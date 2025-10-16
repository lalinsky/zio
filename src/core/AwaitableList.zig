//! Simple doubly-linked list for awaitables (non-concurrent).
//!
//! Provides O(1) push, pop, and remove operations.

const std = @import("std");
const builtin = @import("builtin");
const Awaitable = @import("../runtime.zig").Awaitable;

const SimpleAwaitableList = @This();

head: ?*Awaitable = null,
tail: ?*Awaitable = null,

pub fn push(self: *SimpleAwaitableList, awaitable: *Awaitable) void {
    std.debug.assert(!awaitable.in_list);
    awaitable.in_list = true;
    awaitable.next = null;
    if (self.tail) |tail| {
        tail.next = awaitable;
        awaitable.prev = tail;
        self.tail = awaitable;
    } else {
        awaitable.prev = null;
        self.head = awaitable;
        self.tail = awaitable;
    }
}

pub fn pop(self: *SimpleAwaitableList) ?*Awaitable {
    const head = self.head orelse return null;
    head.in_list = false;
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

pub fn concatByMoving(self: *SimpleAwaitableList, other: *SimpleAwaitableList) void {
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

pub fn remove(self: *SimpleAwaitableList, awaitable: *Awaitable) bool {
    // Handle empty list
    if (self.head == null) return false;

    // Check if not in list (may have been removed already)
    if (!awaitable.in_list) return false;

    // Validate membership (if no prev, must be head)
    if (awaitable.prev == null and self.head != awaitable) return false;
    // Validate membership (if no next, must be tail)
    if (awaitable.next == null and self.tail != awaitable) return false;

    // Mark as removed
    awaitable.in_list = false;

    // Update prev node's next pointer (or head if removing first node)
    if (awaitable.prev) |prev_node| {
        prev_node.next = awaitable.next;
    } else {
        // No prev means this is the head
        self.head = awaitable.next;
    }

    // Update next node's prev pointer (or tail if removing last node)
    if (awaitable.next) |next_node| {
        next_node.prev = awaitable.prev;
    } else {
        // No next means this is the tail
        self.tail = awaitable.prev;
    }

    // Clear pointers
    awaitable.next = null;
    awaitable.prev = null;

    return true;
}
