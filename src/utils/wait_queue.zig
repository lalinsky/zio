// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Wait queues for thread-safe synchronization primitives.
//!
//! This is a low-level building block for implementing synchronization primitives
//! (mutexes, condition variables, semaphores, etc.). Application code should use
//! higher-level primitives from the sync module instead of using these queues directly.
//!
//! Provides two variants:
//! - SimpleWaitQueue: Non-atomic queue for use under external synchronization (e.g., mutex)
//! - WaitQueue: Atomic queue with sentinel states for lock-free synchronization

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const SimpleStack = @import("simple_stack.zig").SimpleStack;

/// Simple wait queue for use under external synchronization (e.g., mutex).
///
/// **Low-level primitive**: This is intended for implementing synchronization primitives.
/// Application code should use higher-level abstractions from the sync module instead.
///
/// This is a non-atomic wait queue that must be protected by an external lock.
/// Use this when you already have a mutex protecting your data structure - it's
/// simpler and faster since it doesn't need atomic operations or mutation spinlocks.
///
/// Provides O(1) push, pop, and remove operations using a doubly-linked list.
///
/// T must be a struct type with:
/// - `next` field of type ?*T
/// - `prev` field of type ?*T
/// - `in_list` field of type bool in debug mode, void in release (tracks queue membership)
///
/// Usage:
/// ```zig
/// const MyNode = struct {
///     next: ?*MyNode = null,
///     prev: ?*MyNode = null,
///     in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
///     data: i32,
/// };
/// var mutex: os.Mutex = .init();
/// var queue: SimpleWaitQueue(MyNode) = .empty;
///
/// mutex.lock();
/// defer mutex.unlock();
/// queue.push(&node);
/// ```
pub fn SimpleWaitQueue(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        /// Empty queue constant for convenient initialization
        pub const empty: Self = .{};

        /// Check if the queue is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }

        /// Add item to the end of the queue.
        /// Must be called with external synchronization.
        pub fn push(self: *Self, item: *T) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }

            item.next = null;
            item.prev = self.tail;

            if (self.tail) |tail| {
                tail.next = item;
            } else {
                self.head = item;
            }

            self.tail = item;
        }

        /// Remove and return the item at the front of the queue.
        /// Must be called with external synchronization.
        /// Returns null if queue is empty.
        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;

            if (std.debug.runtime_safety) {
                std.debug.assert(head.in_list);
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

        /// Remove and return all items from the queue.
        /// Must be called with external synchronization.
        /// Returns a SimpleStack containing all items; the original queue becomes empty.
        /// This is useful for processing all items without repeated locking.
        ///
        /// The returned stack only uses `next` pointers for iteration. All nodes have
        /// their `prev` field set to null, which acts as a sentinel to prevent concurrent
        /// remove() operations from touching the nodes while they're being processed.
        pub fn popAll(self: *Self) SimpleStack(T) {
            const head = self.head;

            // Iterate through all nodes and set prev = null (sentinel)
            // This prevents concurrent remove() from manipulating these nodes
            var node = head;
            while (node) |n| {
                n.prev = null;
                node = n.next;
            }

            // Clear the queue
            self.* = .empty;

            // Return a SimpleStack (only uses next pointers)
            return .{ .head = head };
        }

        /// Remove a specific item from the queue.
        /// Must be called with external synchronization.
        /// Returns true if the item was found and removed, false otherwise.
        pub fn remove(self: *Self, item: *T) bool {
            // Validate membership via pointer checks
            if (item.prev == null and self.head != item) return false;
            if (item.next == null and self.tail != item) return false;

            if (std.debug.runtime_safety) {
                std.debug.assert(item.in_list);
                item.in_list = false;
            }

            if (item.prev) |prev| {
                prev.next = item.next;
            } else {
                self.head = item.next;
            }

            if (item.next) |next| {
                next.prev = item.prev;
            } else {
                self.tail = item.prev;
            }

            item.next = null;
            item.prev = null;

            return true;
        }
    };
}

