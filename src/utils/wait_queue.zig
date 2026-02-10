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

/// Atomic wait queue with a sticky flag for synchronization primitives.
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
/// ## State Encoding
///
/// Uses tagged pointers with a user flag and mutation spinlock:
/// - bit 0: User flag (sticky, orthogonal to waiters)
/// - bit 1: Mutation spinlock (internal)
/// - bits 2+: Pointer to head node (0 if no waiters)
///
/// The flag is "sticky" - it persists across push/pop/remove operations. This allows
/// tracking logical state (set/unset, locked/unlocked) independently of whether there
/// are waiters in the queue.
///
/// ## Usage Examples
///
/// For ResetEvent (flag = "is set"):
/// - `isFlagSet()` → check if event is signaled
/// - `pushUnlessFlag()` → wait unless already set
/// - `setFlag()` + `pop()` loop → signal and wake all waiters
/// - `remove()` → cancel wait (preserves flag!)
///
/// For Mutex (flag = "is unlocked"):
/// - `tryClearFlagIfEmpty()` → tryLock
/// - `pushOrClearFlag()` → lock (acquire or wait)
/// - `popOrSetFlag()` → unlock (wake next or mark unlocked)
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

        // Bit layout constants
        const flag_bit: usize = 0b01;
        const lock_bit: usize = 0b10;
        const ptr_mask: usize = ~@as(usize, 0b11);

        /// Empty queue with flag cleared.
        pub const empty: Self = .{
            .head = std.atomic.Value(usize).init(0),
        };

        /// Empty queue with flag set.
        pub const empty_flagged: Self = .{
            .head = std.atomic.Value(usize).init(flag_bit),
        };

        // =========================================================================
        // State Queries
        // =========================================================================

        /// Check if the flag is set.
        ///
        /// Memory ordering: Uses .acquire to synchronize-with setFlag()'s .release.
        pub fn isFlagSet(self: *const Self) bool {
            return self.head.load(.acquire) & flag_bit != 0;
        }

        /// Check if there are waiters in the queue.
        ///
        /// Memory ordering: Uses .acquire to ensure visibility of waiter data.
        pub fn hasWaiters(self: *const Self) bool {
            return self.head.load(.acquire) & ptr_mask != 0;
        }

        // =========================================================================
        // Flag Operations
        // =========================================================================

        /// Set the flag. Can be called at any time, even with waiters.
        /// The flag is "sticky" - it stays set until explicitly cleared.
        ///
        /// Memory ordering: Uses .release to make prior writes visible to
        /// threads that subsequently observe the flag via isFlagSet().
        pub fn setFlag(self: *Self) void {
            _ = self.head.fetchOr(flag_bit, .release);
        }

        /// Clear the flag.
        ///
        /// Memory ordering: Uses .release for consistency with setFlag().
        pub fn clearFlag(self: *Self) void {
            _ = self.head.fetchAnd(~flag_bit, .release);
        }

        /// Try to set the flag if not already set.
        /// Returns true if we set the flag, false if it was already set.
        ///
        /// Memory ordering: Uses .acq_rel for bidirectional synchronization.
        pub fn trySetFlag(self: *Self) bool {
            const old = self.head.fetchOr(flag_bit, .acq_rel);
            return old & flag_bit == 0;
        }

        /// Try to clear the flag, but only if there are no waiters.
        /// Returns true if cleared, false if flag was not set or has waiters.
        ///
        /// This is useful for Mutex.tryLock() - atomically check unlocked AND no contention.
        pub fn tryClearFlagIfEmpty(self: *Self) bool {
            // Only succeeds if state is exactly flag_bit (flag set, no waiters, not locked)
            return self.head.cmpxchgStrong(flag_bit, 0, .acq_rel, .acquire) == null;
        }

        // =========================================================================
        // Internal Helpers
        // =========================================================================

        /// Acquire exclusive access to manipulate the wait list.
        /// Spins until mutation lock is acquired.
        /// Returns the state before mutation bit was set (with lock bit cleared).
        fn acquireMutationLock(self: *Self) usize {
            var spin_count: u4 = 0;
            while (true) {
                const old = self.head.fetchOr(lock_bit, .acquire);

                if (old & lock_bit == 0) {
                    return old;
                }

                spin_count +%= 1;
                if (spin_count == 0) {
                    std.Thread.yield() catch {};
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Release exclusive access to wait list.
        fn releaseMutationLock(self: *Self) void {
            _ = self.head.fetchAnd(~lock_bit, .release);
        }

        /// Extract pointer from state, or null if no waiters.
        fn getHeadPtr(state: usize) ?*T {
            const ptr_val = state & ptr_mask;
            if (ptr_val == 0) return null;
            return @ptrFromInt(ptr_val);
        }

        /// Create state value from pointer, preserving flag.
        fn makePtrState(ptr: *T, preserve_flag: usize) usize {
            const addr = @intFromPtr(ptr);
            std.debug.assert(addr & 0b11 == 0); // Must be aligned
            return addr | (preserve_flag & flag_bit);
        }

        /// Internal helper: perform the actual push after lock is acquired.
        /// Assumes mutation lock is held. Releases lock before returning.
        fn pushInternal(self: *Self, old_state: usize, item: *T) void {
            // Initialize item
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = null;
            item.prev = null;

            const old_head = getHeadPtr(old_state);

            // First waiter - add to empty queue
            if (old_head == null) {
                // Item is both head and tail, store tail pointer in its own userdata
                item.userdata = @intFromPtr(item);
                // Preserve flag, set pointer
                self.head.store(makePtrState(item, old_state), .release);
                return;
            }

            // Get tail from head's userdata
            const head = old_head.?;
            const tail: *T = @ptrFromInt(head.userdata);

            // Append to tail
            tail.next = item;
            item.prev = tail;

            // Update tail pointer in head's userdata
            head.userdata = @intFromPtr(item);

            self.releaseMutationLock();
        }

        /// Internal helper: perform the actual pop after lock is acquired.
        /// Assumes mutation lock is held and there are waiters. Releases lock before returning.
        fn popInternal(self: *Self, old_state: usize, old_head: *T) *T {
            const next = old_head.next;

            // Mark as removed from list
            if (std.debug.runtime_safety) {
                std.debug.assert(old_head.in_list);
                old_head.in_list = false;
            }

            // Clear old head's pointers
            old_head.next = null;
            old_head.prev = null;

            if (next) |new_head| {
                // Transfer tail pointer from old head to new head
                new_head.userdata = old_head.userdata;
                new_head.prev = null;
                // Preserve flag, update pointer
                self.head.store(makePtrState(new_head, old_state), .release);
            } else {
                // Was last waiter - preserve flag, clear pointer
                self.head.store(old_state & flag_bit, .release);
            }

            return old_head;
        }

        // =========================================================================
        // Waiter Operations (all preserve flag)
        // =========================================================================

        /// Add item to the end of the queue.
        /// Preserves the flag.
        pub fn push(self: *Self, item: *T) void {
            const old_state = self.acquireMutationLock();
            self.pushInternal(old_state, item);
        }

        /// Add item to the end of the queue, unless the flag is set.
        /// Returns true if item was pushed, false if flag was set.
        ///
        /// This is useful for ResetEvent/Future wait - don't wait if already signaled.
        pub fn pushUnlessFlag(self: *Self, item: *T) bool {
            const old_state = self.acquireMutationLock();

            if (old_state & flag_bit != 0) {
                self.releaseMutationLock();
                return false;
            }

            self.pushInternal(old_state, item);
            return true;
        }

        /// Remove and return the item at the front of the queue.
        /// Returns null if there are no waiters.
        /// Preserves the flag.
        pub fn pop(self: *Self) ?*T {
            const old_state = self.acquireMutationLock();

            const old_head = getHeadPtr(old_state) orelse {
                self.releaseMutationLock();
                return null;
            };

            return self.popInternal(old_state, old_head);
        }

        /// Remove a specific item from the queue.
        /// Returns true if the item was found and removed, false otherwise.
        /// **Preserves the flag** - this is the key fix for the cancel race!
        pub fn remove(self: *Self, item: *T) bool {
            const old_state = self.acquireMutationLock();

            const head = getHeadPtr(old_state) orelse {
                self.releaseMutationLock();
                return false;
            };

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
                    next.userdata = head.userdata;
                    // Preserve flag, update pointer
                    self.head.store(makePtrState(next, old_state), .release);
                } else {
                    // Was only waiter - PRESERVE FLAG, clear pointer
                    self.head.store(old_state & flag_bit, .release);
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

        // =========================================================================
        // Combined Operations (for lock semantics)
        // =========================================================================

        /// Push a waiter, or if flag is set AND no waiters, clear the flag.
        /// Returns `.pushed` if waiter was added to queue.
        /// Returns `.flag_cleared` if flag was cleared (caller "won", e.g., acquired lock).
        ///
        /// This is useful for Mutex.lock() - either acquire the lock or join the wait queue.
        pub fn pushOrClearFlag(self: *Self, item: *T) enum { pushed, flag_cleared } {
            const old_state = self.acquireMutationLock();

            // If flag set and no waiters, clear flag (acquire lock)
            if (old_state == flag_bit) {
                self.head.store(0, .release); // Clear flag and lock bit
                return .flag_cleared;
            }

            self.pushInternal(old_state, item);
            return .pushed;
        }

        /// Pop a waiter, or if no waiters, set the flag.
        /// Returns the popped waiter, or null if flag was set (queue was empty).
        ///
        /// This is useful for Mutex.unlock() - wake next waiter or mark as unlocked.
        pub fn popOrSetFlag(self: *Self) ?*T {
            const old_state = self.acquireMutationLock();

            const old_head = getHeadPtr(old_state) orelse {
                // No waiters, set flag
                self.head.store(flag_bit, .release);
                return null;
            };

            return self.popInternal(old_state, old_head);
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

    // Initially empty with flag clear
    try std.testing.expect(!queue.isFlagSet());
    try std.testing.expect(!queue.hasWaiters());

    // Create mock nodes - ensure proper alignment
    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };

    // Push items
    queue.push(&node1);
    try std.testing.expect(queue.hasWaiters());
    try std.testing.expect(!queue.isFlagSet()); // Flag preserved (clear)
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
    try std.testing.expect(!queue.hasWaiters());

    // Remove non-existent item
    try std.testing.expectEqual(false, queue.remove(&node1));
}

test "WaitQueue flag operations" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);

    // Test .empty (flag clear)
    var queue: Queue = .empty;
    try std.testing.expect(!queue.isFlagSet());

    // Test .empty_flagged (flag set)
    var queue2: Queue = .empty_flagged;
    try std.testing.expect(queue2.isFlagSet());

    // Test setFlag / clearFlag
    queue.setFlag();
    try std.testing.expect(queue.isFlagSet());
    queue.clearFlag();
    try std.testing.expect(!queue.isFlagSet());

    // Test trySetFlag
    try std.testing.expect(queue.trySetFlag()); // Should succeed
    try std.testing.expect(!queue.trySetFlag()); // Already set, should fail
    try std.testing.expect(queue.isFlagSet());

    // Test tryClearFlagIfEmpty
    try std.testing.expect(queue.tryClearFlagIfEmpty()); // No waiters, should succeed
    try std.testing.expect(!queue.isFlagSet());

    // Add a waiter, then try to clear
    var node align(8) = TestNode{ .value = 1 };
    queue.setFlag();
    queue.push(&node);
    try std.testing.expect(!queue.tryClearFlagIfEmpty()); // Has waiters, should fail
    try std.testing.expect(queue.isFlagSet()); // Flag unchanged

    _ = queue.pop();
}

test "WaitQueue empty and empty_flagged constants" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    // Test .empty initialization
    var queue: WaitQueue(TestNode) = .empty;
    try std.testing.expect(!queue.isFlagSet());
    try std.testing.expect(!queue.hasWaiters());

    // Verify it works
    var node align(8) = TestNode{ .value = 42 };
    queue.push(&node);
    try std.testing.expect(queue.hasWaiters());

    const popped = queue.pop();
    try std.testing.expectEqual(&node, popped);
    try std.testing.expect(!queue.hasWaiters());

    // Test .empty_flagged
    var queue2: WaitQueue(TestNode) = .empty_flagged;
    try std.testing.expect(queue2.isFlagSet());
    try std.testing.expect(!queue2.hasWaiters());
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
    try std.testing.expect(!queue.hasWaiters());
}

