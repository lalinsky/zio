const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const common = @import("common.zig");

const unexpectedError = @import("../../os/base.zig").unexpectedError;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Queue = @import("../queue.zig").Queue;
const NetConnect = @import("../completion.zig").NetConnect;
const NetAccept = @import("../completion.zig").NetAccept;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetRecvFrom = @import("../completion.zig").NetRecvFrom;
const NetSendTo = @import("../completion.zig").NetSendTo;
const NetRecvMsg = @import("../completion.zig").NetRecvMsg;
const NetSendMsg = @import("../completion.zig").NetSendMsg;
const NetPoll = @import("../completion.zig").NetPoll;
const NetClose = @import("../completion.zig").NetClose;
const PipePoll = @import("../completion.zig").PipePoll;
const PipeClose = @import("../completion.zig").PipeClose;
const MachPort = @import("../completion.zig").MachPort;
const ProcessWait = @import("../completion.zig").ProcessWait;
const fs = @import("../../os/fs.zig");
const sockreg = @import("../sockreg.zig");
const Loop = @import("../loop.zig").Loop;
const Op = @import("../completion.zig").Op;

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .process_wait = true,
    // Only Darwin has usable absolute wall-clock EVFILT_TIMER semantics
    // (NOTE_ABSOLUTE = gettimeofday, NOTE_MACH_CONTINUOUS_TIME = suspend-aware).
    // The BSDs' EVFILT_TIMER absolute clock is monotonic-only and underspecified
    // with no CLOCK_REALTIME timer, so they keep the capped poll-timeout fallback.
    .native_wall_timers = builtin.os.tag.isDarwin(),
    .cross_loop_socket_reg = true,
};

pub const SharedState = struct {
    /// Cross-loop single-owner socket registration table, shared by every loop
    /// in the group. See sockreg.zig.
    sock_table: sockreg.Table = .{},
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const Self = @This();

const log = @import("../../common.zig").log;

// These are not defined in std.c for FreeBSD/NetBSD,
// but the values are the same across all systems using kqueue
const EV_ERROR: u16 = 0x4000;
const EV_EOF: u16 = 0x8000;

// std.c has wrong numbers for EVFILT_USER and NOTE_TRIGGER on NetBSD
// https://github.com/ziglang/zig/pull/25853
const EVFILT_USER: i16 = switch (builtin.target.os.tag) {
    .netbsd => 8,
    else => std.c.EVFILT.USER,
};
const NOTE_TRIGGER: u32 = 0x01000000;

const delete_marker: usize = std.math.maxInt(usize);

// udata tag marking a kevent that belongs to the single-owner socket path, so
// poll() routes its events to the shared registration table instead of the
// one-shot poll_queue (pipes / streaming files share EVFILT_READ/WRITE but use
// udata == 0).
const sock_marker: usize = std.math.maxInt(usize) - 1;

// Persistent edge-triggered (EV_CLEAR) interest for sockets: a fd/direction is
// added to its owner loop's kqueue once and stays registered for the fd's life.
// Edge-triggered is safe because submit() drains the socket to EAGAIN first.

fn isSocketOp(op: Op) bool {
    return switch (op) {
        .net_connect,
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_sendmsg,
        .net_poll,
        => true,
        else => false,
    };
}

/// Direction (read/write filter) a socket op waits on.
fn dirForOp(c: *Completion) sockreg.Dir {
    return switch (c.op) {
        .net_accept, .net_recv, .net_recvfrom, .net_recvmsg => .read,
        .net_connect, .net_send, .net_sendto, .net_sendmsg => .write,
        .net_poll => switch (c.cast(NetPoll).event) {
            .recv => .read,
            .send => .write,
        },
        else => unreachable,
    };
}

fn filterForDir(dir: sockreg.Dir) i16 {
    return switch (dir) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };
}

// EVFILT_TIMER idents for the boot/real wall-clock timers (Darwin only). They
// share the EVFILT_TIMER filter, which nothing else uses, so plain 0/1 idents
// don't collide with fd-based idents on other filters.
const WALL_BOOT_IDENT: usize = 0;
const WALL_REAL_IDENT: usize = 1;

