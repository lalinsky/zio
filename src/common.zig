// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub const log = std.log.scoped(.zio);

const ev = @import("ev/root.zig");
const Timeout = @import("time.zig").Timeout;
const Clock = @import("time.zig").Clock;
const Timestamp = @import("time.zig").Timestamp;
const Stopwatch = @import("time.zig").Stopwatch;
const Duration = @import("time.zig").Duration;
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
        return self.timedWaitClock(expected, timeout, .awake, cancel_mode);
    }

    /// Like `timedWait`, but the timeout is measured against `clock`. The
    /// no-task futex fallback only supports the monotonic (`awake`) clock, so
    /// boot/real timeouts there degrade to awake semantics.
    pub fn timedWaitClock(self: *Waiter, expected: u32, timeout: Timeout, clock: Clock, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (timeout == .none) {
            return self.wait(expected, cancel_mode);
        }

        const d = &self.mode.direct;
        const task = d.task orelse return timedWaitFutex(d, expected, futexTimeout(timeout, clock));

        var timer: ev.Timer = .initClock(timeout, clock);
        timer.c.userdata = self;
        timer.c.callback = callback;

        task.getExecutor().loop.setTimer(&timer, timeout);
        defer timer.c.getLoop().?.clearTimer(&timer);

        return waitTask(d, task, expected, cancel_mode);
    }

    fn waitFutex(d: *Direct, expected: u32) void {
        while (true) {
            const current = d.notify.state.load(.acquire);
            if (current >= expected) return;
            d.notify.wait(current);
        }
    }

    /// Collapse a wall-clock (boot/real) deadline into a monotonic-relative
    /// duration for the no-task futex fallback, which can only wait on the
    /// monotonic clock. Without this, `timedWaitFutex` would compare an
    /// absolute realtime timestamp (~ns since 1970) against monotonic time and
    /// wait for decades. Best-effort: it snapshots the remaining time once and
    /// loses suspend/step semantics.
    ///
    /// TODO: support boot/real natively on this path. The Linux futex can wait
    /// against CLOCK_REALTIME (FUTEX_WAIT_BITSET | FUTEX_CLOCK_REALTIME), so a
    /// no-task wait on a real deadline could be exact rather than converted.
    fn futexTimeout(timeout: Timeout, clock: Clock) Timeout {
        return switch (timeout) {
            .none, .duration => timeout,
            .deadline => |deadline| .{ .duration = Timestamp.now(clock).durationTo(deadline) },
        };
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
        var current = d.notify.state.load(.acquire);
        if (current >= expected) return;

        // Park loop: yield until the condition is met.
        //
        // Race safety: if a signal fires while the task is in .ready state (between
        // the condition check above and the actual context switch in yield), the waker
        // sets the `awaken` bit. `processCleanup.park` then consumes the bit and
        // reschedules the task instead of transitioning it to .waiting, so the wake
        // is never lost.
        while (true) {
            if (cancel_mode == .allow_cancel) {
                try task.yield(.park, .allow_cancel);
            } else {
                task.yield(.park, .no_cancel);
            }

            current = d.notify.state.load(.acquire);
            if (current >= expected) return;
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
    // The callback only wakes the parked task — nothing that needs the
    // deferred-finish safety net, and the hot path skips the queue round trip.
    c.flags = .{ .defer_callback = false }; // single-shot wait: no rearm either

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, if (builtin.single_threaded) std.heap.c_allocator else std.heap.smp_allocator);
        return;
    };

    // Async path: Submit to the event loop and wait for completion
    task.getExecutor().loop.add(c);
    // Inline completions never park; charge the coop budget so they still
    // hit a yield point.
    const completed_inline = waiter.mode.direct.notify.state.load(.acquire) != 0;
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
    if (completed_inline) {
        task.getExecutor().maybeYield(.reschedule, .no_cancel);
    }
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
    c.flags = .{ .defer_callback = false };

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, if (builtin.single_threaded) std.heap.c_allocator else std.heap.smp_allocator);
        return;
    };

    // Async path: Submit to the event loop and wait for completion (no cancel)
    task.getExecutor().loop.add(c);
    const completed_inline = waiter.mode.direct.notify.state.load(.acquire) != 0;
    waiter.wait(1, .no_cancel);
    if (completed_inline) {
        task.getExecutor().maybeYield(.reschedule, .no_cancel);
    }
}

