// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A one-shot readiness callback on a socket, without a task waiting for it.
//!
//! A server that keeps thousands of idle connections can end each idle
//! connection's task, keep the connection as a small heap object, and arm a
//! `ReadyWatch` on its socket. When the socket becomes readable, the callback
//! runs on the executor that armed the watch, and it can spawn a task there to
//! serve the connection (`Runtime.spawnInto(.local, ...)` and
//! `Group.spawnInto(.local, ...)` are valid from a loop callback).
//!
//! ```zig
//! conn.watch = try zio.net.ReadyWatch.arm(conn.socket.handle, .readable, onReadable, conn);
//!
//! fn onReadable(userdata: ?*anyopaque, result: zio.net.ReadyWatch.Error!void) void {
//!     const conn: *Conn = @ptrCast(@alignCast(userdata));
//!     conn.watch = null; // the watch is gone once its callback runs
//!     _ = result catch {}; // the next read reports the socket's error
//!     var handle = rt.spawnInto(.local, serve, .{conn}) catch |err| return conn.drop(err);
//!     handle.detach();
//! }
//! ```
//!
//! The watch belongs to zio, so the object it refers to can be freed as soon
//! as `disarm` returns: the event loop may still hold the watch for a while
//! (an io_uring cancel completes asynchronously), but it never calls back.

const std = @import("std");
const builtin = @import("builtin");

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const runtime = @import("runtime.zig");
const Executor = runtime.Executor;
const AtomicStack = @import("ev/loop.zig").AtomicStack;

const Handle = ev.Backend.NetHandle;

pub const ReadyWatch = struct {
    poll: ev.NetPoll,
    home: *Executor,
    callback: Callback,
    userdata: ?*anyopaque,
    state: State = .armed,
    /// In `home.watches.live` from `arm` until freed.
    live_node: std.DoublyLinkedList.Node = .{},
    /// Link in `home.watches.inbox` while handed back from another loop.
    next: ?*ReadyWatch = null,

    const State = enum { armed, disarmed, fired };

    pub const Event = enum { readable, writable };

    /// What the callback is told: the socket is ready, or polling it failed.
    /// A hangup or a pending socket error counts as ready on most backends;
    /// the next read or write reports it.
    pub const Error = os.net.RecvError;

    /// Runs on the executor that armed the watch, from its event loop, not
    /// from a task: it must not block or wait. It may arm or disarm other
    /// watches, spawn tasks (`spawnInto(.local, ...)`), and signal events or
    /// channels. The watch is freed when it returns.
    pub const Callback = *const fn (userdata: ?*anyopaque, result: Error!void) void;

    pub const ArmError = error{
        /// Called from a thread that is not one of a runtime's executors.
        InvalidPlacement,
        OutOfMemory,
    };

    /// Calls `callback(userdata, ...)` once, when `handle` becomes ready for
    /// `event`, on the calling executor; at once (from the loop, after `arm`
    /// returns) if it is ready now. Callable from a task or from a loop
    /// callback running on an executor.
    ///
    /// The returned watch is valid until its callback starts or until
    /// `disarm`; use neither after that. Disarm the watch before closing the
    /// socket. A watch that never fires is freed with its executor when the
    /// runtime shuts down, without calling back. Armed on the main executor,
    /// it fires only while the main task waits in zio, as that is when the
    /// main executor runs its loop.
    ///
    /// Only the executor that armed the watch may disarm it, so with
    /// `.work_stealing` scheduling arm it from a loop callback, or from a
    /// task that disarms it only before its next suspension point.
    pub fn arm(handle: Handle, event: Event, callback: Callback, userdata: ?*anyopaque) ArmError!*ReadyWatch {
        const home = runtime.getCurrentExecutorOrNull() orelse return error.InvalidPlacement;
        const self = try home.runtime.allocator.create(ReadyWatch);
        self.* = .{
            .poll = .init(handle, switch (event) {
                .readable => .recv,
                .writable => .send,
            }),
            .home = home,
            .callback = callback,
            .userdata = userdata,
        };
        // Deferred finishing (the default) keeps the callback out of `arm`
        // even when the socket is ready at once.
        self.poll.c.callback = onPoll;
        home.watches.attach(home, self);
        home.loopAdd(&self.poll.c);
        return self;
    }

    /// The callback will not run once this returns, and whatever its userdata
    /// points at may be freed. Must be called on the executor that armed the
    /// watch. A no-op from inside the watch's own callback.
    pub fn disarm(self: *ReadyWatch) void {
        std.debug.assert(runtime.getCurrentExecutorOrNull() == self.home);
        if (self.state != .armed) return;
        self.state = .disarmed;
        // Fire-and-forget: the poll may already be finished, queued for its
        // callback, or (io_uring) canceled only later. Whichever way it ends,
        // `onPoll` sees `.disarmed` and frees the watch.
        self.home.loopCancel(&self.poll.c);
    }

    /// The poll finished on `loop`. On epoll and kqueue the loop that owns a
    /// socket's readiness services it, which need not be the one that armed
    /// the watch (any loop may on IOCP), so the watch goes back to its home
    /// executor first: state, callback and free all stay on that thread.
    fn onPoll(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *ReadyWatch = @fieldParentPtr("poll", c.cast(ev.NetPoll));
        if (loop != &self.home.loop) return self.home.watches.handBack(self);
        self.finish();
    }

    fn finish(self: *ReadyWatch) void {
        if (self.state == .armed) {
            self.state = .fired;
            const result: Error!void = if (self.poll.getResult()) |_| {} else |err| switch (err) {
                // Only `disarm` cancels the poll, and it leaves `.armed`.
                error.Canceled => unreachable,
                else => |e| e,
            };
            self.callback(self.userdata, result);
        }
        self.home.watches.free(self);
    }
};