const PollEntry = struct {
    completions: Queue(Completion),
};

allocator: std.mem.Allocator,
/// Shared cross-loop socket registration table (see sockreg.zig). All loops in
/// a group point at the same table.
shared: *SharedState = undefined,
kqueue_fd: i32 = -1,
waker_ident: usize = undefined,
poll_queue: std.AutoHashMapUnmanaged(u64, PollEntry) = .empty,
change_buffer: std.ArrayList(std.c.Kevent) = .empty,
events: []std.c.Kevent,
/// Currently-armed absolute deadline (ns in the clock's epoch) for the boot/real
/// EVFILT_TIMER, or null if disarmed. Index 0 = boot, 1 = real. Darwin only.
wall_armed: [2]?u64 = .{ null, null },

fn makeKey(ident: usize, filter: i32) u64 {
    std.debug.assert(ident <= std.math.maxInt(u32));
    return (@as(u64, @intCast(ident)) << 32) | @as(u32, @bitCast(filter));
}

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    shared_state.sock_table.acquire(allocator);
    errdefer shared_state.sock_table.release();
    const kq = std.c.kqueue();
    const kqueue_fd: i32 = switch (posix.errno(kq)) {
        .SUCCESS => @intCast(kq),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = std.c.close(kqueue_fd);

    const events = try allocator.alloc(std.c.Kevent, queue_size);
    errdefer allocator.free(events);

    var change_buffer = try std.ArrayList(std.c.Kevent).initCapacity(allocator, queue_size);
    errdefer change_buffer.deinit(allocator);

    // Use address of self as unique waker ident
    const waker_ident = @intFromPtr(self);

    // Register EVFILT_USER for wakeups
    var changes: [1]std.c.Kevent = .{.{
        .ident = waker_ident,
        .filter = EVFILT_USER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    const rc = std.c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return unexpectedError(err),
    }

    self.* = .{
        .allocator = allocator,
        .shared = shared_state,
        .kqueue_fd = kqueue_fd,
        .waker_ident = waker_ident,
        .change_buffer = change_buffer,
        .events = events,
    };

    try self.poll_queue.ensureTotalCapacity(self.allocator, queue_size);
}

pub fn deinit(self: *Self) void {
    self.poll_queue.deinit(self.allocator);
    self.change_buffer.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.kqueue_fd != -1) {
        _ = std.c.close(self.kqueue_fd);
    }
    self.shared.sock_table.release();
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    var changes: [1]std.c.Kevent = .{.{
        .ident = self.waker_ident,
        .filter = EVFILT_USER,
        .flags = 0,
        .fflags = NOTE_TRIGGER,
        .data = 0,
        .udata = 0,
    }};
    _ = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
}

/// Arm/update/disarm the given wall clock's EVFILT_TIMER to an absolute deadline
/// (ns in that clock's epoch; null = disarm). Returns false only if it couldn't
/// arm a pending deadline, so the loop folds that clock into the capped poll
/// timeout. Darwin only; other kqueue platforms keep the fallback (the comptime
/// guard also keeps the Darwin-only NOTE_* references out of their builds).
pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        return switch (clock) {
            .boot => self.armWall(0, WALL_BOOT_IDENT, deadline),
            .real => self.armWall(1, WALL_REAL_IDENT, deadline),
            else => unreachable,
        };
    }
    return true;
}

