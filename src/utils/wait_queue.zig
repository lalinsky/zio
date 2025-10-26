//! Wait queues for thread-safe synchronization primitives.
//!
//! This is a low-level building block for implementing synchronization primitives
//! (mutexes, condition variables, semaphores, etc.). Application code should use
//! higher-level primitives from the sync module instead of using these queues directly.
//!
//! Provides two variants:
//! - WaitQueue: 16-byte queue with separate head and tail pointers
//! - CompactWaitQueue: 8-byte queue with tail stored in head node

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;

/// Generic wait queue with two sentinel states for synchronization primitives.
///
/// **Low-level primitive**: This is intended for implementing synchronization primitives.
/// Application code should use higher-level abstractions from the sync module instead.
///
/// Uses tagged pointers with mutation spinlock for thread-safe operations:
/// - 0b00: Sentinel state 0
/// - 0b01: Sentinel state 1
/// - ptr (>1): Pointer to head of wait queue
/// - ptr | 0b10: Mutation lock bit (queue is being modified)
///
/// Provides O(1) push, pop, and remove operations using a doubly-linked list
/// with atomic head pointer and non-atomic tail pointer (protected by mutation lock).
///
/// This pattern enables efficient concurrent synchronization primitives where:
/// - Sentinel states can encode additional information (e.g., locked vs unlocked)
/// - Wait queues need thread-safe access with minimal overhead
/// - Critical sections are very short (just pointer manipulation)
///
/// T must be a struct type with:
/// - `next` field of type ?*T
/// - `prev` field of type ?*T
/// - `in_list` field of type bool (debug mode only)
///
/// Usage:
/// ```zig
/// const MyNode = struct {
///     next: ?*MyNode = null,
///     prev: ?*MyNode = null,
///     in_list: bool = false, // Required in debug mode
///     data: i32,
/// };
/// // Use .empty for initialization:
/// var queue: WaitQueue(MyNode) = .empty;
/// // Or for convenient field initialization:
/// waiters: WaitQueue(MyNode) = .empty,
/// ```
pub fn WaitQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head of FIFO wait queue with state encoded in lower bits
        head: std.atomic.Value(usize),

        /// Tail of FIFO wait queue (only valid when head is a pointer)
        /// Not atomic - only accessed while holding mutation lock (bit 0b10 in head)
        tail: ?*T = null,

        /// Empty queue constant for convenient initialization
        pub const empty: Self = .{
            .head = std.atomic.Value(usize).init(@intFromEnum(State.sentinel0)),
        };

        pub const State = enum(usize) {
            sentinel0 = 0b00,
            sentinel1 = 0b01,
            _,

            /// Returns true if state is a pointer (not a sentinel).
            pub fn isPointer(s: State) bool {
                const val = @intFromEnum(s);
                return val > 1; // Not a sentinel (0 or 1) = pointer
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
            // .acquire: synchronizes-with .release from any prior state transitions
            return @enumFromInt(self.head.load(.acquire));
        }

        /// Try to atomically transition from one sentinel state to another.
        /// Returns the previous state (useful for checking if already at target).
        ///
        /// Memory ordering: Uses .acq_rel on success for bidirectional synchronization
        /// (both lock acquisition and unlock paths). Uses .acquire on failure to observe
        /// the current state.
        fn tryTransitionEx(self: *Self, from: State, to: State) State {
            std.debug.assert(!from.isPointer() and !to.isPointer());
            // .acq_rel on success: acquires from prior unlock's .release AND releases for future operations
            // .acquire on failure: synchronizes-with prior .release to observe current state
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
        ///
        /// Memory ordering: Uses .acq_rel on success for bidirectional synchronization
        /// (both lock acquisition and unlock paths). Uses .acquire on failure to observe
        /// the current state.
        pub fn tryTransition(self: *Self, from: State, to: State) bool {
            return self.tryTransitionEx(from, to) == from;
        }

        /// Acquire exclusive access to manipulate the wait list.
        /// Spins until mutation lock is acquired.
        /// Returns the state before mutation bit was set.
        ///
        /// Memory ordering: Uses .acquire on fetchOr to synchronize-with the previous
        /// releaseMutationLock(). This ensures visibility of all modifications made
        /// while the lock was previously held, including non-atomic tail pointer updates.
        ///
        /// If running in a coroutine, will yield to allow other tasks to run.
        /// Otherwise spins (useful for thread pool callbacks).
        pub fn acquireMutationLock(self: *Self) State {
            var spin_count: u4 = 0;
            while (true) {
                // Try to set mutation bit atomically
                // .acquire: synchronizes-with previous .release from releaseMutationLock
                const old = self.head.fetchOr(0b10, .acquire);
                const old_state: State = @enumFromInt(old);

                if (!old_state.hasMutationBit()) {
                    // We got it! old_state is the state before we set the bit
                    return old_state;
                }

                // Someone else holds the mutation lock, spin with yielding on overflow
                spin_count +%= 1;
                if (spin_count == 0) {
                    // Yield at OS thread level to prevent live-lock in multi-threaded scenarios
                    std.Thread.yield() catch {};
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Release exclusive access to wait list.
        ///
        /// Memory ordering: Uses .release on fetchAnd to make all modifications
        /// visible to future lock acquires. This includes non-atomic writes to tail
        /// and doubly-linked list pointer updates performed while holding the lock.
        pub fn releaseMutationLock(self: *Self) void {
            // .release: makes all prior writes visible to future acquireMutationLock calls
            // Clear mutation bit (bit 1) by ANDing with ~0b10
            const prev = self.head.fetchAnd(~@as(usize, 0b10), .release);
            std.debug.assert(prev & 0b10 != 0); // Must have been holding the lock
        }

        /// Internal helper: perform the actual push after lock is acquired.
        /// Assumes mutation lock is held. Releases lock before returning.
        /// Releases lock implicitly (via head.store) if queue was empty, or explicitly otherwise.
        fn pushInternal(self: *Self, old_state: State, item: *T) void {
            // Initialize item
            if (builtin.mode == .Debug) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = null;
            item.prev = null;

            // First waiter - transition from sentinel to queue
            if (!old_state.isPointer()) {
                self.tail = item;
                // .release: publishes tail update and item initialization
                self.head.store(@intFromEnum(State.fromPtr(item)), .release);
                return;
            }

            // Append to tail (safe - we have mutation lock)
            const old_tail = self.tail.?;
            item.prev = old_tail;
            item.next = null;
            old_tail.next = item;
            self.tail = item;

            self.releaseMutationLock();
        }

        /// Add item to the end of the queue.
        /// If queue is currently in a sentinel state, transitions to queue state.
        /// Otherwise acquires mutation lock and appends to tail.
        pub fn push(self: *Self, item: *T) void {
            const old_state = self.acquireMutationLock();
            self.pushInternal(old_state, item);
        }

        /// Add item to the end of the queue, unless queue is in forbidden_state.
        ///
        /// Returns true if item was pushed, false if queue was in forbidden_state.
        ///
        /// This is useful for primitives like ResetEvent where you want to wait unless
        /// the event is already in a signaled state:
        /// - `pushUnless(is_set, wait_node)` → push unless queue is `is_set`, return false if already set
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
            /// Item was pushed to the queue
            pushed,
            /// Queue was in from_state and transitioned to to_state (item was not pushed)
            transitioned,
        };

        /// Push an item to the queue, or if the queue is in from_state, transition to to_state instead.
        ///
        /// Returns `.transitioned` if the queue was in from_state and was transitioned to to_state (item was not pushed).
        /// Returns `.pushed` if the item was pushed to the queue.
        ///
        /// This is useful for avoiding invalid state transitions. For example, in a mutex:
        /// - If queue is unlocked, transition to locked_once (acquire the lock)
        /// - Otherwise, push to wait queue (add waiter to locked mutex)
        /// This prevents the invalid transition: unlocked -> has_waiters (skipping locked_once).
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

            // Check if queue is empty (in sentinel state)
            if (!old_state.isPointer()) {
                self.releaseMutationLock();
                return null;
            }

            const old_head = old_state.getPtr().?;
            const next = old_head.next;

            // Mark as removed from list
            if (builtin.mode == .Debug) {
                std.debug.assert(old_head.in_list);
                old_head.in_list = false;
            }

            // Clear old head's pointers
            old_head.next = null;
            old_head.prev = null;

            if (next == null) {
                // Last waiter - transition to sentinel0
                // (implicitly releases mutation lock since sentinel0 = 0b00 has no mutation bit)
                self.tail = null;
                // .release: publishes tail update and makes queue empty state visible
                self.head.store(@intFromEnum(State.sentinel0), .release);
            } else {
                // More waiters - update head
                // (implicitly releases mutation lock since fromPtr() creates state without mutation bit)
                next.?.prev = null;
                // .release: publishes new head pointer and doubly-linked list updates
                self.head.store(@intFromEnum(State.fromPtr(next.?)), .release);
            }
            // Mutation lock released by store() above

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

            // Check if we're actually in the list (using prev/next pointers)
            // If prev is null and we're not head, we're not in the list
            if (item.prev == null and head != item) {
                self.releaseMutationLock();
                return false;
            }
            // If next is null and we're not tail, we're not in the list
            if (item.next == null and self.tail != item) {
                self.releaseMutationLock();
                return false;
            }

            // Mark as removed from list
            if (builtin.mode == .Debug) {
                item.in_list = false;
            }

            // Save pointers, then clear them immediately while holding lock
            // This prevents data races with concurrent remove() calls and ensures
            // second remove attempts fail the early exit checks above
            const item_prev = item.prev;
            const item_next = item.next;
            item.prev = null;
            item.next = null;

            // O(1) removal with doubly-linked list (using saved values)
            if (item_prev) |prev| {
                prev.next = item_next;
            }
            if (item_next) |next| {
                next.prev = item_prev;
            }

            // Update head if removing head
            if (head == item) {
                if (item_next) |next| {
                    // Store new head pointer (implicitly releases mutation lock since
                    // fromPtr() creates a state without the mutation bit)
                    // .release: publishes doubly-linked list updates and new head
                    self.head.store(@intFromEnum(State.fromPtr(next)), .release);
                } else {
                    // Was only waiter - transition to sentinel0
                    // Update tail first, then clear the mutation bit via store(.release)
                    self.tail = null;
                    // (implicitly releases mutation lock since sentinel0 = 0b00 has no mutation bit)
                    // .release: publishes tail update and queue empty state
                    self.head.store(@intFromEnum(State.sentinel0), .release);
                }
                // Mutation lock released by store() above
            } else {
                // Not removing head, update tail if needed then explicitly release lock
                if (self.tail == item) {
                    self.tail = item_prev;
                }
                self.releaseMutationLock();
            }

            return true;
        }

        /// Pop one item, retrying until success or queue is empty.
        /// If queue is empty (in from_sentinel state), transitions to to_sentinel.
        /// Returns the popped item, or null if queue was/became empty.
        ///
        /// Handles races where items are removed (via cancellation) between
        /// the empty check and pop by retrying in a loop.
        pub fn popOrTransition(self: *Self, from_sentinel: State, to_sentinel: State) ?*T {
            std.debug.assert(!from_sentinel.isPointer());
            std.debug.assert(!to_sentinel.isPointer());

            const old_state = self.acquireMutationLock();

            // If in from_sentinel, transition to to_sentinel
            if (old_state == from_sentinel) {
                self.head.store(@intFromEnum(to_sentinel), .release);
                return null;
            }

            // Already in target state, nothing to do
            if (old_state == to_sentinel) {
                self.releaseMutationLock();
                return null;
            }

            // Must be a pointer (has waiters)
            if (!old_state.isPointer()) {
                // Some other sentinel state - this shouldn't happen
                // but be defensive and return null
                self.releaseMutationLock();
                return null;
            }

            const old_head = old_state.getPtr().?;
            const next = old_head.next;

            // Mark as removed from list
            if (builtin.mode == .Debug) {
                std.debug.assert(old_head.in_list);
                old_head.in_list = false;
            }

            // Clear old head's pointers
            old_head.next = null;
            old_head.prev = null;

            if (next == null) {
                // Last waiter - transition to to_sentinel (not sentinel0!)
                self.tail = null;
                self.head.store(@intFromEnum(to_sentinel), .release);
                return old_head;
            } else {
                // More waiters - update head
                next.?.prev = null;
                self.head.store(@intFromEnum(State.fromPtr(next.?)), .release);
                return old_head;
            }
        }
    };
}

test "WaitQueue basic operations" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    // Initially in sentinel0 state
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Create mock nodes - ensure proper alignment
    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };

    // Push items
    queue.push(&node1);
    try testing.expect(queue.getState().isPointer());
    queue.push(&node2);

    // Pop items (FIFO order)
    const popped1 = queue.pop();
    try testing.expectEqual(&node1, popped1);

    // Remove specific item
    try testing.expectEqual(true, queue.remove(&node2));
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Remove non-existent item
    try testing.expectEqual(false, queue.remove(&node1));
}

