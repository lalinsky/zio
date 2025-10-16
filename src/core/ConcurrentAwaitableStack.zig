//! Lock-free intrusive stack for cross-thread communication.
//!
//! Uses atomic compare-and-swap for thread-safe push operations.
//! PopAll atomically drains the entire stack and returns items in LIFO order.

const std = @import("std");
const Awaitable = @import("../runtime.zig").Awaitable;
const SimpleAwaitableStack = @import("SimpleAwaitableStack.zig");

const ConcurrentAwaitableStack = @This();

head: std.atomic.Value(?*Awaitable) = std.atomic.Value(?*Awaitable).init(null),

/// Push an item onto the stack. Thread-safe, can be called from any thread.
pub fn push(self: *ConcurrentAwaitableStack, item: *Awaitable) void {
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
/// Returns a SimpleAwaitableStack containing all drained items (LIFO order).
pub fn popAll(self: *ConcurrentAwaitableStack) SimpleAwaitableStack {
    const head = self.head.swap(null, .acq_rel);
    return SimpleAwaitableStack{ .head = head };
}