test "WaitQueue remove preserves flag" {
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

    // Push a waiter
    queue.push(&node1);
    try std.testing.expect(!queue.isFlagSet());

    // Set the flag while waiter is in queue
    queue.setFlag();
    try std.testing.expect(queue.isFlagSet());
    try std.testing.expect(queue.hasWaiters());

    // Remove the waiter - flag should be preserved!
    try std.testing.expectEqual(true, queue.remove(&node1));
    try std.testing.expect(queue.isFlagSet()); // THE KEY TEST
    try std.testing.expect(!queue.hasWaiters());
}

test "WaitQueue pop preserves flag" {
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

    // Set flag, then push a waiter
    queue.setFlag();
    queue.push(&node1);
    try std.testing.expect(queue.isFlagSet());
    try std.testing.expect(queue.hasWaiters());

    // Pop the waiter - flag should be preserved!
    const popped = queue.pop();
    try std.testing.expectEqual(&node1, popped);
    try std.testing.expect(queue.isFlagSet()); // Flag preserved
    try std.testing.expect(!queue.hasWaiters());
}

test "WaitQueue pushUnlessFlag" {
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

    // Push should succeed when flag is clear
    try std.testing.expect(queue.pushUnlessFlag(&node1));
    try std.testing.expect(queue.hasWaiters());

    // Set the flag
    queue.setFlag();

    // Push should fail when flag is set
    try std.testing.expect(!queue.pushUnlessFlag(&node2));

    // Clean up
    _ = queue.pop();
}

