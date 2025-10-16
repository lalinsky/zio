//! Simple singly-linked stack (LIFO) for single-threaded use.
//!
//! Provides O(1) push and pop operations.

const std = @import("std");
const builtin = @import("builtin");
const Awaitable = @import("../runtime.zig").Awaitable;

const SimpleAwaitableStack = @This();

head: ?*Awaitable = null,

pub fn push(self: *SimpleAwaitableStack, item: *Awaitable) void {
    if (builtin.mode == .Debug) {
        std.debug.assert(!item.in_list);
        item.in_list = true;
    }
    item.next = self.head;
    self.head = item;
}

pub fn pop(self: *SimpleAwaitableStack) ?*Awaitable {
    const head = self.head orelse return null;
    if (builtin.mode == .Debug) {
        head.in_list = false;
    }
    self.head = head.next;
    head.next = null;
    return head;
}

/// Move all items from other stack to this stack (prepends).
pub fn prependByMoving(self: *SimpleAwaitableStack, other: *SimpleAwaitableStack) void {
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