/// An executor's watches. Touched only on the executor's thread, except
/// `inbox`, where other loops hand back the watches they finished.
pub const Home = struct {
    live: std.DoublyLinkedList = .{},
    inbox: AtomicStack(ReadyWatch) = .{},
    /// Wakes the home loop to drain `inbox`; added to the loop with the
    /// first watch, so executors without watches carry nothing.
    inbox_async: ev.Async = .init(),
    inbox_added: bool = false,

    fn attach(self: *Home, executor: *Executor, watch: *ReadyWatch) void {
        if (!self.inbox_added) {
            self.inbox_async.c.callback = drainInbox;
            self.inbox_async.c.flags.rearm = true;
            executor.loopAdd(&self.inbox_async.c);
            self.inbox_added = true;
        }
        self.live.append(&watch.live_node);
    }

    /// Any thread: queue a watch another loop finished for its home loop.
    fn handBack(self: *Home, watch: *ReadyWatch) void {
        self.inbox.push(watch);
        self.inbox_async.notify();
    }

    fn drainInbox(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Home = @fieldParentPtr("inbox_async", c.cast(ev.Async));
        // Pushed last, popped first: reverse so they finish in arrival order.
        var batch = self.inbox.popAll();
        var ordered: ?*ReadyWatch = null;
        while (batch.pop()) |watch| {
            watch.next = ordered;
            ordered = watch;
        }
        while (ordered) |watch| {
            ordered = watch.next;
            watch.next = null;
            watch.finish();
        }
    }

    fn free(self: *Home, watch: *ReadyWatch) void {
        self.live.remove(&watch.live_node);
        watch.home.runtime.allocator.destroy(watch);
    }

    /// Frees the watches that never finished. Called with every loop of the
    /// runtime stopped and this executor's loop torn down, so nothing can
    /// still finish or hand one back.
    pub fn deinit(self: *Home, allocator: std.mem.Allocator) void {
        while (self.live.popFirst()) |node| {
            const watch: *ReadyWatch = @fieldParentPtr("live_node", node);
            // IOCP may still write the pending zero-byte receive's result
            // into the watch, so leave it allocated there.
            if (ev.backend == .iocp and watch.poll.c.loadState().phase == .running) continue;
            allocator.destroy(watch);
        }
    }
};