fn armWall(self: *Self, idx: usize, ident: usize, deadline: ?u64) bool {
    if (self.wall_armed[idx] == deadline) return true; // unchanged (incl. both null)
    // reserveChange only fails on OOM: the change buffer grows and is reused
    // across polls (clearRetainingCapacity), so there's no "full" condition like
    // io_uring's fixed SQ ring. On OOM while arming a pending deadline, report
    // failure so the loop folds this clock into the capped poll timeout and
    // retries next scan. A failed disarm has no pending deadline to fold, so
    // report success and let the stale one-shot wake harmlessly / retry later.
    const change = self.reserveChange() catch {
        log.err("kqueue: failed to reserve change buffer slot for wall timer", .{});
        return deadline == null;
    };
    if (deadline) |d| {
        var fflags: u32 = std.c.NOTE.NSECONDS;
        var data: isize = undefined;
        if (idx == 0) {
            // boot: relative continuous-time timer — counts suspend, and being
            // relative it needs no epoch match with our boot clock.
            const now_ns = time.now(.boot).toNanoseconds();
            fflags |= std.c.NOTE.MACH_CONTINUOUS_TIME;
            data = @intCast(if (d > now_ns) d - now_ns else 0);
        } else {
            // real: absolute gettimeofday timer — fires at the wall moment and
            // is re-evaluated by the kernel across clock steps.
            fflags |= std.c.NOTE.ABSOLUTE;
            data = @intCast(d);
        }
        change.* = .{
            .ident = ident,
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = fflags,
            .data = data,
            .udata = 0,
        };
    } else {
        change.* = .{
            .ident = ident,
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
    }
    self.wall_armed[idx] = deadline;
    return true;
}

fn getFilter(completion: *Completion) i16 {
    return switch (completion.op) {
        .net_connect => std.c.EVFILT.WRITE,
        .net_accept => std.c.EVFILT.READ,
        .net_recv => std.c.EVFILT.READ,
        .net_send => std.c.EVFILT.WRITE,
        .net_recvfrom => std.c.EVFILT.READ,
        .net_sendto => std.c.EVFILT.WRITE,
        .net_recvmsg => std.c.EVFILT.READ,
        .net_sendmsg => std.c.EVFILT.WRITE,
        .net_poll => blk: {
            const poll_data = completion.cast(NetPoll);
            break :blk switch (poll_data.event) {
                .recv => std.c.EVFILT.READ,
                .send => std.c.EVFILT.WRITE,
            };
        },
        .file_read_streaming => std.c.EVFILT.READ,
        .file_write_streaming => std.c.EVFILT.WRITE,
        .pipe_poll => blk: {
            const poll_data = completion.cast(PipePoll);
            break :blk switch (poll_data.event) {
                .read => std.c.EVFILT.READ,
                .write => std.c.EVFILT.WRITE,
            };
        },
        .process_wait => std.c.EVFILT.PROC,
        .mach_port => if (builtin.os.tag.isDarwin()) std.c.EVFILT.MACHPORT else unreachable,
        else => unreachable,
    };
}

fn getIdent(completion: *Completion) usize {
    return switch (completion.op) {
        .net_accept => @intCast(completion.cast(NetAccept).handle),
        .net_connect => @intCast(completion.cast(NetConnect).handle),
        .net_recv => @intCast(completion.cast(NetRecv).handle),
        .net_send => @intCast(completion.cast(NetSend).handle),
        .net_recvfrom => @intCast(completion.cast(NetRecvFrom).handle),
        .net_sendto => @intCast(completion.cast(NetSendTo).handle),
        .net_recvmsg => @intCast(completion.cast(NetRecvMsg).handle),
        .net_sendmsg => @intCast(completion.cast(NetSendMsg).handle),
        .net_poll => @intCast(completion.cast(NetPoll).handle),
        .pipe_poll => @intCast(completion.cast(PipePoll).handle),
        inline .file_read_streaming, .file_write_streaming => |op| @intCast(completion.cast(op.toType()).handle),
        .pipe_close => @intCast(completion.cast(PipeClose).handle),
        .process_wait => @intCast(completion.cast(ProcessWait).handle),
        .mach_port => completion.cast(MachPort).port,
        else => unreachable,
    };
}

fn getFflags(completion: *Completion) u32 {
    return switch (completion.op) {
        .process_wait => std.c.NOTE.EXIT,
        else => 0,
    };
}

fn reserveChange(self: *Self) !*std.c.Kevent {
    return self.change_buffer.addOne(self.allocator);
}

fn addToPollQueue(self: *Self, state: *LoopState, completion: *Completion) void {
    const ident = getIdent(completion);
    const filter = getFilter(completion);
    const key = makeKey(ident, filter);

    completion.prev = null;
    completion.next = null;

    const gop = self.poll_queue.getOrPut(self.allocator, key) catch {
        log.err("Failed to add to poll queue: OutOfMemory", .{});
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return;
    };

    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .completions = .{} };
        const change = self.reserveChange() catch {
            _ = self.poll_queue.remove(key);
            completion.setError(error.Unexpected);
            state.markCompletedFromBackend(completion);
            return;
        };
        change.* = .{
            .ident = ident,
            .filter = filter,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = getFflags(completion),
            .data = 0,
            .udata = 0,
        };
    }

    gop.value_ptr.completions.push(completion);
}

