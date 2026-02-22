// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const log = std.log.scoped(.zio);

const ev = @import("ev/root.zig");
const Timeout = @import("time.zig").Timeout;
const Stopwatch = @import("time.zig").Stopwatch;
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTaskOrNull = @import("runtime.zig").getCurrentTaskOrNull;
const AnyTask = @import("task.zig").AnyTask;
const Executor = @import("runtime.zig").Executor;
const WaitNode = @import("utils/wait_queue.zig").WaitNode;
const os = @import("os/root.zig");

/// Error set for operations that can be cancelled
pub const Cancelable = error{
    Canceled,
};

/// Error set for operations that can timeout
pub const Timeoutable = error{
    Timeout,
};

/// Sentinel value indicating no winner has been selected yet in select operations
pub const NO_WINNER = std.math.maxInt(usize);

/// Stack-allocated waiter for async operations.
///
/// Supports two modes:
/// - `direct`: For single-future waiting. Owns the task and notify.
/// - `select`: For multi-future select(). Points to a parent direct waiter.
///
/// Usage:
/// ```zig
/// var waiter = Waiter.init();
/// future.asyncWait(&waiter);
/// try waiter.wait(1, .allow_cancel);
/// ```
pub const Waiter = struct {
    node: WaitNode = .{},
    mode: union(enum) {
        direct: Direct,
        select: Select,
    },

    /// Direct waiter for single-future waiting.
    pub const Direct = struct {
        notify: os.thread.Notify,
        task: ?*AnyTask,

        pub fn init() Direct {
            return .{
                .notify = .init(),
                .task = getCurrentTaskOrNull(),
            };
        }
    };

    /// Select waiter for multi-future select().
    pub const Select = struct {
        parent: *Waiter,
        winner: *std.atomic.Value(usize),
        index: usize,

        pub fn init(parent: *Waiter, winner: *std.atomic.Value(usize), index: usize) Select {
            return .{
                .parent = parent,
                .winner = winner,
                .index = index,
            };
        }
    };

    /// Initialize a direct waiter for single-future waiting.
    pub fn init() Waiter {
        return .{
            .mode = .{ .direct = Direct.init() },
        };
    }

    /// Initialize a select waiter for multi-future select().
    pub fn initSelect(parent: *Waiter, winner: *std.atomic.Value(usize), index: usize) Waiter {
        return .{
            .mode = .{ .select = Select.init(parent, winner, index) },
        };
    }

    /// Recover Waiter pointer from embedded WaitNode.
    pub inline fn fromNode(node: *WaitNode) *Waiter {
        return @fieldParentPtr("node", node);
    }

    /// Signal this waiter.
    /// For direct: increments signal count and wakes the task.
    /// For select: tries to claim winner slot, then signals the parent.
    pub fn signal(self: *Waiter) void {
        switch (self.mode) {
            .direct => |*d| {
                if (d.task) |task| {
                    _ = d.notify.state.fetchAdd(1, .release);
                    task.wake();
                } else {
                    d.notify.signal();
                }
            },
            .select => |*s| {
                // Try to claim winner slot with our index (may already be claimed)
                _ = s.winner.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire);
                // Always signal parent - needed for both winner notification and
                // cleanup synchronization (waiting for in-flight wakes to complete)
                s.parent.signal();
            },
        }
    }

    /// Try to claim this waiter as a winner in select().
    /// Returns true if claimed (or if direct waiter), false if another waiter already won.
    pub fn tryClaim(self: *Waiter) bool {
        return switch (self.mode) {
            .direct => true,
            .select => |*s| s.winner.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire) == null,
        };
    }

    /// Check if this waiter won its select (was claimed).
    /// Returns true if won (or if direct waiter).
    pub fn didWin(self: *const Waiter) bool {
        return switch (self.mode) {
            .direct => true,
            .select => |s| s.winner.load(.acquire) == s.index,
        };
    }

    /// Wait for at least `expected` signals, handling spurious wakeups internally.
    /// Only valid for direct waiters.
    pub fn wait(self: *Waiter, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        const d = &self.mode.direct;
        if (d.task) |task| {
            return waitTask(d, task, expected, cancel_mode);
        } else {
            return waitFutex(d, expected);
        }
    }

    /// Wait for at least `expected` signals with a timeout.
    /// The caller must check their condition to determine if timeout actually won
    /// (e.g., by trying to remove from a wait queue).
    /// Only valid for direct waiters.
    pub fn timedWait(self: *Waiter, expected: u32, timeout: Timeout, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (timeout == .none) {
            return self.wait(expected, cancel_mode);
        }

        const d = &self.mode.direct;
        const task = d.task orelse return timedWaitFutex(d, expected, timeout);

        var timer: ev.Timer = .init(timeout);
        timer.c.userdata = self;
        timer.c.callback = callback;

        task.getExecutor().loop.setTimer(&timer, timeout);
        defer timer.c.loop.?.clearTimer(&timer);

        return waitTask(d, task, expected, cancel_mode);
    }

    fn waitFutex(d: *Direct, expected: u32) void {
        while (true) {
            const current = d.notify.state.load(.acquire);
            if (current >= expected) return;
            d.notify.wait(current);
        }
    }

    fn timedWaitFutex(d: *Direct, expected: u32, timeout: Timeout) void {
        const deadline = timeout.toDeadline();
        while (true) {
            const current = d.notify.state.load(.acquire);
            if (current >= expected) {
                return;
            }
            const remaining = deadline.durationFromNow();
            if (remaining.value <= 0) {
                return;
            }
            d.notify.timedWait(current, remaining) catch return;
        }
    }

    fn waitTask(d: *Direct, task: *AnyTask, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        task.state.store(.preparing_to_wait, .release);

        var current = d.notify.state.load(.acquire);
        if (current >= expected) {
            task.state.store(.ready, .release);
            return;
        }

        while (true) {
            if (cancel_mode == .allow_cancel) {
                try task.yield(.park, .allow_cancel);
            } else {
                task.yield(.park, .no_cancel);
            }

            current = d.notify.state.load(.acquire);
            if (current >= expected) {
                return;
            }
            task.state.store(.preparing_to_wait, .release);
        }
    }

    /// Callback for ev.Completion - signals this waiter.
    pub fn callback(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Waiter = @ptrCast(@alignCast(c.userdata.?));
        self.signal();
    }
};