/// Runs an I/O operation to completion with a timeout.
/// If the timeout expires before the I/O completes, returns `error.Timeout`.
/// If the timeout is `.none`, waits indefinitely (just calls `waitForIo`).
pub fn timedWaitForIo(c: *ev.Completion, timeout: Timeout) (Timeoutable || Cancelable)!void {
    return timedWaitForIoClock(c, timeout, .awake);
}

/// Like `timedWaitForIo`, but the timeout is measured against `clock`.
pub fn timedWaitForIoClock(c: *ev.Completion, timeout: Timeout, clock: Clock) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return waitForIo(c);
    }

    var group = ev.Group.init(.race);
    var timer = ev.Timer.initClock(timeout, clock);

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

    errdefer std.debug.print("timedWait(50ms) returned after {d}ms\n", .{elapsed.toMilliseconds()});

    // Should return normally after timeout expires (allow slight undershoot for timer resolution)
    try std.testing.expect(elapsed.toMilliseconds() >= 40);
    // Generous upper bound: only meant to catch gross timeout miscalculation
    // (wrong units, waiting forever). Loaded CI runners can delay the wakeup
    // by hundreds of milliseconds, so anything tighter is flaky.
    try std.testing.expect(elapsed.toMilliseconds() < 5000);
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
    };

    var ctx: Context = .{ .args = args };

    // Outside a task there is no event loop / thread pool to hand off to, so run
    // the function inline on the calling thread.
    if (getCurrentTaskOrNull() == null) {
        return @call(.auto, func, args);
    }

    var token: os.syscall_cancel.Token = .{};
    var work = ev.Work.init(Context.workFn, &ctx);
    work.cancel_token = &token;

    // Submit to the thread pool and wait through the event loop. The loop owns
    // completion delivery — it finalizes work.c and signals the waiter on the
    // loop thread as the *last* step — and cancellation: loop.cancel interrupts
    // a blocking cancelable syscall via SIGURG and resends each tick until the
    // worker acknowledges (see Loop.cancel_resend). Unlike a direct worker-thread
    // completion callback, nothing touches this stack frame after we might
    // return, so there is no use-after-free window.
    //
    // workFn always runs (token-bearing work is never dropped from the queue),
    // so ctx.result is always valid. A canceled syscall makes `func` return
    // error.Canceled, which surfaces here as that result; waitForIo re-arms the
    // task's pending cancellation before returning.
    //
    // waitForIo only fails with error.Canceled, and only when the *completion*
    // carries a Canceled result — which happens on the drop path, where workFn
    // never runs and ctx.result would be undefined. Token-bearing work is never
    // dropped (it always completes via setResult, cancellation delivered in-band
    // through func's return), so this is unreachable. Assert it: were it ever to
    // fire we would be returning uninitialized ctx.result, which we would much
    // rather crash on.
    waitForIo(&work.c) catch unreachable;

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

test "blockInPlace: cancellation interrupts a blocking syscall on the worker" {
    if (!os.syscall_cancel.enabled) return;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // A worker function that blocks in a cancelable read on an empty pipe. When
    // the owning task is canceled, the read must be interrupted via SIGURG and
    // return error.Canceled — which blockInPlace surfaces as its result.
    const worker = struct {
        fn cancelableRead(fd: std.c.fd_t, ready: *std.atomic.Value(bool)) error{ Canceled, Unexpected }!void {
            const sc = try os.syscall_cancel.Syscall.begin();
            defer sc.finish();
            // Signal that we are inside the cancelable region, just before read().
            ready.store(true, .release);
            var buf: [1]u8 = undefined;
            while (true) {
                const rc = std.c.read(fd, &buf, buf.len);
                if (rc >= 0) return error.Unexpected;
                switch (std.posix.errno(rc)) {
                    .INTR => {
                        try sc.checkCancel();
                        continue;
                    },
                    else => return error.Unexpected,
                }
            }
        }

        fn call(read_fd: std.c.fd_t, ready: *std.atomic.Value(bool)) !void {
            const result = blockInPlace(cancelableRead, .{ read_fd, ready });
            try std.testing.expectError(error.Canceled, result);
        }
    };

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ready = std.atomic.Value(bool).init(false);
    var handle = try rt.spawn(worker.call, .{ fds[0], &ready });

    // Wait until the worker is inside the cancelable region (after begin() but
    // before read()), then cancel the task.
    while (!ready.load(.acquire)) try rt.sleep(.fromMicroseconds(100));
    handle.cancel();

    // The worker catches the cancellation and returns normally, so join succeeds.
    try handle.join();
}