/// Wait queue with two sentinel states for synchronization primitives.
///
/// **Low-level primitive**: This is intended for implementing synchronization primitives.
/// Application code should use higher-level abstractions from the sync module instead.
///
/// This is a space-efficient queue using only 8 bytes by storing the tail pointer in the
/// head node's userdata field. This is useful for implementing standard library interfaces
/// that only provide 64 bits of state (e.g., std.Io.Mutex).
///
/// While this design is more complex than a standard separate head/tail layout, it's actually
/// faster in practice because the head is always cache-hot from the atomic operations, so
/// accessing the tail via head.userdata is cheaper than a separate atomic tail pointer.
///
/// Uses tagged pointers with mutation spinlock for thread-safe operations:
/// - 0b00: Sentinel state 0
/// - 0b01: Sentinel state 1
/// - ptr (>1): Pointer to head of wait queue
/// - ptr | 0b10: Mutation lock bit
///
/// **IMPORTANT**: The `userdata` field in T is reserved for internal use by the queue.
/// When a node is the head of the queue, its userdata field stores the tail pointer.
/// Applications must not modify userdata while the node is in the queue.
///
/// T must be a struct type with:
/// - `next` field of type ?*T
/// - `prev` field of type ?*T
/// - `userdata` field of type usize (reserved for queue internals)
/// - `in_list` field of type bool in debug mode, void in release (tracks queue membership)
///
/// Usage:
/// ```zig
/// const MyNode = struct {
///     next: ?*MyNode = null,
///     prev: ?*MyNode = null,
///     userdata: usize = 0,  // Reserved for queue internals
///     in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
///     data: i32,
/// };
/// var queue: WaitQueue(MyNode) = .empty;
/// ```
pub fn WaitQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head of FIFO wait queue with state encoded in lower bits.
        /// When head is a pointer, head_node.userdata contains the tail pointer.
        head: std.atomic.Value(usize),

        /// Empty queue constant for convenient initialization
        pub const empty: Self = .{
            .head = std.atomic.Value(usize).init(@intFromEnum(State.sentinel0)),
        };

        /// Create a queue from a raw pointer (e.g., from std.Io.Group.token)
        pub fn fromPtr(ptr: *anyopaque) Self {
            return .{ .head = std.atomic.Value(usize).init(@intFromPtr(ptr)) };
        }

        /// Create a queue from a raw usize value
        pub fn fromInt(value: usize) Self {
            return .{ .head = std.atomic.Value(usize).init(value) };
        }

        pub const State = enum(usize) {
            sentinel0 = 0b00,
            sentinel1 = 0b01,
            _,

            /// Returns true if state is a pointer (not a sentinel).
            pub fn isPointer(s: State) bool {
                const val = @intFromEnum(s);
                return val > 1;
            }

            /// Returns true if the mutation lock bit is set.
            pub fn hasMutationBit(s: State) bool {
                return @intFromEnum(s) & 0b10 != 0;
            }

            /// Returns state with mutation lock bit set.
            pub fn withMutationBit(s: State) State {
                return @enumFromInt(@intFromEnum(s) | 0b10);
            }

            /// Extract pointer from state, or null if state is a sentinel.
            pub fn getPtr(s: State) ?*T {
                if (!s.isPointer()) return null;
                const addr = @intFromEnum(s) & ~@as(usize, 0b11);
                return @ptrFromInt(addr);
            }

            /// Create state from pointer. Pointer must be 4-byte aligned.
            pub fn fromPtr(ptr: *T) State {
                const addr = @intFromPtr(ptr);
                std.debug.assert(addr & 0b11 == 0); // Must be aligned
                return @enumFromInt(addr);
            }
        };

        /// Initialize queue in a specific sentinel state.
        pub fn initWithState(state: State) Self {
            std.debug.assert(!state.isPointer());
            return .{
                .head = std.atomic.Value(usize).init(@intFromEnum(state)),
            };
        }

        /// Get current state (atomic load).
        ///
        /// Memory ordering: Uses .acquire to ensure visibility of any prior modifications
        /// to the list structure if the state is a pointer.
        pub fn getState(self: *const Self) State {
            return @enumFromInt(self.head.load(.acquire));
        }

        /// Try to atomically transition from one sentinel state to another.
        /// Returns the previous state (useful for checking if already at target).
        ///
        /// Memory ordering: Uses .acq_rel on success for bidirectional synchronization.
        /// Uses .acquire on failure to observe the current state.
        pub fn tryTransitionEx(self: *Self, from: State, to: State) State {
            std.debug.assert(!from.isPointer() and !to.isPointer());
            const result = self.head.cmpxchgStrong(
                @intFromEnum(from),
                @intFromEnum(to),
                .acq_rel,
                .acquire,
            );
            if (result) |prev| {
                return @enumFromInt(prev);
            } else {
                return from; // Success, was in from state
            }
        }

        /// Try to atomically transition from one sentinel state to another.
        /// Returns true if successful, false if state has changed.
        pub fn tryTransition(self: *Self, from: State, to: State) bool {
            return self.tryTransitionEx(from, to) == from;
        }

        /// Acquire exclusive access to manipulate the wait list.
        /// Spins until mutation lock is acquired.
        /// Returns the state before mutation bit was set.
        ///
        /// Memory ordering: Uses .acquire on fetchOr to synchronize-with the previous
        /// releaseMutationLock().
        pub fn acquireMutationLock(self: *Self) State {
            var spin_count: u4 = 0;
            while (true) {
                const old = self.head.fetchOr(0b10, .acquire);
                const old_state: State = @enumFromInt(old);

                if (!old_state.hasMutationBit()) {
                    return old_state;
                }

                spin_count +%= 1;
                if (spin_count == 0) {
                    std.Thread.yield() catch {};
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Release exclusive access to wait list.
        ///
        /// Memory ordering: Uses .release on fetchAnd to make all modifications
        /// visible to future lock acquires.
        pub fn releaseMutationLock(self: *Self) void {
            const prev = self.head.fetchAnd(~@as(usize, 0b10), .release);
            std.debug.assert(prev & 0b10 != 0);
        }

        /// Internal helper: perform the actual push after lock is acquired.
        /// Assumes mutation lock is held. Releases lock before returning.
        fn pushInternal(self: *Self, old_state: State, item: *T) void {
            // Initialize item
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = null;
            item.prev = null;

            // First waiter - transition from sentinel to queue
            if (!old_state.isPointer()) {
                // Item is both head and tail, store tail pointer in its own userdata
                item.userdata = @intFromPtr(item);
                // .release: publishes userdata update and item initialization
                self.head.store(@intFromEnum(State.fromPtr(item)), .release);
                return;
            }

            // Get head and tail from head's userdata
            const head = old_state.getPtr().?;
            const tail: *T = @ptrFromInt(head.userdata);

            // Append to tail
            tail.next = item;
            item.prev = tail;
            item.next = null;

            // Update tail pointer in head's userdata
            head.userdata = @intFromPtr(item);

            self.releaseMutationLock();
        }

        /// Add item to the end of the queue.
        /// If queue is currently in a sentinel state, transitions to queue state.
        pub fn push(self: *Self, item: *T) void {
            const old_state = self.acquireMutationLock();
            self.pushInternal(old_state, item);
        }

        /// Add item to the end of the queue, unless queue is in forbidden_state.
        /// Returns true if item was pushed, false if queue was in forbidden_state.
        pub fn pushUnless(self: *Self, forbidden_state: State, item: *T) bool {
            const old_state = self.acquireMutationLock();

            if (old_state == forbidden_state) {
                self.releaseMutationLock();
                return false;
            }

            self.pushInternal(old_state, item);
            return true;
        }

        pub const PushOrTransitionResult = enum {
            pushed,
            transitioned,
        };

        /// Push an item to the queue, or if the queue is in from_state, transition to to_state instead.
        /// Returns `.transitioned` if transition occurred, `.pushed` if item was pushed.
        pub fn pushOrTransition(self: *Self, from_state: State, to_state: State, item: *T) PushOrTransitionResult {
            const old_state = self.acquireMutationLock();

            if (old_state == from_state) {
                self.head.store(@intFromEnum(to_state), .release);
                return .transitioned;
            }

            self.pushInternal(old_state, item);
            return .pushed;
        }

        /// Remove and return the item at the front of the queue.
        /// Returns null if queue is in a sentinel state (empty).
        pub fn pop(self: *Self) ?*T {
            const old_state = self.acquireMutationLock();

            // Check if queue is empty
            if (!old_state.isPointer()) {
                self.releaseMutationLock();
                return null;
            }

            const old_head = old_state.getPtr().?;
            const next = old_head.next;

            // Mark as removed from list
            if (std.debug.runtime_safety) {
                std.debug.assert(old_head.in_list);
                old_head.in_list = false;
            }

            // Clear old head's pointers
            old_head.next = null;
            old_head.prev = null;

            if (next == null) {
                // Last waiter - transition to sentinel0
                self.head.store(@intFromEnum(State.sentinel0), .release);
            } else {
                // Transfer tail pointer from old head to new head
                next.?.userdata = old_head.userdata;
                next.?.prev = null;
                self.head.store(@intFromEnum(State.fromPtr(next.?)), .release);
            }

            return old_head;
        }

        /// Remove a specific item from the queue.
        /// Returns true if the item was found and removed, false otherwise.
        pub fn remove(self: *Self, item: *T) bool {
            const old_state = self.acquireMutationLock();

            // Check if queue is empty
            if (!old_state.isPointer()) {
                self.releaseMutationLock();
                return false;
            }

            const head = old_state.getPtr().?;
            const tail: *T = @ptrFromInt(head.userdata);

            // Validate membership via pointer checks
            if (item.prev == null and head != item) {
                self.releaseMutationLock();
                return false;
            }
            if (item.next == null and tail != item) {
                self.releaseMutationLock();
                return false;
            }

            // Mark as removed from list
            if (std.debug.runtime_safety) {
                std.debug.assert(item.in_list);
                item.in_list = false;
            }

            // Save pointers, then clear them immediately
            const item_prev = item.prev;
            const item_next = item.next;
            item.prev = null;
            item.next = null;

            // Update doubly-linked list
            if (item_prev) |prev| {
                prev.next = item_next;
            }
            if (item_next) |next| {
                next.prev = item_prev;
            }

            // Update head if removing head
            if (head == item) {
                if (item_next) |next| {
                    // Transfer tail pointer to new head
                    // (tail can't be item since item.next != null)
                    next.userdata = head.userdata;
                    self.head.store(@intFromEnum(State.fromPtr(next)), .release);
                } else {
                    // Was only waiter
                    self.head.store(@intFromEnum(State.sentinel0), .release);
                }
            } else {
                // Not removing head, update tail if needed
                if (tail == item) {
                    head.userdata = @intFromPtr(item_prev.?);
                }
                self.releaseMutationLock();
            }

            return true;
        }

        /// Pop one item, or if queue is empty (in from_sentinel state), transition to to_sentinel.
        /// When popping the last item, transitions to last_waiter_sentinel.
        /// Returns the popped item, or null if queue was/became empty.
        pub fn popOrTransition(self: *Self, from_sentinel: State, to_sentinel: State, last_waiter_sentinel: State) ?*T {
            std.debug.assert(!from_sentinel.isPointer());
            std.debug.assert(!to_sentinel.isPointer());
            std.debug.assert(!last_waiter_sentinel.isPointer());

            const old_state = self.acquireMutationLock();

            // If in from_sentinel, transition to to_sentinel
            if (old_state == from_sentinel) {
                self.head.store(@intFromEnum(to_sentinel), .release);
                return null;
            }

            // Already in target state
            if (old_state == to_sentinel) {
                self.releaseMutationLock();
                return null;
            }

            // Must be a pointer (has waiters)
            if (!old_state.isPointer()) {
                self.releaseMutationLock();
                return null;
            }

            const old_head = old_state.getPtr().?;
            const next = old_head.next;

            // Mark as removed from list
            if (std.debug.runtime_safety) {
                std.debug.assert(old_head.in_list);
                old_head.in_list = false;
            }

            // Clear old head's pointers
            old_head.next = null;
            old_head.prev = null;

            if (next == null) {
                // Last waiter - transition to last_waiter_sentinel
                self.head.store(@intFromEnum(last_waiter_sentinel), .release);
            } else {
                // Transfer tail pointer to new head
                next.?.userdata = old_head.userdata;
                next.?.prev = null;
                self.head.store(@intFromEnum(State.fromPtr(next.?)), .release);
            }

            return old_head;
        }
    };
}

test "SimpleWaitQueue basic operations" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    var queue: SimpleWaitQueue(TestNode) = .empty;

    // Initially empty
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(null, queue.pop());

    // Create nodes
    var node1 = TestNode{ .value = 1 };
    var node2 = TestNode{ .value = 2 };
    var node3 = TestNode{ .value = 3 };

    // Push items
    queue.push(&node1);
    try std.testing.expect(!queue.isEmpty());
    queue.push(&node2);
    queue.push(&node3);

    // Pop items (FIFO order)
    const popped1 = queue.pop();
    try std.testing.expectEqual(&node1, popped1);
    try std.testing.expectEqual(1, popped1.?.value);

    const popped2 = queue.pop();
    try std.testing.expectEqual(&node2, popped2);

    const popped3 = queue.pop();
    try std.testing.expectEqual(&node3, popped3);

    // Empty again
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(null, queue.pop());
}