fn removeFromPollQueue(self: *Self, completion: *Completion) void {
    const ident = getIdent(completion);
    const filter = getFilter(completion);
    const key = makeKey(ident, filter);
    const entry = self.poll_queue.getPtr(key) orelse return;

    _ = entry.completions.remove(completion);

    if (entry.completions.head == null) {
        const change = self.reserveChange() catch {
            _ = self.poll_queue.remove(key);
            return;
        };
        change.* = .{
            .ident = ident,
            .filter = filter,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = delete_marker,
        };
        _ = self.poll_queue.remove(key);
    }
}

// ---- single-owner socket registration path ----------------------------------

const ParkResult = enum {
    /// Completion parked in the owner loop's waiter queue.
    parked,
    /// A readiness edge raced us; the caller should retry the syscall.
    retry,
    /// Registration/allocation failed; completion already finished with an error.
    failed,
};

/// Queue an EV_ADD | EV_CLEAR for `(fd, dir)` on this loop's kqueue (applied on
/// the next poll). Edge-triggered + persistent: the registration stays for the
/// fd's lifetime. Returns false only on OOM growing the change buffer.
fn ensureKevent(self: *Self, fd: NetHandle, dir: sockreg.Dir) bool {
    const change = self.reserveChange() catch {
        log.err("kqueue: failed to reserve change buffer slot for socket", .{});
        return false;
    };
    change.* = .{
        .ident = @intCast(fd),
        .filter = filterForDir(dir),
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = sock_marker,
    };
    return true;
}