test "WaitQueue pushOrClearFlag" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);

    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };

    // Test 1: flag set, no waiters -> clears flag
    var queue1: Queue = .empty_flagged;
    try std.testing.expectEqual(.flag_cleared, queue1.pushOrClearFlag(&node1));
    try std.testing.expect(!queue1.isFlagSet());
    try std.testing.expect(!queue1.hasWaiters());

    // Test 2: flag clear, no waiters -> pushes
    var queue2: Queue = .empty;
    try std.testing.expectEqual(.pushed, queue2.pushOrClearFlag(&node1));
    try std.testing.expect(!queue2.isFlagSet());
    try std.testing.expect(queue2.hasWaiters());
    _ = queue2.pop();

    // Test 3: flag set, has waiters -> pushes (doesn't clear)
    var queue3: Queue = .empty;
    queue3.push(&node1);
    queue3.setFlag();
    try std.testing.expectEqual(.pushed, queue3.pushOrClearFlag(&node2));
    try std.testing.expect(queue3.isFlagSet()); // Flag unchanged
    _ = queue3.pop();
    _ = queue3.pop();
}

test "WaitQueue popOrSetFlag" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: i32,
    };

    const Queue = WaitQueue(TestNode);

    var node1 align(8) = TestNode{ .value = 1 };

    // Test 1: has waiters -> pops, doesn't set flag
    var queue1: Queue = .empty;
    queue1.push(&node1);
    const popped = queue1.popOrSetFlag();
    try std.testing.expectEqual(&node1, popped);
    try std.testing.expect(!queue1.isFlagSet()); // Flag not set (was clear before)
    try std.testing.expect(!queue1.hasWaiters());

    // Test 2: no waiters -> sets flag
    var queue2: Queue = .empty;
    const popped2 = queue2.popOrSetFlag();
    try std.testing.expectEqual(null, popped2);
    try std.testing.expect(queue2.isFlagSet()); // Flag now set
    try std.testing.expect(!queue2.hasWaiters());
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
    try std.testing.expect(!queue.hasWaiters());
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
    try std.testing.expect(!queue.hasWaiters());
}

