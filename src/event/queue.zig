const std = @import("std");
const assert = std.debug.assert;

/// An intrusive doubly-linked list implementation. The type T must have fields
/// "next" of type `?*T` and "prev" of type `?*T`.
///
/// For those unaware, an intrusive variant of a data structure is one in which
/// the data type in the list has the pointer to the next/prev elements, rather
/// than a higher level "node" or "container" type. The primary benefit
/// of this (and the reason we implement this) is that it defers all memory
/// management to the caller: the data structure implementation doesn't need
/// to allocate "nodes" to contain each element. Instead, the caller provides
/// the element and how its allocated is up to them.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: ?*T = null,
        tail: ?*T = null,

        /// Enqueue a new element to the back of the queue.
        pub fn push(self: *Self, v: *T) void {
            assert(v.next == null);
            assert(v.prev == null);

            if (self.tail) |tail| {
                // If we have elements in the queue, then we add a new tail.
                tail.next = v;
                v.prev = tail;
                self.tail = v;
            } else {
                // No elements in the queue we setup the initial state.
                self.head = v;
                self.tail = v;
            }
        }

        /// Dequeue the next element from the queue.
        pub fn pop(self: *Self) ?*T {
            // The next element is in "head".
            const next = self.head orelse return null;

            // If the head and tail are equal this is the last element
            // so we also set tail to null so we can now be empty.
            if (self.head == self.tail) self.tail = null;

            // Head is whatever is next (if we're the last element,
            // this will be null);
            self.head = next.next;

            // Update the new head's prev pointer
            if (self.head) |head| {
                head.prev = null;
            }

            // We set the "next" and "prev" fields to null so that this element
            // can be inserted again.
            next.next = null;
            next.prev = null;
            return next;
        }

        /// Remove a specific element from the queue.
        /// The element must be in the queue.
        pub fn remove(self: *Self, v: *T) void {
            // Update the previous element's next pointer
            if (v.prev) |prev| {
                prev.next = v.next;
            } else {
                // v is the head
                self.head = v.next;
            }

            // Update the next element's prev pointer
            if (v.next) |next| {
                next.prev = v.prev;
            } else {
                // v is the tail
                self.tail = v.prev;
            }

            // Clear the element's pointers
            v.next = null;
            v.prev = null;
        }

        /// Returns true if the queue is empty.
        pub fn empty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

test Queue {
    const testing = std.testing;

    // Types
    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
        prev: ?*Self = null,
    };
    const Q = Queue(Elem);
    var q: Q = .{};
    try testing.expect(q.empty());

    // Elems
    var elems: [10]Elem = .{Elem{}} ** 10;

    // One
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(!q.empty());
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop() == null);
    try testing.expect(q.empty());

    // Two
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // Interleaved
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // Remove from middle
    q.push(&elems[0]);
    q.push(&elems[1]);
    q.push(&elems[2]);
    q.remove(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[2]);
    try testing.expect(q.pop() == null);

    // Remove from head
    q.push(&elems[0]);
    q.push(&elems[1]);
    q.push(&elems[2]);
    q.remove(&elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop().? == &elems[2]);
    try testing.expect(q.pop() == null);

    // Remove from tail
    q.push(&elems[0]);
    q.push(&elems[1]);
    q.push(&elems[2]);
    q.remove(&elems[2]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // Remove single element
    q.push(&elems[0]);
    q.remove(&elems[0]);
    try testing.expect(q.empty());
    try testing.expect(q.pop() == null);
}
