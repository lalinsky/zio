// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Common utilities for sync primitives.

const std = @import("std");
const WaitNode = @import("../runtime/WaitNode.zig");
const Awaitable = @import("../runtime/awaitable.zig").Awaitable;
const AnyTask = @import("../runtime/task.zig").AnyTask;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../common.zig").Cancelable;

/// Stack-allocated waiter for sync operations.
///
/// This separates the operation's wait node from the task's wait node,
/// allowing a task to be canceled/scheduled while its operation wait node
/// is still in a wait queue.
///
/// Use with CompactWaitQueue(WaitNode) - push &waiter.wait_node.
///
/// Usage:
/// ```zig
/// var waiter: Waiter = .init(&task.awaitable);
/// queue.push(&waiter.wait_node);
/// try waiter.wait(executor);
/// ```
pub const Waiter = struct {
    wait_node: WaitNode,
    awaitable: *Awaitable,
    signaled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const vtable: WaitNode.VTable = .{
        .wake = wakeImpl,
    };

    pub fn init(awaitable: *Awaitable) Waiter {
        return .{
            .wait_node = .{ .vtable = &vtable },
            .awaitable = awaitable,
            .signaled = std.atomic.Value(bool).init(false),
        };
    }

    /// Signal this waiter and wake the task.
    /// Must be called by the signaler after removing from queue.
    pub fn signal(self: *Waiter) void {
        self.signaled.store(true, .release);
        AnyTask.fromAwaitable(self.awaitable).wake();
    }

    fn wakeImpl(wait_node: *WaitNode) void {
        const self: *Waiter = @fieldParentPtr("wait_node", wait_node);
        self.signal();
    }

    /// Wait for the signal, handling spurious wakeups internally.
    pub fn wait(self: *Waiter) Cancelable!void {
        const task = AnyTask.fromAwaitable(self.awaitable);

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
        const task = AnyTask.fromAwaitable(self.awaitable);

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
};
