// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Generic simple doubly-linked queue (FIFO) for single-threaded use.
//!
//! Provides O(1) push, pop, and remove operations.
//!
//! Usage:
//! ```zig
//! const MyNode = struct {
//!     next: ?*MyNode = null,
//!     prev: ?*MyNode = null,
//!     in_list: bool = false, // Required in debug mode
//!     data: i32,
//! };
//! var queue: SimpleQueue(MyNode) = .{};
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Generic simple FIFO queue.
/// T must be a struct type with `next` and `prev` fields of type ?*T.
/// In debug mode, the struct must also have an `in_list` field of type bool.
pub fn SimpleQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        pub fn push(self: *Self, item: *T) void {
            if (builtin.mode == .Debug) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = null;
            if (self.tail) |tail| {
                tail.next = item;
                item.prev = tail;
                self.tail = item;
            } else {
                item.prev = null;
                self.head = item;
                self.tail = item;
            }
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            if (builtin.mode == .Debug) {
                head.in_list = false;
            }
            self.head = head.next;
            if (self.head) |new_head| {
                new_head.prev = null;
            } else {
                self.tail = null;
            }
            head.next = null;
            head.prev = null;
            return head;
        }

        pub fn concatByMoving(self: *Self, other: *Self) void {
            if (other.head == null) return;

            if (self.tail) |tail| {
                tail.next = other.head;
                if (other.head) |other_head| {
                    other_head.prev = tail;
                }
                self.tail = other.tail;
            } else {
                self.head = other.head;
                self.tail = other.tail;
            }

            other.head = null;
            other.tail = null;
        }

        pub fn remove(self: *Self, item: *T) bool {
            // Handle empty list
            if (self.head == null) return false;

            // Validate membership (if no prev, must be head)
            if (item.prev == null and self.head != item) return false;
            // Validate membership (if no next, must be tail)
            if (item.next == null and self.tail != item) return false;

            // Mark as removed
            if (builtin.mode == .Debug) {
                item.in_list = false;
            }

            // Update prev node's next pointer (or head if removing first node)
            if (item.prev) |prev_node| {
                prev_node.next = item.next;
            } else {
                // No prev means this is the head
                self.head = item.next;
            }

            // Update next node's prev pointer (or tail if removing last node)
            if (item.next) |next_node| {
                next_node.prev = item.prev;
            } else {
                // No next means this is the tail
                self.tail = item.prev;
            }

            // Clear pointers
            item.next = null;
            item.prev = null;

            return true;
        }
    };
}