test "WaitQueue popOrSetFlag with concurrent removals" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

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

    // Thread 1: popOrSetFlag until empty (then flag gets set)
    var pop_count = std.atomic.Value(usize).init(0);
    var pops_done = std.atomic.Value(bool).init(false);
    const pop_thread = try std.Thread.spawn(.{}, struct {
        fn popItems(q: *Queue, count: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
            var local_count: usize = 0;
            while (true) {
                if (q.popOrSetFlag()) |_| {
                    local_count += 1;
                } else {
                    break; // Flag was set, queue is empty
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

    // Verify all items were accounted for and flag was set
    try std.testing.expectEqual(num_items, total_processed);
    try std.testing.expect(queue.isFlagSet());
    try std.testing.expect(!queue.hasWaiters());
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
    try std.testing.expect(!queue.hasWaiters());
}

test "WaitQueue concurrent setFlag and remove" {
    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = WaitQueue(TestNode);

    // This test verifies that remove() preserves the flag even under contention
    for (0..100) |_| {
        var queue: Queue = .empty;
        var node align(8) = TestNode{ .value = 1 };

        queue.push(&node);

        // Thread 1: Set flag and pop
        const set_thread = try std.Thread.spawn(.{}, struct {
            fn setAndPop(q: *Queue) void {
                q.setFlag();
                _ = q.pop();
            }
        }.setAndPop, .{&queue});

        // Thread 2: Try to remove
        const remove_thread = try std.Thread.spawn(.{}, struct {
            fn tryRemove(q: *Queue, n: *TestNode) void {
                _ = q.remove(n);
            }
        }.tryRemove, .{ &queue, &node });

        set_thread.join();
        remove_thread.join();

        // The flag should always be set, regardless of which thread won
        try std.testing.expect(queue.isFlagSet());
        try std.testing.expect(!queue.hasWaiters());
    }
}
