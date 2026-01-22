// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const ev = @import("ev/root.zig");
const Duration = @import("time.zig").Duration;
const Timeout = @import("time.zig").Timeout;
const Runtime = @import("runtime.zig").Runtime;
const AnyTask = @import("runtime/task.zig").AnyTask;
const Executor = @import("runtime.zig").Executor;
const WaitNode = @import("runtime/WaitNode.zig");

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
/// Tracks a signaled state that is atomically set before waking the task.
///
/// For sync primitives, the wait_node is used in wait queues.
/// For I/O operations, only the signaled field is used.
///
/// Usage:
/// ```zig
/// var waiter: Waiter = .init(task);
/// // Setup operation (e.g., push to queue, submit I/O)
/// try waiter.wait();
/// ```
pub const Waiter = struct {
    wait_node: WaitNode,
    task: *AnyTask,
    signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const vtable: WaitNode.VTable = .{
        .wake = wakeImpl,
    };

    pub fn init(runtime: *Runtime) Waiter {
        return .{
            .wait_node = .{ .vtable = &vtable },
            .task = runtime.getCurrentTask(),
            .signaled = std.atomic.Value(bool).init(false),
        };
    }

    /// Signal this waiter and wake the task.
    /// Must be called by the signaler after removing from queue or completing I/O.
    pub fn signal(self: *Waiter) void {
        self.signaled.store(true, .release);
        self.task.wake();
    }

    fn wakeImpl(wait_node: *WaitNode) void {
        const self: *Waiter = @fieldParentPtr("wait_node", wait_node);
        self.signal();
    }

    /// Wait for the signal, handling spurious wakeups internally.
    pub fn wait(self: *Waiter) Cancelable!void {
        const task = self.task;

        while (true) {
            task.state.store(.preparing_to_wait, .release);

            // Check after setting state to handle the race where
            // signal happens while we're in .ready state (e.g., after spurious wakeup).
            if (self.signaled.load(.acquire)) {
                task.state.store(.ready, .release);
                return;
            }

            // Get executor fresh each time - may change after cancel/reschedule
            const executor = task.getExecutor();
            try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);

            // Check completion - if not signaled, it was a spurious wakeup
            if (self.signaled.load(.acquire)) {
                return;
            }
            // Spurious wakeup - loop and wait again
        }
    }

    /// Wait for the signal with cancellation shielded.
    /// Used when waiting for a signal that is guaranteed to arrive (e.g., after being removed from queue).
    pub fn waitUncancelable(self: *Waiter) void {
        const task = self.task;

        while (true) {
            task.state.store(.preparing_to_wait, .release);

            if (self.signaled.load(.acquire)) {
                task.state.store(.ready, .release);
                return;
            }

            const executor = task.getExecutor();
            executor.yield(.preparing_to_wait, .waiting, .no_cancel);

            if (self.signaled.load(.acquire)) {
                return;
            }
        }
    }

    /// Wait for the signal with a timeout.
    /// Returns error.Timeout if the timeout expires before signal() is called.
    /// The caller must check their condition to determine if timeout actually won
    /// (e.g., by trying to remove from a wait queue).
    pub fn timedWait(self: *Waiter, timeout: Duration) (Timeoutable || Cancelable)!void {
        var timer: ev.Timer = .init(.{ .duration = .zero });
        timer.c.userdata = self;
        timer.c.callback = callback;

        self.task.getExecutor().loop.setTimer(&timer, timeout);
        defer timer.c.loop.?.clearTimer(&timer);

        try self.wait();
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
pub fn waitForIo(rt: *Runtime, c: *ev.Completion) Cancelable!void {
    var waiter = Waiter.init(rt);
    c.userdata = &waiter;
    c.callback = Waiter.callback;

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    // Submit to the event loop and wait for completion
    waiter.task.getExecutor().loop.add(c);
    waiter.wait() catch |err| switch (err) {
        error.Canceled => {
            // On cancellation, cancel the I/O and wait for completion
            waiter.task.getExecutor().loop.cancel(c);
            waiter.waitUncancelable();

            // Check if I/O was actually canceled
            if (c.err) |io_err| {
                if (io_err == error.Canceled) {
                    return error.Canceled;
                }
            }
            // IO completed successfully despite cancel request - restore the pending cancel
            waiter.task.recancel();
            return;
        },
    };
}

/// Runs an I/O operation to completion with a timeout.
/// If the timeout expires before the I/O completes, returns `error.Timeout`.
/// If the timeout is `.none`, waits indefinitely (just calls `waitForIo`).
pub fn timedWaitForIo(rt: *Runtime, c: *ev.Completion, timeout: Timeout) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return waitForIo(rt, c);
    }

    var group = ev.Group.init(.race);
    var timer = ev.Timer.init(timeout);

    group.add(c);
    group.add(&timer.c);

    try waitForIo(rt, &group.c);

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
    try waitForIo(rt, &timer.c);
}

test "timedWaitForIo: timeout interrupts long operation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Long timer (1 second) with short timeout (10ms)
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(1) });
    try std.testing.expectError(error.Timeout, timedWaitForIo(rt, &timer.c, .{ .duration = .fromMilliseconds(10) }));
}

test "timedWaitForIo: completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Short timer (10ms) with long timeout (1 second)
    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try timedWaitForIo(rt, &timer.c, .{ .duration = .fromSeconds(1) });
}