/// Runs an I/O operation to completion.
/// Sets up the callback, submits to the event loop, and waits for completion.
///
/// If called from a context with an async runtime, uses the event loop.
/// If called from a context without a runtime, executes the operation synchronously.
pub fn waitForIo(c: *ev.Completion) Cancelable!void {
    var waiter = Waiter.init();
    c.userdata = &waiter;
    c.callback = Waiter.callback;

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, std.heap.smp_allocator);
        return;
    };

    // Async path: Submit to the event loop and wait for completion
    task.getExecutor().loop.add(c);
    waiter.wait(1, .allow_cancel) catch |err| switch (err) {
        error.Canceled => {
            // On cancellation, cancel the I/O and wait for completion
            task.getExecutor().loop.cancel(c);
            waiter.wait(1, .no_cancel);

            // Check if I/O was actually canceled
            if (c.err) |io_err| {
                if (io_err == error.Canceled) {
                    return error.Canceled;
                }
            }
            // IO completed successfully despite cancel request - restore the pending cancel
            task.recancel();
            return;
        },
    };
}

/// Runs an I/O operation to completion without allowing cancellation.
/// This is used for cleanup operations like close() that must complete.
///
/// If called from a context with an async runtime, uses the event loop (no cancel).
/// If called from a context without a runtime, executes the operation synchronously.
pub fn waitForIoUncancelable(c: *ev.Completion) void {
    var waiter = Waiter.init();
    c.userdata = &waiter;
    c.callback = Waiter.callback;

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, std.heap.smp_allocator);
        return;
    };

    // Async path: Submit to the event loop and wait for completion (no cancel)
    task.getExecutor().loop.add(c);
    waiter.wait(1, .no_cancel);
}

