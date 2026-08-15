// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! The stderr side of `debug_io`: the locks, the writers, and the
//! `lockStderr` / `tryLockStderr` / `unlockStderr` implementations.
//!
//! stderr has two sinks, each a lock and a writer of its own, picked by the
//! calling context:
//!
//!  * the user sink, used by tasks and by threads running user code. Its
//!    holder can park inside the critical section, because the write is routed
//!    through the event loop. That is fine here: every acquirer of this
//!    sink either parks (a task, leaving its executor free to run the
//!    holder) or blocks without stopping the runtime from resuming the holder
//!    (a plain thread).
//!
//!  * the scheduler sink, used by runtime code: the event loop, marked
//!    scheduler regions (see `log.zig`), and the crash handler. None of those
//!    may park, so its holder always writes on the blocking path and releases
//!    within one write, which makes every wait for it bounded.
//!
//! Keeping them apart is what makes the deadlock in #661 impossible rather
//! than merely avoided. Runtime code never waits for a lock a parked task can
//! hold, and never writes through that task's writer, whose drain may itself
//! be suspended mid-call. The cost is that the two sinks interleave: each
//! locked section flushes once, so messages stay whole up to the buffer the
//! caller passes, but the two have no order relative to each other.

const std = @import("std");
const Io = std.Io;

const Mutex = @import("sync/Mutex.zig");
const Condition = @import("sync/Condition.zig");
const AnyTask = @import("task.zig").AnyTask;
const Cancelable = @import("common.zig").Cancelable;
const runtime = @import("runtime.zig");
const log = @import("log.zig");
const zio_fs = @import("fs.zig");
const zioFileToStd = @import("io.zig").zioFileToStd;

/// Who holds a sink. The distinction matters because only a task can park
/// while holding one.
pub const Holder = union(enum) {
    task: *AnyTask,
    thread: std.Thread.Id,

    fn eql(self: Holder, other: Holder) bool {
        return switch (self) {
            .task => |task| other == .task and other.task == task,
            .thread => |id| other == .thread and other.thread == id,
        };
    }
};

/// A recursive lock whose holder may park while holding it.
///
/// `owner` is the lock: `null` means unlocked. `mtx` only guards `owner` and
/// `depth`, and is held for those updates alone, never across the critical
/// section; waiters block on `cond`, which parks tasks and blocks threads. The
/// caller supplies its own identity, since the two sinks classify the same
/// thread differently.
pub const Lock = struct {
    mtx: Mutex = .init,
    cond: Condition = .init,
    owner: ?Holder = null,
    depth: u32 = 0,

    pub const init: Lock = .{};

    pub fn lock(self: *Lock, me: Holder) Cancelable!void {
        try self.mtx.lock();
        defer self.mtx.unlock();

        while (self.owner) |owner| {
            if (owner.eql(me)) {
                self.depth += 1;
                return;
            }
            try self.cond.wait(&self.mtx);
        }
        self.owner = me;
        self.depth = 1;
    }

    pub fn tryLock(self: *Lock, me: Holder) Cancelable!bool {
        try self.mtx.lock();
        defer self.mtx.unlock();

        if (self.owner) |owner| {
            if (!owner.eql(me)) return false;
            self.depth += 1;
            return true;
        }
        self.owner = me;
        self.depth = 1;
        return true;
    }

    /// Releasing must not be able to fail: an acquisition that could not be
    /// released would hold stderr forever, so this takes the latch
    /// uncancelable, unlike `lock`.
    pub fn unlock(self: *Lock, me: Holder) void {
        var wake = false;
        {
            self.mtx.lockUncancelable();
            defer self.mtx.unlock();

            std.debug.assert(self.owner != null and self.owner.?.eql(me));
            std.debug.assert(self.depth > 0);
            self.depth -= 1;
            if (self.depth == 0) {
                self.owner = null;
                wake = true;
            }
        }
        if (wake) self.cond.signal();
    }
};

/// A lock and the writer it protects.
const Sink = struct {
    lock: Lock = .init,
    writer: Io.File.Writer = undefined,
    writer_ready: bool = false,

    fn locked(self: *Sink, io: Io, terminal_mode: ?Io.Terminal.Mode) Io.LockedStderr {
        if (!self.writer_ready) {
            // Always streaming, even for a seekable stderr: stderr is a shared
            // stream, and positional writes track an offset private to this
            // writer, so they overwrite (and are overwritten by) anything else
            // writing to the same file description -- the other sink, child
            // processes, external tools. Streaming writes advance the shared
            // file offset, so every writer appends after the others.
            self.writer = .initStreaming(zioFileToStd(zio_fs.stderr()), io, &.{});
            self.writer_ready = true;
        }
        return .{
            .file_writer = &self.writer,
            .terminal_mode = terminal_mode orelse .no_color,
        };
    }

    fn flush(self: *Sink) void {
        if (self.writer.err == null) self.writer.interface.flush() catch {};
        self.writer.err = null;
    }
};

var user_sink: Sink = .{};
var scheduler_sink: Sink = .{};

/// Set by the crash handler, never cleared: the thread is on its way to
/// `abort()`. It puts panic output on the scheduler sink, which matters on
/// threads the checks below cannot otherwise classify.
threadlocal var crashed: bool = false;