test "WaitQueue state transitions" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue = Queue.initWithState(.sentinel1);
    try testing.expectEqual(Queue.State.sentinel1, queue.getState());

    // Transition between sentinels
    try testing.expectEqual(true, queue.tryTransition(.sentinel1, .sentinel0));
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());

    // Failed transition
    try testing.expectEqual(false, queue.tryTransition(.sentinel1, .sentinel0));
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue empty constant" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: i32,
    };

    // Test .empty initialization
    var queue: WaitQueue(TestNode) = .empty;
    try testing.expectEqual(WaitQueue(TestNode).State.sentinel0, queue.getState());
    try testing.expectEqual(@as(?*TestNode, null), queue.tail);

    // Verify it works like init()
    var node align(8) = TestNode{ .value = 42 };
    queue.push(&node);
    try testing.expect(queue.getState().isPointer());

    const popped = queue.pop();
    try testing.expectEqual(&node, popped);
    try testing.expectEqual(WaitQueue(TestNode).State.sentinel0, queue.getState());
}

test "WaitQueue double remove" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: i32,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    // Create mock nodes
    var node1 align(8) = TestNode{ .value = 1 };
    var node2 align(8) = TestNode{ .value = 2 };
    var node3 align(8) = TestNode{ .value = 3 };

    // Push three items
    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    // Remove middle item
    try testing.expectEqual(true, queue.remove(&node2));

    // Try to remove the same item again - should return false
    try testing.expectEqual(false, queue.remove(&node2));

    // Remove head
    try testing.expectEqual(true, queue.remove(&node1));

    // Try to remove head again - should return false
    try testing.expectEqual(false, queue.remove(&node1));

    // Remove tail
    try testing.expectEqual(true, queue.remove(&node3));

    // Try to remove tail again - should return false
    try testing.expectEqual(false, queue.remove(&node3));

    // List should be empty (back to sentinel0)
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue concurrent push and pop" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_threads = 4;
    const items_per_thread = 100;
    const total_items = num_threads * items_per_thread;

    // Create nodes for pushing
    const nodes = try testing.allocator.alloc(TestNode, total_items);
    defer testing.allocator.free(nodes);

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

    try testing.expectEqual(total_items, popped_count);
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue concurrent remove during modifications" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_items = 200;

    // Create nodes
    const nodes = try testing.allocator.alloc(TestNode, num_items);
    defer testing.allocator.free(nodes);

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
    try testing.expectEqual(num_items, total_processed);
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());
}