const testing = std.testing;
const zio_options = @import("options.zig").options;
const multi_executor = zio_options.scheduling.multiExecutor();
const migrates = zio_options.scheduling.migrates();
const Runtime = runtime.Runtime;
const Placement = runtime.Placement;
const Group = @import("group.zig").Group;
const ResetEvent = @import("sync/Event.zig");
const net = @import("net.zig");

const wait_limit: @import("time.zig").Timeout = .{ .duration = .fromSeconds(5) };

/// A connected socket pair: the watches are on `fds[0]`, the test writes to
/// `fds[1]`.
const Pair = struct {
    fds: [2]Handle,

    fn open() !Pair {
        return .{ .fds = try os.net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true }) };
    }

    fn send(self: Pair) !void {
        const iov = [_]os.net.iovec_const{os.net.iovecConstFromSlice("x")};
        _ = try os.net.send(self.fds[1], &iov, .{});
    }

    /// Through the loop, which also drops the sockets' registrations.
    fn close(self: Pair) void {
        for (self.fds) |fd| (net.Socket{ .handle = fd, .address = undefined }).close();
    }

    /// Without a runtime, after it is gone.
    fn closeRaw(self: Pair) void {
        for (self.fds) |fd| os.net.close(fd);
    }
};

const Probe = struct {
    fired: std.atomic.Value(u32) = .init(0),
    executor: std.atomic.Value(?*Executor) = .init(null),
    err: ?anyerror = null,
    done: ResetEvent = .init,
    /// Cleared by the callback, as the watch is gone once it runs.
    watch: ?*ReadyWatch = null,

    fn callback(userdata: ?*anyopaque, result: ReadyWatch.Error!void) void {
        const self: *Probe = @ptrCast(@alignCast(userdata));
        self.watch = null;
        self.executor.store(runtime.getCurrentExecutorOrNull(), .release);
        result catch |err| {
            self.err = err;
        };
        _ = self.fired.fetchAdd(1, .acq_rel);
        self.done.set();
    }

    fn arm(self: *Probe, handle: Handle, event: ReadyWatch.Event) !void {
        self.watch = try ReadyWatch.arm(handle, event, callback, self);
    }

    fn disarm(self: *Probe) void {
        if (self.watch) |watch| watch.disarm();
        self.watch = null;
    }
};

test "ReadyWatch: fires once when the socket becomes readable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    var probe: Probe = .{};
    try probe.arm(pair.fds[0], .readable);
    try rt.sleep(.fromMilliseconds(20));
    try testing.expectEqual(0, probe.fired.load(.acquire));

    try pair.send();
    try probe.done.waitTimeout(wait_limit);
    // Still readable (nothing read the byte), and still once.
    try rt.sleep(.fromMilliseconds(20));
    try testing.expectEqual(1, probe.fired.load(.acquire));
    try testing.expectEqual(runtime.getCurrentExecutor(), probe.executor.load(.acquire).?);
    try testing.expectEqual(null, probe.err);
    try testing.expectEqual(null, probe.watch);
}

test "ReadyWatch: writable fires at once on a fresh socket, from the loop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{});
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    var probe: Probe = .{};
    try probe.arm(pair.fds[0], .writable);
    // Ready now, yet the callback waits for the loop: `arm` never calls it.
    try testing.expectEqual(0, probe.fired.load(.acquire));
    try probe.done.waitTimeout(wait_limit);
    try testing.expectEqual(1, probe.fired.load(.acquire));
}

test "ReadyWatch: disarmed before readiness, never fires" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    var probe: Probe = .{};
    // Disarmed while parked in the loop.
    try probe.arm(pair.fds[0], .readable);
    try rt.sleep(.fromMilliseconds(10));
    probe.disarm();
    // Disarmed before the loop even saw it.
    try probe.arm(pair.fds[0], .readable);
    probe.disarm();

    try pair.send();
    try rt.sleep(.fromMilliseconds(50));
    try testing.expectEqual(0, probe.fired.load(.acquire));
}