test "SimpleWaitQueue remove operations" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    var queue: SimpleWaitQueue(TestNode) = .empty;

    var node1 = TestNode{ .value = 1 };
    var node2 = TestNode{ .value = 2 };
    var node3 = TestNode{ .value = 3 };

    // Push three items
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // Remove middle item
    try std.testing.expect(queue.remove(&node2));
    try std.testing.expect(!queue.isEmpty());

    // Try to remove same item again - should fail
    try std.testing.expect(!queue.remove(&node2));

    // Remove head
    try std.testing.expect(queue.remove(&node1));

    // Remove tail
    try std.testing.expect(queue.remove(&node3));

    // Queue should be empty
    try std.testing.expect(queue.isEmpty());

    // Try to remove from empty queue
    try std.testing.expect(!queue.remove(&node1));
}

test "SimpleWaitQueue remove head and tail" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    var queue: SimpleWaitQueue(TestNode) = .empty;

    var node1 = TestNode{ .value = 1 };
    var node2 = TestNode{ .value = 2 };
    var node3 = TestNode{ .value = 3 };

    // Test removing head
    queue.push(&node1);
    queue.push(&node2);
    try std.testing.expect(queue.remove(&node1));
    const popped = queue.pop();
    try std.testing.expectEqual(&node2, popped);
    try std.testing.expect(queue.isEmpty());

    // Test removing tail
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);
    try std.testing.expect(queue.remove(&node3));
    try std.testing.expectEqual(&node1, queue.pop());
    try std.testing.expectEqual(&node2, queue.pop());
    try std.testing.expect(queue.isEmpty());
}

