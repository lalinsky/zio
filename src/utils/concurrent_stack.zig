// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Generic lock-free intrusive stack for cross-thread communication.
//!
//! Uses atomic compare-and-swap for thread-safe push operations.
//! PopAll atomically drains the entire stack and returns items in LIFO order.
//!
//! T must be a struct type with a `next` field of type ?*T.

const std = @import("std");
const SimpleStack = @import("simple_stack.zig").SimpleStack;

/// Generic concurrent LIFO stack.
/// T must be a struct type with `next` field of type ?*T.
pub fn ConcurrentStack(comptime T: type) type {
    return struct {
        const Self = @This();

        head: std.atomic.Value(?*T) = std.atomic.Value(?*T).init(null),

        /// Push an item onto the stack. Thread-safe, can be called from any thread.
        pub fn push(self: *Self, item: *T) void {
            while (true) {
                const current_head = self.head.load(.acquire);
                item.next = current_head;

                // Try to swing head to new item
                if (self.head.cmpxchgWeak(
                    current_head,
                    item,
                    .release,
                    .acquire,
                ) == null) {
                    return; // Success!
                }
                // CAS failed, retry
            }
        }

        /// Atomically drain all items from the stack.
        /// Returns a SimpleStack containing all drained items (LIFO order).
        pub fn popAll(self: *Self) SimpleStack(T) {
            const head = self.head.swap(null, .acq_rel);
            return SimpleStack(T){ .head = head };
        }
    };
}
