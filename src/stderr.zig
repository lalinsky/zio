// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! The stderr side of `debug_io`: the locks, the writers, and the
//! `lockStderr` / `tryLockStderr` / `unlockStderr` implementations.
//!
//! stderr has one primary sink -- the user lock and writer -- and a fallback.
//! User context (a task, or a thread running user code) always takes the user
//! sink and may park while holding it: a task leaves its executor free to run
//! whoever it waits on, a plain thread blocks without stopping the runtime.
//!
//! A no-suspend caller (the run loop, a `loopAdd`/`loopCancel` region, the
//! crash handler; see `runtime.getWaitableTaskOrNull`) must not park and must
//! never wait for a holder that can. It still prefers the user sink, so that
//! output stays in one stream whenever possible:
//!
//!  * user lock free: take it, write on the blocking path, release within
//!    the section.
//!  * held by a thread: wait for it. Thread holders write on the blocking
//!    path and cannot park, so the wait is bounded.
//!  * held by a task: the task may be parked, and waiting for it from the
//!    machinery that has to resume it is the #661 deadlock. Divert to the
//!    scheduler sink, whose holders are only ever no-suspend callers, so
//!    every wait for it is bounded too.
//!
//! On the crash path there is one more case: the user lock held by the task
//! mounted on the crashing thread itself. That task is mid-panic on this very
//! stack and will never resume, so the panic handler re-enters its lock and
//! takes it over rather than diverting, and the panic message lands in the
//! same stream the task was writing to.
//!
//! The cost of the fallback is that the two sinks interleave: each locked
//! section flushes once, so messages stay whole up to the buffer the caller
//! passes, but the two streams have no order relative to each other. This
//! only happens while a task actually holds the user lock.

const std = @import("std");
const zio_options = @import("options.zig").options;
const Io = std.Io;

const Mutex = @import("sync/Mutex.zig");
const Condition = @import("sync/Condition.zig");
const AnyTask = @import("task.zig").AnyTask;
const Cancelable = @import("common.zig").Cancelable;
const runtime = @import("runtime.zig");
const zio_fs = @import("fs.zig");
const zioFileToStd = @import("io.zig").zioFileToStd;

/// Who holds a sink. The distinction matters because only a task can park
/// while holding one, and because a task keeps its identity when it migrates
/// to another executor thread mid-section.
pub const Holder = union(enum) {
    task: *AnyTask,
    thread: std.Thread.Id,
};