test "SimpleWaitQueue empty constant" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    // Test .empty initialization
    var queue: SimpleWaitQueue(TestNode) = .empty;
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(null, queue.head);
    try std.testing.expectEqual(null, queue.tail);

    // Verify it works
    var node = TestNode{ .value = 42 };
    queue.push(&node);
    try std.testing.expect(!queue.isEmpty());

    const popped = queue.pop();
    try std.testing.expectEqual(&node, popped);
    try std.testing.expect(queue.isEmpty());
}

test "WaitQueue basic operations" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    // Initially in sentinel0 state
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Create mock nodes - ensure proper alignment
    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };

    // Push items
    queue.push(&node1);
    try std.testing.expect(queue.getState().isPointer());
    // When there's only one item, it should point to itself as tail
    try std.testing.expectEqual(@intFromPtr(&node1), node1.userdata);

    queue.push(&node2);
    // node1 is still head, its userdata should now point to node2 (tail)
    try std.testing.expectEqual(@intFromPtr(&node2), node1.userdata);

    // Pop items (FIFO order)
    const popped1 = queue.pop();
    try std.testing.expectEqual(&node1, popped1);
    // node2 is now head and tail, should point to itself
    try std.testing.expectEqual(@intFromPtr(&node2), node2.userdata);

    // Remove specific item
    try std.testing.expectEqual(true, queue.remove(&node2));
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Remove non-existent item
    try std.testing.expectEqual(false, queue.remove(&node1));
}