test "WaitQueue popOrTransition with concurrent removals" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue = Queue.initWithState(.sentinel0);

    const num_items = 500;

    // Create nodes
    const nodes = try testing.allocator.alloc(TestNode, num_items);
    defer testing.allocator.free(nodes);

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
                if (q.popOrTransition(.sentinel0, .sentinel1)) |_| {
                    local_count += 1;
                } else {
                    // Queue became empty and transitioned
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
            // Try to remove items while the other thread is popping
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
    try testing.expectEqual(num_items, total_processed);
    try testing.expectEqual(Queue.State.sentinel1, queue.getState());
}

test "WaitQueue stress test with heavy contention" {
    const testing = std.testing;

    const TestNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: bool = false,
        value: usize,
    };

    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const num_threads = 8;
    const items_per_thread = 200;
    const total_items = num_threads * items_per_thread;

    // Create nodes
    const nodes = try testing.allocator.alloc(TestNode, total_items);
    defer testing.allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    // All threads do the same thing: push their items, then simultaneously pop AND remove
    // This creates maximum contention on the mutation lock
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

                    // Try to remove a specific item (deterministically based on thread_id)
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
    try testing.expectEqual(total_items, total_accounted);
    try testing.expectEqual(Queue.State.sentinel0, queue.getState());
}