pub fn markCrashed() void {
    crashed = true;
}

const Context = struct {
    /// Whether this caller uses the scheduler sink.
    scheduler: bool,
    holder: Holder,
};

/// Classifies the caller. A task marker means task context; its absence on an
/// executor thread means the run loop; the flag from `log.zig` covers marked
/// scheduler regions on any thread, including a task's own stack. Everything
/// else, including thread-pool workers running user code, is user context.
fn currentContext() Context {
    const thread: Context = .{ .scheduler = true, .holder = .{ .thread = std.Thread.getCurrentId() } };
    if (crashed or log.inSchedulerContext()) return thread;
    if (runtime.getCurrentExecutorOrNull()) |exec| {
        const task = exec.current_task orelse return thread;
        return .{ .scheduler = false, .holder = .{ .task = task } };
    }
    return .{ .scheduler = false, .holder = .{ .thread = std.Thread.getCurrentId() } };
}

fn sinkFor(context: Context) *Sink {
    if (!context.scheduler) return &user_sink;
    // Everything reaching the scheduler sink must have no current task, so
    // its write takes the blocking path and the lock is never held across a
    // suspension. That is what makes waiting for it bounded, including for the
    // panic handler. Scheduler regions and the crash handler clear the marker
    // (see log.zig); the run loop and foreign threads have no task to begin
    // with.
    std.debug.assert(runtime.getCurrentTaskOrNull() == null);
    return &scheduler_sink;
}

pub fn lock(io: Io, terminal_mode: ?Io.Terminal.Mode) Cancelable!Io.LockedStderr {
    const context = currentContext();
    const sink = sinkFor(context);
    try sink.lock.lock(context.holder);
    // A no-op outside task context, which is every scheduler-sink caller.
    runtime.beginShield();
    return sink.locked(io, terminal_mode);
}

pub fn tryLock(io: Io, terminal_mode: ?Io.Terminal.Mode) Cancelable!?Io.LockedStderr {
    const context = currentContext();
    const sink = sinkFor(context);
    if (!try sink.lock.tryLock(context.holder)) return null;
    runtime.beginShield();
    return sink.locked(io, terminal_mode);
}

pub fn unlock() void {
    // The context cannot have changed since the matching lock: scheduler
    // regions enclose their locked sections, and the crash marker is only ever
    // set, so a section that started on one sink ends on the same one.
    const context = currentContext();
    const sink = sinkFor(context);
    sink.flush();
    runtime.endShield();
    sink.lock.unlock(context.holder);
}

test "stderr lock: re-entry from the same task" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const me = currentContext().holder;
    try std.testing.expectEqual(Holder.task, std.meta.activeTag(me));

    var l: Lock = .init;
    try l.lock(me);
    try l.lock(me);
    try std.testing.expectEqual(2, l.depth);

    l.unlock(me);
    try std.testing.expect(l.owner != null);
    l.unlock(me);
    try std.testing.expect(l.owner == null);
}

test "stderr lock: a scheduler region is a different holder than its task" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const task_context = currentContext();
    try std.testing.expect(!task_context.scheduler);

    var l: Lock = .init;
    try l.lock(task_context.holder);
    defer l.unlock(task_context.holder);

    // Inside a scheduler region the same thread is a different holder, and is
    // routed to the other sink, so it must not be taken for the task
    // re-entering this lock.
    const region = log.enterSchedulerContext();
    defer log.exitSchedulerContext(region);

    const scheduler_context = currentContext();
    try std.testing.expect(scheduler_context.scheduler);
    try std.testing.expect(!task_context.holder.eql(scheduler_context.holder));
    try std.testing.expect(!try l.tryLock(scheduler_context.holder));
}

test "stderr lock: re-entry from the same scheduler thread" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const region = log.enterSchedulerContext();
    defer log.exitSchedulerContext(region);

    const me = currentContext().holder;
    try std.testing.expectEqual(Holder.thread, std.meta.activeTag(me));

    var l: Lock = .init;
    try l.lock(me);
    // What the panic handler does when the crashing thread already held it.
    try l.lock(me);
    try std.testing.expectEqual(2, l.depth);

    l.unlock(me);
    l.unlock(me);
    try std.testing.expect(l.owner == null);
}

test "stderr lock: a task waits for another task and is handed the lock" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    const Shared = struct {
        l: Lock = .init,
        order: [2]u8 = .{ 0, 0 },
        next: u8 = 0,

        fn contend(self: *@This(), id: u8) !void {
            const me = currentContext().holder;
            try self.l.lock(me);
            defer self.l.unlock(me);
            self.order[self.next] = id;
            self.next += 1;
            // Hold across a suspension, which is the case this lock exists
            // for: the waiter must park rather than spin.
            try runtime.sleep(.fromMilliseconds(20));
        }
    };

    var shared: Shared = .{};
    var first = try rt.spawn(Shared.contend, .{ &shared, 1 });
    try runtime.sleep(.fromMilliseconds(5));
    var second = try rt.spawn(Shared.contend, .{ &shared, 2 });

    try first.join();
    try second.join();

    try std.testing.expectEqual([2]u8{ 1, 2 }, shared.order);
    try std.testing.expect(shared.l.owner == null);
}