/// A recursive lock whose holder may park while holding it.
///
/// `owner` is the lock: `null` means unlocked. `mtx` only guards `owner` and
/// `depth`, and is held for those updates alone, never across the critical
/// section; waiters block on `cond`, which parks tasks and blocks threads
/// (inside a no-suspend region the waiter carries no task, so it blocks).
/// The caller supplies its own identity, since a no-suspend region on a
/// task's stack must not be mistaken for the task.
pub const Lock = struct {
    mtx: Mutex = .init,
    cond: Condition = .init,
    owner: ?Holder = null,
    depth: u32 = 0,

    pub const init: Lock = .{};

    /// User-context acquire: parks (or blocks, for a plain thread) until the
    /// lock is free, recursively per holder.
    pub fn lock(self: *Lock, me: Holder) Cancelable!void {
        try self.mtx.lock();
        defer self.mtx.unlock();

        while (self.owner) |owner| {
            if (std.meta.eql(owner, me)) {
                self.depth += 1;
                return;
            }
            self.cond.wait(&self.mtx) catch |err| {
                // A wake consumed on the way into a cancel must not die with
                // us: if the lock is free, hand it to the next waiter.
                if (self.owner == null) self.cond.signal();
                return err;
            };
        }
        self.owner = me;
        self.depth = 1;
    }

    /// Never parks and never fails with an error; guard contention (a few
    /// instructions wide) counts as the lock being busy.
    pub fn tryLock(self: *Lock, me: Holder) bool {
        if (!self.mtx.tryLock()) return false;
        defer self.mtx.unlock();

        if (self.owner) |owner| {
            if (!std.meta.eql(owner, me)) return false;
            self.depth += 1;
            return true;
        }
        self.owner = me;
        self.depth = 1;
        return true;
    }

    /// No-suspend acquire: never parks, and never waits for a holder that
    /// can. Returns the holder to unlock with on success (`me`, or the owner
    /// itself on a crash takeover), or null when the owner is a task, which
    /// the caller must not wait for -- it diverts to the other sink.
    ///
    /// `takeover` is set only on the crash path and names the task mounted on
    /// the crashing thread: a lock that task holds is re-entered rather than
    /// diverted from, since the task is mid-panic on this very stack and will
    /// never resume to release it.
    ///
    /// A panic inside the few-instruction `mtx` window itself (the asserts in
    /// `unlock`, say) still deadlocks the crash handler here; accepted as
    /// vanishingly narrow next to a panic anywhere else while holding stderr,
    /// which this path handles.
    pub fn lockNoSuspend(self: *Lock, me: Holder, takeover: ?*AnyTask) ?Holder {
        self.mtx.lockUncancelable();
        defer self.mtx.unlock();

        while (self.owner) |owner| {
            if (std.meta.eql(owner, me)) {
                self.depth += 1;
                return me;
            }
            if (takeover) |task| {
                if (owner == .task and owner.task == task) {
                    self.depth += 1;
                    return owner;
                }
            }
            if (owner == .thread) {
                // Bounded: thread holders block, write, and release without
                // ever needing this thread's loop. Re-check on wake: a task
                // may have barged in, and then we must divert instead.
                self.cond.waitUncancelable(&self.mtx);
                continue;
            }
            return null;
        }
        self.owner = me;
        self.depth = 1;
        return me;
    }

    /// Like `lockNoSuspend` but without the bounded wait: a busy lock is a
    /// busy lock.
    pub fn tryLockNoSuspend(self: *Lock, me: Holder, takeover: ?*AnyTask) ?Holder {
        if (!self.mtx.tryLock()) return null;
        defer self.mtx.unlock();

        if (self.owner) |owner| {
            if (std.meta.eql(owner, me)) {
                self.depth += 1;
                return me;
            }
            if (takeover) |task| {
                if (owner == .task and owner.task == task) {
                    self.depth += 1;
                    return owner;
                }
            }
            return null;
        }
        self.owner = me;
        self.depth = 1;
        return me;
    }

    /// Releasing must not be able to fail: an acquisition that could not be
    /// released would hold stderr forever, so this takes the latch
    /// uncancelable, unlike `lock`.
    pub fn unlock(self: *Lock, me: Holder) void {
        var wake = false;
        {
            self.mtx.lockUncancelable();
            defer self.mtx.unlock();

            std.debug.assert(self.owner != null and std.meta.eql(self.owner.?, me));
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
/// `abort()`. Classifies threads the checks below cannot (a crashing foreign
/// thread), and enables the takeover of the mounted task's lock.
threadlocal var crashed: bool = false;

pub fn markCrashed() void {
    crashed = true;
}

const Context = struct {
    /// Whether this caller must not park, and so must never wait for a lock
    /// a task holds.
    no_suspend: bool,
    holder: Holder,
    /// On the crash path, the task mounted on this thread, whose user-sink
    /// lock the panic handler may take over.
    takeover: ?*AnyTask = null,
};

/// Classifies the caller. A mounted task outside a no-suspend region is task
/// context; an executor thread without one is the run loop; the region depth
/// covers `loopAdd`/`loopCancel` and explicit regions on any executor thread,
/// including a task's own stack. Everything else, including thread-pool
/// workers running user code, is user thread context.
fn currentContext() Context {
    if (crashed) {
        return .{
            .no_suspend = true,
            .holder = .{ .thread = std.Thread.getCurrentId() },
            .takeover = runtime.getCurrentTaskOrNull(),
        };
    }
    if (runtime.getCurrentExecutorOrNull()) |exec| {
        if (exec.no_suspend == 0) {
            if (exec.current_task) |task| {
                return .{ .no_suspend = false, .holder = .{ .task = task } };
            }
        }
        return .{ .no_suspend = true, .holder = .{ .thread = std.Thread.getCurrentId() } };
    }
    return .{ .no_suspend = false, .holder = .{ .thread = std.Thread.getCurrentId() } };
}

/// Which sink each nested no-suspend section on this thread took, pushed at
/// lock time and popped by unlock. Needed because the choice depends on lock
/// state at lock time (a no-suspend caller diverts only when the user lock is
/// task-held), so unlock cannot re-derive it. No-suspend sections never park,
/// so they open and close on one thread; user sections are NOT recorded here
/// -- their holder may migrate between executor threads while parked, and
/// unlock re-derives them instead (always the user sink, held as the current
/// task or thread).
const Section = struct {
    sink: *Sink,
    holder: Holder,
};
threadlocal var sections: [8]Section = undefined;
threadlocal var section_count: u8 = 0;

pub fn lock(io: Io, terminal_mode: ?Io.Terminal.Mode) Cancelable!Io.LockedStderr {
    const context = currentContext();
    if (!context.no_suspend) {
        try user_sink.lock.lock(context.holder);
        runtime.beginShield();
        return user_sink.locked(io, terminal_mode);
    }

    var sink = &user_sink;
    const holder = user_sink.lock.lockNoSuspend(context.holder, context.takeover) orelse blk: {
        sink = &scheduler_sink;
        // The scheduler sink only ever has no-suspend (thread) holders, so
        // this cannot divert in turn.
        break :blk scheduler_sink.lock.lockNoSuspend(context.holder, null) orelse unreachable;
    };
    pushSection(.{ .sink = sink, .holder = holder });
    runtime.beginShield();
    return sink.locked(io, terminal_mode);
}

pub fn tryLock(io: Io, terminal_mode: ?Io.Terminal.Mode) Cancelable!?Io.LockedStderr {
    const context = currentContext();
    if (!context.no_suspend) {
        if (!user_sink.lock.tryLock(context.holder)) return null;
        runtime.beginShield();
        return user_sink.locked(io, terminal_mode);
    }

    var sink = &user_sink;
    const holder = user_sink.lock.tryLockNoSuspend(context.holder, context.takeover) orelse blk: {
        sink = &scheduler_sink;
        break :blk scheduler_sink.lock.tryLockNoSuspend(context.holder, null) orelse return null;
    };
    pushSection(.{ .sink = sink, .holder = holder });
    runtime.beginShield();
    return sink.locked(io, terminal_mode);
}

pub fn unlock() void {
    // The classification cannot have changed since the matching lock: user
    // sections may migrate threads but stay user context (regions strictly
    // enclose their locked sections, and a panic never returns to run an
    // unlock), and no-suspend sections never suspend, so their stack entry is
    // popped on the thread that pushed it.
    const context = currentContext();
    if (!context.no_suspend) {
        user_sink.flush();
        runtime.endShield();
        user_sink.lock.unlock(context.holder);
        return;
    }

    const section = popSection() orelse return;
    section.sink.flush();
    runtime.endShield();
    section.sink.lock.unlock(section.holder);
}

/// Sections that did not fit on the stack, so that `popSection` stays paired
/// with `pushSection`. Counted rather than stored: without this, the matching
/// unlock would pop somebody else's entry and release a lock it never took.
threadlocal var dropped_sections: u8 = 0;

fn pushSection(section: Section) void {
    // Only re-entry stacks these up (a panic inside a locked section), so eight
    // is deep. Checked in every build mode, not just where asserts survive: an
    // overflow here corrupts the neighbouring thread-locals, on the crash path.
    // Dropping leaks one level of recursion depth and leaves stderr locked,
    // which beats aborting silently on a thread already headed for abort().
    if (section_count == sections.len) {
        dropped_sections +|= 1;
        return;
    }
    sections[section_count] = section;
    section_count += 1;
}

/// Null when the matching push was dropped; the caller then leaves the sink
/// locked. See `pushSection`.
fn popSection() ?Section {
    if (dropped_sections > 0) {
        dropped_sections -= 1;
        return null;
    }
    std.debug.assert(section_count > 0);
    section_count -= 1;
    return sections[section_count];
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

test "stderr lock: a no-suspend region diverts from a task-held lock" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const task_context = currentContext();
    try std.testing.expect(!task_context.no_suspend);

    var l: Lock = .init;
    try l.lock(task_context.holder);
    defer l.unlock(task_context.holder);

    // Inside a no-suspend region the same thread is a different holder: it
    // must not re-enter the task's lock, and must not wait for it either.
    runtime.beginNoSuspend();
    defer runtime.endNoSuspend();

    const ns_context = currentContext();
    try std.testing.expect(ns_context.no_suspend);
    try std.testing.expect(!std.meta.eql(task_context.holder, ns_context.holder));
    try std.testing.expect(l.lockNoSuspend(ns_context.holder, null) == null);
    try std.testing.expect(l.tryLockNoSuspend(ns_context.holder, null) == null);
}

test "stderr lock: re-entry from the same no-suspend thread" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    runtime.beginNoSuspend();
    defer runtime.endNoSuspend();

    const me = currentContext().holder;
    try std.testing.expectEqual(Holder.thread, std.meta.activeTag(me));

    var l: Lock = .init;
    try std.testing.expect(l.lockNoSuspend(me, null) != null);
    try std.testing.expect(l.lockNoSuspend(me, null) != null);
    try std.testing.expectEqual(2, l.depth);

    l.unlock(me);
    l.unlock(me);
    try std.testing.expect(l.owner == null);
}

test "stderr lock: the crash path takes over the mounted task's lock" {
    const rt = try runtime.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const task = runtime.getCurrentTask();
    const task_holder: Holder = .{ .task = task };

    var l: Lock = .init;
    try l.lock(task_holder);

    // What the panic handler does when the crashing thread's own task holds
    // the lock: re-enter it instead of diverting, unlock with the owner's
    // identity.
    const me: Holder = .{ .thread = std.Thread.getCurrentId() };
    const acquired = l.lockNoSuspend(me, task) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(acquired, task_holder));
    try std.testing.expectEqual(2, l.depth);

    l.unlock(acquired);
    l.unlock(task_holder);
    try std.testing.expect(l.owner == null);
}

test "stderr lock: a task waits for another task and is handed the lock" {
    if (comptime !zio_options.scheduling.multiExecutor()) return error.SkipZigTest;
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