/// Park `completion` on the loop that owns `(fd, dir)`, registering this loop as
/// the owner if nobody is yet. If the owner is a different loop, the completion
/// (and its accounting) is migrated to it. Returns `.retry` if a readiness edge
/// raced the optimistic syscall.
fn parkSocket(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) ParkResult {
    const dir = dirForOp(completion);
    const self_loop: *anyopaque = @ptrCast(state.loop);
    const shard = self.shared.sock_table.shardForFd(fd);

    shard.mutex.lock();
    const gop = shard.map.getOrPut(self.shared.sock_table.allocator, @as(u32, @bitCast(fd))) catch {
        shard.mutex.unlock();
        log.err("sock registration table OOM", .{});
        completion.setError(error.Unexpected);
        state.markCompletedDeferredFromBackend(completion);
        return .failed;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const entry = gop.value_ptr;
    const created = !gop.found_existing;

    // A readiness edge fired since our optimistic syscall: retry instead of
    // sleeping (the data the edge announced is still in the socket buffer).
    const ready = entry.readyPtr(dir);
    if (ready.*) {
        ready.* = false;
        if (created and entry.isEmpty()) _ = shard.map.remove(@as(u32, @bitCast(fd)));
        shard.mutex.unlock();
        return .retry;
    }

    const owner = entry.ownerPtr(dir);
    if (owner.* == null) {
        // Become the owner: register this fd/direction in this loop's kqueue.
        if (!self.ensureKevent(fd, dir)) {
            if (created and entry.isEmpty()) _ = shard.map.remove(@as(u32, @bitCast(fd)));
            shard.mutex.unlock();
            completion.setError(error.Unexpected);
            state.markCompletedDeferredFromBackend(completion);
            return .failed;
        }
        owner.* = self_loop;
    }

    completion.prev = null;
    completion.next = null;
    if (owner.* != self_loop) {
        // Migrate ownership of this completion to the loop that monitors the fd:
        // move its accounting and reassign its loop so it completes/cancels there.
        const owner_loop: *Loop = @ptrCast(@alignCast(owner.*));
        state.decrInflight();
        state.decrActive();
        owner_loop.state.incrInflight();
        owner_loop.state.incrActive();
        completion.loop = owner_loop;
        // The owner monitors this fd in its own kqueue; nudge it so it applies a
        // possibly-pending registration / re-checks readiness promptly.
        owner_loop.wake();
    }
    entry.waiters(dir).push(completion);
    shard.mutex.unlock();
    return .parked;
}

/// Generic submit for socket read/write/accept-family ops: try the syscall
/// optimistically (reusing checkCompletion with a no-error synthetic event) and
/// only park on WouldBlock. Draining to EAGAIN first makes EV_CLEAR safe.
fn submitSocketIo(self: *Self, state: *LoopState, c: *Completion) void {
    const fd: NetHandle = @intCast(getIdent(c));
    const dir = dirForOp(c);
    var probe: std.c.Kevent = .{
        .ident = @intCast(fd),
        .filter = filterForDir(dir),
        .flags = 0,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    while (true) {
        switch (checkCompletion(c, &probe)) {
            .completed => {
                state.markCompletedDeferredFromBackend(c);
                return;
            },
            .requeue => switch (self.parkSocket(state, fd, c)) {
                .parked, .failed => return,
                .retry => {}, // loop and retry the syscall
            },
        }
    }
}

/// Submit a connect: try connect() first, register on WouldBlock.
fn submitConnect(self: *Self, state: *LoopState, c: *Completion) void {
    const data = c.cast(NetConnect);
    if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
        c.setResult(.net_connect, {});
        state.markCompletedDeferredFromBackend(c);
        return;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => {
            c.setError(err);
            state.markCompletedDeferredFromBackend(c);
            return;
        },
    }
    switch (self.parkSocket(state, data.handle, c)) {
        .parked, .failed => {},
        .retry => {
            // The socket became writable while we raced: the connect finished.
            if (net.getSockError(data.handle)) |se| {
                if (se == 0) c.setResult(.net_connect, {}) else c.setError(net.errnoToConnectError(@enumFromInt(se)));
            } else |_| c.setError(error.Unexpected);
            state.markCompletedDeferredFromBackend(c);
        },
    }
}

/// Submit a net_poll: probe readiness with a 0-timeout poll() first (it has no
/// I/O to drain, so it cannot rely on a fresh edge for an already-ready socket),
/// and register for an edge only when not ready.
fn submitPoll(self: *Self, state: *LoopState, c: *Completion) void {
    const data = c.cast(NetPoll);
    const want: i16 = switch (data.event) {
        .recv => std.posix.POLL.IN,
        .send => std.posix.POLL.OUT,
    };
    while (true) {
        var pfd = [_]std.posix.pollfd{.{ .fd = data.handle, .events = want, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 0) catch 0;
        if (ready > 0 and (pfd[0].revents & (want | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            c.setResult(.net_poll, {});
            state.markCompletedDeferredFromBackend(c);
            return;
        }
        switch (self.parkSocket(state, data.handle, c)) {
            .parked, .failed => return,
            .retry => {}, // re-probe
        }
    }
}

/// Service ready waiters for one (fd, dir) on the owner loop. Runs each waiter's
/// syscall under the shard lock (non-blocking), collects the finished ones, then
/// completes them after unlocking (completing can resume a fiber re-entrantly).
fn serviceSocket(self: *Self, state: *LoopState, fd: NetHandle, dir: sockreg.Dir, event: *const std.c.Kevent) void {
    const shard = self.shared.sock_table.shardForFd(fd);
    shard.mutex.lock();
    const entry = shard.map.getPtr(@as(u32, @bitCast(fd))) orelse {
        shard.mutex.unlock();
        return;
    };

    const had_waiters = entry.waiters(dir).head != null;
    var to_finish: Queue(Completion) = .{};
    var iter: ?*Completion = entry.waiters(dir).head;
    while (iter) |c| {
        iter = c.next;
        if (c.state == .completed or c.state == .dead) {
            _ = entry.waiters(dir).remove(c);
            continue;
        }
        switch (checkCompletion(c, event)) {
            .completed => {
                _ = entry.waiters(dir).remove(c);
                to_finish.push(c);
            },
            .requeue => break, // drained to EAGAIN for this direction
        }
    }
    // Latch a readiness edge that found no waiter so a racing parker retries
    // instead of sleeping for an edge that already passed.
    entry.readyPtr(dir).* = !had_waiters;
    shard.mutex.unlock();

    while (to_finish.pop()) |c| {
        state.markCompletedFromBackend(c);
    }
}

/// Tear down the shared registration for a socket fd about to be closed. Closing
/// the fd removes it from every kqueue at the kernel level, so this only drops
/// the software bookkeeping (for all loops at once).
fn unregisterSocket(self: *Self, fd: NetHandle) void {
    const shard = self.shared.sock_table.shardForFd(fd);
    shard.mutex.lock();
    _ = shard.map.remove(@as(u32, @bitCast(fd)));
    shard.mutex.unlock();
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.incrActive();

    switch (c.op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        // Synchronous operations - complete immediately
        .net_open => {
            common.handleNetOpen(c);
            state.markCompletedFromBackend(c);
        },
        .net_bind => {
            common.handleNetBind(c);
            state.markCompletedFromBackend(c);
        },
        .net_listen => {
            common.handleNetListen(c);
            state.markCompletedFromBackend(c);
        },
        .net_close => {
            const data = c.cast(NetClose);
            // Tear down the persistent registration before the fd is closed, so a
            // future socket that reuses this fd number starts clean on every loop.
            self.unregisterSocket(data.handle);
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Sockets take the single-owner, persistent edge-triggered path: try the
        // syscall optimistically, register with the owning loop only on WouldBlock.
        .net_connect => self.submitConnect(state, c),
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_sendmsg,
        => self.submitSocketIo(state, c),
        .net_poll => self.submitPoll(state, c),

        .pipe_poll,
        // Streaming file I/O is routed here by the loop only when the fd is
        // pollable (non-seekable); a pipe is always pollable.
        .file_read_streaming,
        .file_write_streaming,
        .mach_port,
        .process_wait,
        => {
            self.addToPollQueue(state, c);
        },

        .pipe_create => {
            const fds = fs.pipe() catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
                return;
            };
            c.setResult(.pipe_create, fds);
            state.markCompletedFromBackend(c);
        },
        .pipe_close => {
            const data = c.cast(PipeClose);
            if (fs.close(data.handle)) |_| {
                c.setResult(.pipe_close, {});
            } else |err| {
                c.setError(err);
            }
            state.markCompletedFromBackend(c);
        },

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_size, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .file_stat, .dir_open, .dir_close, .dir_read, .dir_create_dir, .dir_rename, .dir_rename_preserve, .dir_delete_file, .dir_delete_dir, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link, .device_io_control => unreachable,
        // Driven by Loop's generic read/write fallback, never reaches the backend.
        .net_send_file => unreachable,
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    if (isSocketOp(target.op)) {
        // Sockets are parked in the shared (fd, dir) waiter queue of their owner
        // loop. cancel routes to that owner (target.loop), so this runs on the
        // owner's thread and just detaches from the waiter queue. The kqueue
        // registration is persistent and left in place for the fd's lifetime.
        const fd: NetHandle = @intCast(getIdent(target));
        const dir = dirForOp(target);
        const shard = self.shared.sock_table.shardForFd(fd);
        shard.mutex.lock();
        if (shard.map.getPtr(@as(u32, @bitCast(fd)))) |entry| {
            _ = entry.waiters(dir).remove(target);
        }
        shard.mutex.unlock();
    } else {
        self.removeFromPollQueue(target);
    }

    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    var timeout_spec: std.c.timespec = undefined;
    const timeout_ptr: ?*const std.c.timespec = if (timeout.value < std.math.maxInt(time.TimeInt)) blk: {
        const timeout_ns = timeout.toNanoseconds();
        timeout_spec = .{
            .sec = @intCast(timeout_ns / time.ns_per_s),
            .nsec = @intCast(timeout_ns % time.ns_per_s),
        };
        break :blk &timeout_spec;
    } else null;

    const changes = self.change_buffer.items;
    const rc = std.c.kevent(
        self.kqueue_fd,
        changes.ptr,
        @intCast(changes.len),
        self.events.ptr,
        @intCast(self.events.len),
        timeout_ptr,
    );
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return unexpectedError(err),
    };
    self.change_buffer.clearRetainingCapacity();

    if (n == 0) {
        return true; // Timed out
    }

    var wall_fired = false;
    for (self.events[0..n]) |event| {
        // Check if this is the async wakeup user event
        if (event.filter == EVFILT_USER and event.ident == self.waker_ident) {
            continue;
        }

        // A boot/real wall timer event. Forget the armed deadline in both the
        // fired and the failed-registration case: on a successful one-shot fire
        // the kernel already removed it (EV_ONESHOT), and on EV_ERROR the ADD
        // never stuck, so the stored deadline is stale either way — clearing it
        // lets syncWallTimer re-queue the ADD on the next scan.
        if (event.filter == std.c.EVFILT.TIMER) {
            if (event.ident == WALL_BOOT_IDENT) self.wall_armed[0] = null;
            if (event.ident == WALL_REAL_IDENT) self.wall_armed[1] = null;
            // EV_ERROR surfaces a changelist (ADD/DELETE) failure with errno in
            // event.data; no timer actually fired, so don't report a timeout.
            if (event.flags & EV_ERROR != 0) {
                log.err("kqueue: EVFILT_TIMER registration failed (ident={}): errno {}", .{ event.ident, event.data });
                continue;
            }
            wall_fired = true;
            continue;
        }

        if (event.udata == delete_marker) continue;

        // Sockets (single-owner path): the filter tells us the direction; ERR/EOF
        // is delivered to the waiter, which surfaces it via its syscall.
        if (event.udata == sock_marker) {
            const sock_fd: NetHandle = @intCast(event.ident);
            const dir: sockreg.Dir = if (event.filter == std.c.EVFILT.READ) .read else .write;
            self.serviceSocket(state, sock_fd, dir, &event);
            continue;
        }

        const key = makeKey(event.ident, event.filter);
        reload: while (true) {
            const entry = self.poll_queue.get(key) orelse break :reload;

            var iter: ?*Completion = entry.completions.head;
            var completed_any = false;
            while (iter) |completion| {
                iter = completion.next;

                if (completion.state == .completed or completion.state == .dead) {
                    continue;
                }

                switch (checkCompletion(completion, &event)) {
                    .completed => {
                        self.removeFromPollQueue(completion);
                        state.markCompletedFromBackend(completion);
                        completed_any = true;
                        break;
                    },
                    .requeue => {},
                }
            }
            if (!completed_any) break :reload;
        }
    }

    // A fired wall timer is reported as a timeout so the loop re-runs
    // checkTimers and fires the due boot/real timers.
    return wall_fired;
}

const CheckResult = enum { completed, requeue };

fn handleKqueueError(event: *const std.c.Kevent, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.flags & EV_ERROR) != 0;
    const has_eof = (event.flags & EV_EOF) != 0;
    if (!has_error and !has_eof) return null;

    if (has_error) {
        // event.data contains the errno when EV_ERROR is set
        if (event.data != 0) {
            return errnoToError(@enumFromInt(@as(i32, @intCast(event.data))));
        }
    }

    const sock_err = net.getSockError(@intCast(event.ident)) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
    return errnoToError(@enumFromInt(sock_err));
}

pub fn checkCompletion(comp: *Completion, event: *const std.c.Kevent) CheckResult {
    switch (comp.op) {
        .net_connect => {
            if (handleKqueueError(event, net.errnoToConnectError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            if (handleKqueueError(event, net.errnoToAcceptError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                comp.setResult(.net_accept, handle);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |n| {
                comp.setResult(.net_recv, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_send => {
            const data = comp.cast(NetSend);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.send(data.handle, data.buffer.iovecs, data.flags)) |n| {
                comp.setResult(.net_send, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_recvfrom, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_sendto, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvmsg => {
            const data = comp.cast(NetRecvMsg);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                comp.setResult(.net_recvmsg, result);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendmsg => {
            const data = comp.cast(NetSendMsg);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |n| {
                comp.setResult(.net_sendmsg, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_poll => {
            // For poll operations, EOF means the socket is "ready" (will return EOF on next read).
            // Reuse handleKqueueError so we only fail on real socket errors (SO_ERROR != 0),
            // consistent with the other net_* ops.
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_poll, {});
            }
            return .completed;
        },
        inline .file_read_streaming => |op| {
            const data = comp.cast(op.toType());
            // Check for actual errors first
            const has_error = (event.flags & EV_ERROR) != 0;
            if (has_error and event.data != 0) {
                comp.setError(fs.errnoToFileReadError(@enumFromInt(@as(i32, @intCast(event.data)))));
                return .completed;
            }
            // Try to read - there might still be data in the pipe buffer
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // For pipes, EV_EOF means the write end is closed
                    // If we got WouldBlock and EOF is set, that's EOF (no more data)
                    const has_eof = (event.flags & EV_EOF) != 0;
                    if (has_eof) {
                        comp.setResult(op, 0);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        inline .file_write_streaming => |op| {
            const data = comp.cast(op.toType());
            // For pipes, check for errors but don't use getSockError
            const has_error = (event.flags & EV_ERROR) != 0;
            const has_eof = (event.flags & EV_EOF) != 0;
            if (has_error and event.data != 0) {
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                const err = fs.errnoToFileWriteError(@enumFromInt(@as(i32, @intCast(event.data))));
                comp.setError(switch (err) {
                    error.NotOpenForWriting => error.BrokenPipe,
                    else => err,
                });
                return .completed;
            }
            if (has_eof) {
                // Read end closed
                comp.setError(error.BrokenPipe);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                error.NotOpenForWriting => {
                    comp.setError(error.BrokenPipe);
                    return .completed;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .pipe_close => unreachable, // Handled synchronously in submit
        .pipe_create => unreachable, // Handled synchronously in submit
        .pipe_poll => {
            // For poll operations, any event (error, EOF, or readiness) means "ready"
            // The actual error (if any) will be discovered on the next read/write
            comp.setResult(.pipe_poll, {});
            return .completed;
        },
        .mach_port => {
            comp.setResult(.mach_port, {});
            return .completed;
        },
        .process_wait => {
            // Process exited - call waitpid to get exit status and reap zombie
            // Following libuv pattern: kevent just notifies us, waitpid gets the status
            const data = comp.cast(ProcessWait);

            var status: c_int = 0;
            const rc = posix.system.waitpid(data.handle, &status, 0);
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .CHILD => comp.setError(error.ProcessNotFound),
                    else => comp.setError(error.Unexpected),
                }
            } else {
                // Decode wait status (WEXITSTATUS and WTERMSIG equivalent)
                const ustatus: u32 = @bitCast(status);
                const exit_code: u8 = @intCast((ustatus >> 8) & 0xff);
                const signal_num: u8 = @intCast(ustatus & 0x7f);
                comp.setResult(.process_wait, .{
                    .code = exit_code,
                    .signal = if (signal_num != 0) signal_num else null,
                });
            }

            return .completed;
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{comp.op});
        },
    }
}