test "WaitQueue state transitions" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue = Queue.initWithState(.sentinel1);
    try std.testing.expectEqual(Queue.State.sentinel1, queue.getState());

    // Transition between sentinels
    try std.testing.expectEqual(true, queue.tryTransition(.sentinel1, .sentinel0));
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Failed transition
    try std.testing.expectEqual(false, queue.tryTransition(.sentinel1, .sentinel0));
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue empty constant" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    // Test .empty initialization
    var queue: WaitQueue(TestNode) = .empty;
    try std.testing.expectEqual(WaitQueue(TestNode).State.sentinel0, queue.getState());

    // Verify it works
    var node align(8) = TestNode{ .value = 42 };
    queue.push(&node);
    try std.testing.expect(queue.getState().isPointer());

    const popped = queue.pop();
    try std.testing.expectEqual(&node, popped);
    try std.testing.expectEqual(WaitQueue(TestNode).State.sentinel0, queue.getState());
}

test "WaitQueue tail tracking" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };
    var node3 align(8) = TestNode{ .value = 3 };

    // Push three items
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // node1 is head, should have tail pointer to node3
    try std.testing.expectEqual(@intFromPtr(&node3), node1.userdata);

    // Pop head
    _ = queue.pop();
    // node2 is now head, should still have tail pointer to node3
    try std.testing.expectEqual(@intFromPtr(&node3), node2.userdata);

    // Pop again
    _ = queue.pop();
    // node3 is now head and tail, should point to itself
    try std.testing.expectEqual(@intFromPtr(&node3), node3.userdata);
}

