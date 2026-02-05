// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const log = std.log.scoped(.zio);

const ev = @import("ev/root.zig");
const Duration = @import("time.zig").Duration;
const Timeout = @import("time.zig").Timeout;
const Stopwatch = @import("time.zig").Stopwatch;
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTaskOrNull = @import("runtime.zig").getCurrentTaskOrNull;
const AnyTask = @import("runtime/task.zig").AnyTask;
const Executor = @import("runtime.zig").Executor;
const WaitNode = @import("runtime/WaitNode.zig");
const thread_wait = @import("os/thread_wait.zig");

/// Error set for operations that can be cancelled
pub const Cancelable = error{
    Canceled,
};

/// Error set for operations that can timeout
pub const Timeoutable = error{
    Timeout,
};

/// Stack-allocated waiter for async operations.
///
/// This provides a common pattern for waiting with spurious wakeup handling.
/// Tracks a signal count that is atomically incremented before waking the task.
///
/// For sync primitives, the wait_node is used in wait queues.
/// For I/O operations, only the signaled field is used.
///
/// Usage:
/// ```zig
/// var waiter: Waiter = .init();
/// // Setup operation (e.g., push to queue, submit I/O)
/// try waiter.wait(1, .allow_cancel);
/// ```
pub const Waiter = struct {
    wait_node: WaitNode,
    task: ?*AnyTask,
    event: thread_wait.Event,

    const vtable: WaitNode.VTable = .{
        .wake = wakeImpl,
    };

    pub fn init() Waiter {
        return .{
            .wait_node = .{ .vtable = &vtable },
            .task = getCurrentTaskOrNull(),
            .event = .init(),
        };
    }

    /// Recover Waiter pointer from embedded WaitNode.
    /// Only valid for WaitNodes that are part of a Waiter.
    pub inline fn fromWaitNode(wait_node: *WaitNode) *Waiter {
        if (std.debug.runtime_safety) {
            std.debug.assert(wait_node.vtable == &vtable);
        }
        return @alignCast(@fieldParentPtr("wait_node", wait_node));
    }

    /// Signal this waiter and wake the task.
    /// Increments the signal count and wakes the task.
    pub fn signal(self: *Waiter) void {
        if (self.task) |task| {
            _ = self.event.state.fetchAdd(1, .release);
            task.wake();
        } else {
            self.event.signal();
        }
    }

    fn wakeImpl(wait_node: *WaitNode) void {
        fromWaitNode(wait_node).signal();
    }

    /// Wait for at least `expected` signals, handling spurious wakeups internally.
    pub fn wait(self: *Waiter, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (self.task) |task| {
            return self.waitTask(task, expected, cancel_mode);
        } else {
            return self.waitFutex(expected);
        }
    }

    fn waitFutex(self: *Waiter, expected: u32) void {
        while (true) {
            const current = self.event.state.load(.acquire);
            if (current >= expected) return;
            self.event.wait(current, null);
        }
    }

    fn waitTask(self: *Waiter, task: *AnyTask, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        task.state.store(.preparing_to_wait, .release);

        var current = self.event.state.load(.acquire);
        if (current >= expected) {
            task.state.store(.ready, .release);
            return;
        }

        while (true) {
            const executor = task.getExecutor();
            if (cancel_mode == .allow_cancel) {
                try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);
            } else {
                executor.yield(.preparing_to_wait, .waiting, .no_cancel);
            }

            current = self.event.state.load(.acquire);
            if (current >= expected) {
                return;
            }
            task.state.store(.preparing_to_wait, .release);
        }
    }

    fn timedWaitFutex(self: *Waiter, expected: u32, timeout: Timeout) void {
        if (timeout == .none) {
            return self.waitFutex(expected);
        }

        const deadline = timeout.toDeadline();
        while (true) {
            const current = self.event.state.load(.acquire);
            if (current >= expected) {
                return;
            }
            const remaining = deadline.durationFromNow();
            if (remaining.value <= 0) {
                return;
            }
            self.event.wait(current, remaining);
        }
    }

    fn timedWaitTask(self: *Waiter, task: *AnyTask, expected: u32, timeout: Timeout, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (timeout == .none) {
            return self.waitTask(task, expected, cancel_mode);
        }

        var timer: ev.Timer = .init(timeout);
        timer.c.userdata = self;
        timer.c.callback = callback;

        task.getExecutor().loop.setTimer(&timer, timeout);
        defer timer.c.loop.?.clearTimer(&timer);

        return self.waitTask(task, expected, cancel_mode);
    }

    /// Wait for at least `expected` signals with a timeout.
    /// The caller must check their condition to determine if timeout actually won
    /// (e.g., by trying to remove from a wait queue).
    pub fn timedWait(self: *Waiter, expected: u32, timeout: Timeout, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (self.task) |task| {
            return self.timedWaitTask(task, expected, timeout, cancel_mode);
        } else {
            return self.timedWaitFutex(expected, timeout);
        }
    }

    /// Callback for ev.Completion - signals this waiter.
    /// Use with: completion.userdata = &waiter; completion.callback = Waiter.callback;
    pub fn callback(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Waiter = @ptrCast(@alignCast(c.userdata.?));
        self.signal();
    }
};

/// Runs an I/O operation to completion.
/// Sets up the callback, submits to the event loop, and waits for completion.
pub fn waitForIo(c: *ev.Completion) Cancelable!void {
    var waiter = Waiter.init();
    c.userdata = &waiter;
    c.callback = Waiter.callback;

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Submit to the event loop and wait for completion
    const task = waiter.task orelse @panic("I/O operations require async context");
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
        .wait_node = .{ .vtable = &Waiter.vtable },
        .task = null,
        .event = .init(),
    };

    var timer = Stopwatch.start();
    waiter.timedWait(1, .fromMilliseconds(50), .no_cancel);
    const elapsed = timer.read();

    // Should return normally after timeout expires
    try std.testing.expect(elapsed.toMilliseconds() >= 50);
    try std.testing.expect(elapsed.toMilliseconds() < 200); // Sanity check
}