test "ReadyWatch: disarm racing readiness" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    // Readable before arming: the poll finishes inside `arm` and its callback
    // is queued; disarming then must still win.
    try pair.send();
    var probe: Probe = .{};
    try probe.arm(pair.fds[0], .readable);
    probe.disarm();
    try rt.sleep(.fromMilliseconds(20));
    try testing.expectEqual(0, probe.fired.load(.acquire));

    // Disarm at varying distances from the readiness: whatever had fired by
    // then is all that ever fires.
    var prng: std.Random.DefaultPrng = .init(0x2ead1);
    const random = prng.random();
    for (0..300) |_| {
        var p: Probe = .{};
        try p.arm(pair.fds[0], .readable);
        for (0..random.uintLessThan(u8, 4)) |_| try runtime.yield();
        if (random.boolean()) try rt.sleep(.fromMicroseconds(random.uintLessThan(u32, 200)));
        p.disarm();
        const fired = p.fired.load(.acquire);
        try testing.expect(fired <= 1);
        try runtime.yield();
        try runtime.yield();
        try testing.expectEqual(fired, p.fired.load(.acquire));
    }
    try rt.sleep(.fromMilliseconds(20));
}

test "ReadyWatch: runs on the executor that armed it when another loop owns the socket" {
    if (builtin.os.tag == .windows or !multi_executor or migrates) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    const H = struct {
        // Parks a read on executor 1, so on epoll and kqueue its loop owns
        // the socket's readiness from then on.
        fn reader(handle: Handle) !void {
            var buf: [1]u8 = undefined;
            const stream: net.Stream = .{ .socket = .{ .handle = handle, .address = undefined } };
            _ = try stream.read(&buf, .none);
        }
    };
    var handle = try rt.spawnInto(.{ .executor = 1 }, H.reader, .{pair.fds[0]});
    try rt.sleep(.fromMilliseconds(20));
    try pair.send();
    try handle.join();

    var probe: Probe = .{};
    try probe.arm(pair.fds[0], .readable);
    try rt.sleep(.fromMilliseconds(10));
    try pair.send();
    try probe.done.waitTimeout(wait_limit);
    try testing.expectEqual(1, probe.fired.load(.acquire));
    try testing.expectEqual(rt.executors.items[0], probe.executor.load(.acquire).?);
}

/// A connection parked on a watch, served by a task spawned from its callback.
const Parked = struct {
    rt: *Runtime,
    handle: Handle,
    group: *Group,
    detached: bool,
    home: ?*Executor = null,
    served_on: std.atomic.Value(?*Executor) = .init(null),
    err: ?anyerror = null,
    done: ResetEvent = .init,

    fn park(self: *Parked) !void {
        self.home = runtime.getCurrentExecutor();
        _ = try ReadyWatch.arm(self.handle, .readable, onReadable, self);
    }

    fn onReadable(userdata: ?*anyopaque, result: ReadyWatch.Error!void) void {
        const self: *Parked = @ptrCast(@alignCast(userdata));
        self.spawn(result) catch |err| {
            self.err = err;
            self.done.set();
        };
    }

    fn spawn(self: *Parked, result: ReadyWatch.Error!void) !void {
        try result;
        // A fixed placement promises the task stays put, which work stealing
        // cannot.
        const placement: Placement = if (migrates) .auto else .local;
        if (self.detached) {
            var handle = try self.rt.spawnInto(placement, serve, .{self});
            handle.detach();
        } else {
            try self.group.spawnInto(placement, serve, .{self});
        }
    }

    fn serve(self: *Parked) void {
        self.served_on.store(runtime.getCurrentExecutor(), .release);
        var buf: [8]u8 = undefined;
        const stream: net.Stream = .{ .socket = .{ .handle = self.handle, .address = undefined } };
        if (stream.read(&buf, .none)) |n| {
            if (n != 1) self.err = error.TestUnexpectedResult;
        } else |err| self.err = err;
        self.done.set();
    }
};