test "WaitQueue remove tail updates head.userdata" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };
    var node3 align(8) = TestNode{ .value = 3 };

    // Push three items: [1, 2, 3]
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // Remove tail (node3)
    try std.testing.expectEqual(true, queue.remove(&node3));
    // node1.userdata should now point to node2 (new tail)
    try std.testing.expectEqual(@intFromPtr(&node2), node1.userdata);

    // Remove new tail (node2)
    try std.testing.expectEqual(true, queue.remove(&node2));
    // node1.userdata should now point to itself (only item)
    try std.testing.expectEqual(@intFromPtr(&node1), node1.userdata);
}

test "WaitQueue remove head transfers userdata" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };
    var node3 align(8) = TestNode{ .value = 3 };

    // Push three items: [1, 2, 3]
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // node1.userdata points to node3
    try std.testing.expectEqual(@intFromPtr(&node3), node1.userdata);

    // Remove head (node1)
    try std.testing.expectEqual(true, queue.remove(&node1));
    // node2 is now head, should have tail pointer to node3
    try std.testing.expectEqual(@intFromPtr(&node3), node2.userdata);
}

test "WaitQueue double remove" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };
    var node3 align(8) = TestNode{ .value = 3 };

    // Push three items
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // Remove middle item
    try std.testing.expectEqual(true, queue.remove(&node2));

    // Try to remove the same item again - should return false
    try std.testing.expectEqual(false, queue.remove(&node2));

    // Remove head
    try std.testing.expectEqual(true, queue.remove(&node1));

    // Try to remove head again - should return false
    try std.testing.expectEqual(false, queue.remove(&node1));

    // Remove tail
    try std.testing.expectEqual(true, queue.remove(&node3));

    // Try to remove tail again - should return false
    try std.testing.expectEqual(false, queue.remove(&node3));

    // Queue should be empty
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue concurrent push and pop" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_threads = 4;
    const items_per_thread = 100;
    const total_items = num_threads * items_per_thread;

    // Create nodes for pushing
    const nodes = try std.testing.allocator.alloc(TestNode, total_items);
    defer std.testing.allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    // Spawn threads to push items concurrently
    var push_threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        const start = i * items_per_thread;
        const end = (i + 1) * items_per_thread;
        push_threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(q: *Queue, items: []TestNode) void {
                for (items) |*item| {
                    q.push(item);
                }
            }
        }.pushItems, .{ &queue, nodes[start..end] });
    }

    // Wait for all pushes to complete
    for (push_threads) |t| {
        t.join();
    }

    // Verify all items are in the list by popping them
    var popped_count: usize = 0;
    while (queue.pop()) |_| {
        popped_count += 1;
    }

    try std.testing.expectEqual(total_items, popped_count);
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue concurrent remove during modifications" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_items = 200;

    // Create nodes
    const nodes = try std.testing.allocator.alloc(TestNode, num_items);
    defer std.testing.allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    // Thread 1: Push all items
    const push_thread = try std.Thread.spawn(.{}, struct {
        fn pushItems(q: *Queue, items: []TestNode) void {
            for (items) |*item| {
                q.push(item);
            }
        }
    }.pushItems, .{ &queue, nodes });

    // Thread 2: Pop items
    var pop_count = std.atomic.Value(usize).init(0);
    const pop_thread = try std.Thread.spawn(.{}, struct {
        fn popItems(q: *Queue, count: *std.atomic.Value(usize)) void {
            var local_count: usize = 0;
            while (local_count < 100) {
                if (q.pop()) |_| {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.popItems, .{ &queue, &pop_count });

    // Thread 3: Remove specific items (every 3rd item)
    var remove_count = std.atomic.Value(usize).init(0);
    const remove_thread = try std.Thread.spawn(.{}, struct {
        fn removeItems(q: *Queue, items: []TestNode, count: *std.atomic.Value(usize)) void {
            var local_count: usize = 0;
            var i: usize = 0;
            while (i < items.len) : (i += 3) {
                if (q.remove(&items[i])) {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.removeItems, .{ &queue, nodes, &remove_count });

    // Wait for all threads
    push_thread.join();
    pop_thread.join();
    remove_thread.join();

    // Drain remaining items
    var remaining_count: usize = 0;
    while (queue.pop()) |_| {
        remaining_count += 1;
    }

    const total_processed = pop_count.load(.monotonic) + remove_count.load(.monotonic) + remaining_count;

    // Verify all items were accounted for
    try std.testing.expectEqual(num_items, total_processed);
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue popOrTransition with concurrent removals" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue = Queue.initWithState(.sentinel0);

    const num_items = 500;

    // Create nodes
    const nodes = try std.testing.allocator.alloc(TestNode, num_items);
    defer std.testing.allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    // Push all items first
    for (nodes) |*n| {
        queue.push(n);
    }

    // Thread 1: popOrTransition from sentinel0 to sentinel1
    var pop_count = std.atomic.Value(usize).init(0);
    var pops_done = std.atomic.Value(bool).init(false);
    const pop_thread = try std.Thread.spawn(.{}, struct {
        fn popItems(q: *Queue, count: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
            var local_count: usize = 0;
            while (true) {
                if (q.popOrTransition(.sentinel0, .sentinel1, .sentinel1)) |_| {
                    local_count += 1;
                } else {
                    break;
                }
            }
            count.store(local_count, .monotonic);
            done.store(true, .monotonic);
        }
    }.popItems, .{ &queue, &pop_count, &pops_done });

    // Thread 2: Remove random items while popping
    var remove_count = std.atomic.Value(usize).init(0);
    const remove_thread = try std.Thread.spawn(.{}, struct {
        fn removeItems(q: *Queue, items: []TestNode, count: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
            var local_count: usize = 0;
            for (items) |*item| {
                if (done.load(.monotonic)) break;
                if (q.remove(item)) {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.removeItems, .{ &queue, nodes, &remove_count, &pops_done });

    pop_thread.join();
    remove_thread.join();

    const total_processed = pop_count.load(.monotonic) + remove_count.load(.monotonic);

    // Verify all items were accounted for and state transitioned
    try std.testing.expectEqual(num_items, total_processed);
    try std.testing.expectEqual(Queue.State.sentinel1, queue.getState());
}

test "WaitQueue stress test with heavy contention" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_threads = 8;
    const items_per_thread = 200;
    const total_items = num_threads * items_per_thread;

    // Create nodes
    const nodes = try std.testing.allocator.alloc(TestNode, total_items);
    defer std.testing.allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    const ThreadCounts = struct {
        popped: std.atomic.Value(usize),
        removed: std.atomic.Value(usize),
    };
    var threads: [num_threads]std.Thread = undefined;
    var counts: [num_threads]ThreadCounts = undefined;

    for (0..num_threads) |i| {
        counts[i] = .{
            .popped = std.atomic.Value(usize).init(0),
            .removed = std.atomic.Value(usize).init(0),
        };
    }

    for (0..num_threads) |i| {
        const start = i * items_per_thread;
        const end = (i + 1) * items_per_thread;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn stressTest(q: *Queue, my_items: []TestNode, all_items: []TestNode, thread_counts: *ThreadCounts, thread_id: usize) void {
                // Phase 1: Push all my items
                for (my_items) |*item| {
                    q.push(item);
                }

                // Phase 2: Simultaneously pop and remove
                var local_pop_count: usize = 0;
                var local_remove_count: usize = 0;
                for (0..100) |j| {
                    // Try to pop
                    if (q.pop()) |_| {
                        local_pop_count += 1;
                    }

                    // Try to remove a specific item
                    const idx = (thread_id * 13 + j * 7) % all_items.len;
                    if (q.remove(&all_items[idx])) {
                        local_remove_count += 1;
                    }
                }

                thread_counts.popped.store(local_pop_count, .monotonic);
                thread_counts.removed.store(local_remove_count, .monotonic);
            }
        }.stressTest, .{ &queue, nodes[start..end], nodes, &counts[i], i });
    }

    // Wait for all threads
    for (threads) |t| {
        t.join();
    }

    // Count operations
    var total_popped: usize = 0;
    var total_removed: usize = 0;
    for (&counts) |*c| {
        total_popped += c.popped.load(.monotonic);
        total_removed += c.removed.load(.monotonic);
    }

    // Drain any remaining items
    var remaining: usize = 0;
    while (queue.pop()) |_| {
        remaining += 1;
    }

    const total_accounted = total_popped + total_removed + remaining;

    // All items must be accounted for
    try std.testing.expectEqual(total_items, total_accounted);
    try std.testing.expectEqual(Queue.State.sentinel0, queue.getState());
}
