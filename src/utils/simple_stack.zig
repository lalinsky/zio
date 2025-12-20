// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Generic simple singly-linked stack (LIFO) for single-threaded use.
//!
//! Provides O(1) push and pop operations.
//!
//! Usage:
//! ```zig
//! const MyNode = struct {
//!     next: ?*MyNode = null,
//!     in_list: bool = false, // Required in debug mode
//!     data: i32,
//! };
//! var stack: SimpleStack(MyNode) = .{};
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Generic simple LIFO stack.
/// T must be a struct type with `next` field of type ?*T.
/// In debug mode, the struct must also have an `in_list` field of type bool.
pub fn SimpleStack(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,

        pub fn push(self: *Self, item: *T) void {
            if (builtin.mode == .Debug) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = self.head;
            self.head = item;
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            if (builtin.mode == .Debug) {
                head.in_list = false;
            }
            self.head = head.next;
            head.next = null;
            return head;
        }

        /// Move all items from other stack to this stack (prepends).
        pub fn prependByMoving(self: *Self, other: *Self) void {
            const other_head = other.head orelse return;

            // Find tail of other stack
            var tail = other_head;
            while (tail.next) |next| {
                tail = next;
            }

            // Link tail to our current head
            tail.next = self.head;
            self.head = other_head;

            other.head = null;
        }
    };
}