fn testSpawnFromCallback(detached: bool) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const pair = try Pair.open();
    defer pair.close();

    var group: Group = .init;
    defer group.cancel();

    var parked: Parked = .{ .rt = rt, .handle = pair.fds[0], .group = &group, .detached = detached };
    // Parked by a task on the last executor, which then ends.
    const last: runtime.ExecutorId = @intCast(rt.executors.items.len - 1);
    var handle = try rt.spawnInto(if (migrates) .auto else .{ .executor = last }, Parked.park, .{&parked});
    try handle.join();

    try rt.sleep(.fromMilliseconds(10));
    try pair.send();
    try parked.done.waitTimeout(wait_limit);
    try group.wait();
    // A detached task is in no group, but it sets `done` last and ends
    // without suspending again, before its executor stops for `deinit`.

    try testing.expectEqual(null, parked.err);
    const served_on = parked.served_on.load(.acquire).?;
    if (!migrates) try testing.expectEqual(parked.home.?, served_on);
}

test "ReadyWatch: the callback spawns a task into a group on its executor" {
    try testSpawnFromCallback(false);
}

test "ReadyWatch: the callback spawns a detached task on its executor" {
    try testSpawnFromCallback(true);
}

test "ReadyWatch: arming off an executor fails" {
    if (builtin.os.tag == .windows or builtin.single_threaded) return error.SkipZigTest;

    const pair = try Pair.open();
    defer pair.closeRaw();

    const H = struct {
        fn foreign(handle: Handle, result: *?anyerror) void {
            _ = ReadyWatch.arm(handle, .readable, Probe.callback, null) catch |err| {
                result.* = err;
                return;
            };
        }
    };
    var result: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, H.foreign, .{ pair.fds[0], &result });
    thread.join();
    try testing.expectEqual(error.InvalidPlacement, result.?);
}

test "ReadyWatch: shutting down with watches armed frees them without calling back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var pairs: [4]Pair = undefined;
    var opened: usize = 0;
    defer for (pairs[0..opened]) |pair| pair.closeRaw();
    for (&pairs) |*pair| {
        pair.* = try Pair.open();
        opened += 1;
    }

    var probes: [pairs.len]Probe = @splat(.{});
    {
        const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(3) });
        defer rt.deinit();

        const H = struct {
            fn armer(probe: *Probe, handle: Handle) !void {
                try probe.arm(handle, .readable);
            }
        };
        // One from the main task, the rest from tasks on every executor.
        try probes[0].arm(pairs[0].fds[0], .readable);
        for (probes[1..], pairs[1..], 0..) |*probe, pair, i| {
            const placement: Placement = if (migrates) .auto else .{ .executor = @intCast(i % rt.executors.items.len) };
            var handle = try rt.spawnInto(placement, H.armer, .{ probe, pair.fds[0] });
            try handle.join();
        }
        try rt.sleep(.fromMilliseconds(10));
    }
    for (&probes) |*probe| try testing.expectEqual(0, probe.fired.load(.acquire));
}

test "ReadyWatch: arm and disarm from tasks on every executor" {
    // Disarming has to happen on the arming executor, which a task under
    // work stealing cannot promise across a suspension.
    if (builtin.os.tag == .windows or migrates) return error.SkipZigTest;

    const rt = try Runtime.init(testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();

    const H = struct {
        fn worker(seed: u64) !void {
            var prng: std.Random.DefaultPrng = .init(seed);
            const random = prng.random();
            for (0..100) |_| {
                const pair = try Pair.open();
                defer pair.close();
                var probe: Probe = .{};
                try probe.arm(pair.fds[0], .readable);
                const send = random.boolean();
                if (send) try pair.send();
                for (0..random.uintLessThan(u8, 3)) |_| try runtime.yield();
                probe.disarm();
                const fired = probe.fired.load(.acquire);
                if (fired > 1 or (fired == 1 and !send)) return error.TestUnexpectedResult;
                try runtime.yield();
                if (probe.fired.load(.acquire) != fired) return error.TestUnexpectedResult;
                if (fired == 1 and probe.executor.load(.acquire) != runtime.getCurrentExecutor()) return error.TestUnexpectedResult;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();
    const n = rt.executors.items.len;
    for (0..2 * n) |i| {
        try group.spawnInto(.{ .executor = @intCast(i % n) }, H.worker, .{i});
    }
    try group.wait();
    try testing.expect(!group.hasFailed());
}
