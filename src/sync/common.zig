// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Common utilities for sync primitives.

const std = @import("std");
const WaitNode = @import("../runtime/WaitNode.zig");
const Awaitable = @import("../runtime/awaitable.zig").Awaitable;
const resumeTask = @import("../runtime/task.zig").resumeTask;

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
/// // ... wait ...
/// // When waiter.wait_node is woken, it resumes the parent task
/// ```
pub const Waiter = struct {
    wait_node: WaitNode,
    awaitable: *Awaitable,

    const vtable: WaitNode.VTable = .{
        .wake = wake,
    };

    pub fn init(awaitable: *Awaitable) Waiter {
        return .{
            .wait_node = .{ .vtable = &vtable },
            .awaitable = awaitable,
        };
    }

    fn wake(wait_node: *WaitNode) void {
        const self: *Waiter = @fieldParentPtr("wait_node", wait_node);
        resumeTask(self.awaitable, .maybe_remote);
    }
};