/// Runs an I/O operation to completion with a timeout.
/// If the timeout expires before the I/O completes, returns `error.Timeout`.
/// If the timeout is `.none`, waits indefinitely (just calls `waitForIo`).
pub fn timedWaitForIo(c: *ev.Completion, timeout: Timeout) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return waitForIo(c);
    }

    var group = ev.Group.init(.race);
    var timer = ev.Timer.init(timeout);

    group.add(c);
    group.add(&timer.c);

    try waitForIo(&group.c);

    // Check if the IO was cancelled by the timeout
    // (both could complete in a race, so check if I/O was actually cancelled)
    if (timer.c.err == null) {
        if (c.err) |io_err| {
            if (io_err == error.Canceled) {
                return error.Timeout;
            }
        }
    }
}

test "waitForIo: basic timer completion" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try waitForIo(&timer.c);
}

test "timedWaitForIo: timeout interrupts long operation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Long timer (1 second) with short timeout (10ms)
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(1) });
    try std.testing.expectError(error.Timeout, timedWaitForIo(&timer.c, .fromMilliseconds(10)));
}

test "timedWaitForIo: completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Short timer (10ms) with long timeout (1 second)
    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try timedWaitForIo(&timer.c, .{ .duration = .fromSeconds(1) });
}

test "Waiter: futex-based timed wait with timeout" {
    // Create waiter without task (blocking context)
    var waiter: Waiter = .{
        .mode = .{ .direct = .{
            .task = null,
            .notify = .init(),
        } },
    };

    var timer = Stopwatch.start();
    waiter.timedWait(1, .fromMilliseconds(50), .no_cancel);
    const elapsed = timer.read();

    // Should return normally after timeout expires (allow slight undershoot for timer resolution)
    try std.testing.expect(elapsed.toMilliseconds() >= 40);
    try std.testing.expect(elapsed.toMilliseconds() < 200); // Sanity check
}

/// Execute a blocking function on the thread pool, blocking the current task until completion.
///
/// Unlike `spawnBlocking`, this does not allocate - all state is kept on the stack.
/// The calling task is parked while the blocking work executes on a thread pool worker.
///
/// Usage:
/// ```zig
/// const result = zio.blockInPlace(expensiveComputation, .{arg1, arg2});
/// ```
pub fn blockInPlace(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) meta.ReturnType(func) {
    const Args = @TypeOf(args);
    const Result = meta.ReturnType(func);

    const Context = struct {
        args: Args,
        result: Result = undefined,

        fn workFn(work: *ev.Work) void {
            const ctx: *@This() = @ptrCast(@alignCast(work.userdata.?));
            ctx.result = @call(.auto, func, ctx.args);
        }

        fn completionFn(completion_ctx: ?*anyopaque, _: *ev.Work) void {
            const waiter: *Waiter = @ptrCast(@alignCast(completion_ctx.?));
            waiter.signal();
        }
    };

    var ctx: Context = .{ .args = args };
    var waiter: Waiter = .init();

    // If not in a task context, just run the function directly
    const task = waiter.mode.direct.task orelse {
        return @call(.auto, func, args);
    };

    var work = ev.Work.init(Context.workFn, &ctx);
    work.completion_fn = Context.completionFn;
    work.completion_context = &waiter;

    const thread_pool = task.getThreadPool();
    thread_pool.submit(&work);

    waiter.wait(1, .allow_cancel) catch {
        // Try to cancel the work, but must wait for completion either way
        // since context is stack-allocated
        thread_pool.cancel(&work);
        waiter.wait(1, .no_cancel);
    };

    return ctx.result;
}

const meta = @import("meta.zig");

test "blockInPlace: basic computation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const double = struct {
        fn call(x: i32) i32 {
            return x * 2;
        }
    }.call;

    const result = blockInPlace(double, .{21});
    try std.testing.expectEqual(42, result);
}
