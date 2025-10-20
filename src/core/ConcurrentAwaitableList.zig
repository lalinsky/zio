//! Concurrent FIFO list for awaitables with two sentinel states.
//!
//! Uses tagged pointers with mutation spinlock for thread-safe operations:
//! - 0b00: Sentinel state 0
//! - 0b01: Sentinel state 1
//! - ptr (>1): Pointer to head of wait queue
//! - ptr | 0b10: Mutation lock bit (queue is being modified)
//!
//! Provides O(1) push, pop, and remove operations using a doubly-linked list
//! with atomic head pointer and non-atomic tail pointer (protected by mutation lock).
//!
//! This pattern enables efficient concurrent synchronization primitives where:
//! - Sentinel states can encode additional information (e.g., locked vs unlocked)
//! - Wait queues need thread-safe access with minimal overhead
//! - Critical sections are very short (just pointer manipulation)

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Awaitable = @import("../runtime.zig").Awaitable;

const ConcurrentAwaitableList = @This();

/// Head of FIFO wait queue with state encoded in lower bits
head: std.atomic.Value(usize),

/// Tail of FIFO wait queue (only valid when head is a pointer)
/// Not atomic - only accessed while holding mutation lock
tail: ?*Awaitable = null,

pub const State = enum(usize) {
    sentinel0 = 0b00,
    sentinel1 = 0b01,
    _,

    pub fn isPointer(s: State) bool {
        const val = @intFromEnum(s);
        return val > 1; // Not a sentinel (0 or 1) = pointer
    }

    pub fn hasMutationBit(s: State) bool {
        return @intFromEnum(s) & 0b10 != 0;
    }

    pub fn withMutationBit(s: State) State {
        return @enumFromInt(@intFromEnum(s) | 0b10);
    }

    pub fn getPtr(s: State) ?*Awaitable {
        if (!s.isPointer()) return null;
        const addr = @intFromEnum(s) & ~@as(usize, 0b11);
        return @ptrFromInt(addr);
    }

    pub fn fromPtr(ptr: *Awaitable) State {
        const addr = @intFromPtr(ptr);
        std.debug.assert(addr & 0b11 == 0); // Must be aligned
        return @enumFromInt(addr);
    }
};

/// Initialize list in sentinel0 state
pub fn init() ConcurrentAwaitableList {
    return .{
        .head = std.atomic.Value(usize).init(@intFromEnum(State.sentinel0)),
    };
}

/// Initialize list in a specific sentinel state
pub fn initWithState(state: State) ConcurrentAwaitableList {
    std.debug.assert(!state.isPointer());
    return .{
        .head = std.atomic.Value(usize).init(@intFromEnum(state)),
    };
}

/// Get current state (atomic load)
///
/// Memory ordering: Uses .acquire to ensure visibility of any prior modifications
/// to the list structure if the state is a pointer.
pub fn getState(self: *const ConcurrentAwaitableList) State {
    // .acquire: synchronizes-with .release from any prior state transitions
    return @enumFromInt(self.head.load(.acquire));
}

/// Try to atomically transition from one sentinel state to another
/// Returns the previous state (useful for checking if already at target)
///
/// Memory ordering: Uses .acq_rel on success for bidirectional synchronization
/// (both lock acquisition and unlock paths). Uses .acquire on failure to observe
/// the current state.
fn tryTransitionEx(self: *ConcurrentAwaitableList, from: State, to: State) State {
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

/// Try to atomically transition from one sentinel state to another
/// Returns true if successful, false if state has changed
///
/// Memory ordering: Uses .acq_rel on success for bidirectional synchronization
/// (both lock acquisition and unlock paths). Uses .acquire on failure to observe
/// the current state.
pub fn tryTransition(self: *ConcurrentAwaitableList, from: State, to: State) bool {
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
/// If executor is null, spins without yielding (useful for thread pool callbacks).
pub fn acquireMutationLock(self: *ConcurrentAwaitableList, executor: ?*Executor) State {
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
            if (executor) |e| {
                e.yield(.ready, .ready, .no_cancel);
            } else {
                std.Thread.yield() catch {};
            }
        }
        std.atomic.spinLoopHint();
    }
}

/// Release exclusive access to wait list.
///
/// Memory ordering: Uses .release on fetchAnd to make all modifications
/// visible to future lock acquires. This includes non-atomic writes to tail
/// and doubly-linked list pointer updates performed while holding the lock.
pub fn releaseMutationLock(self: *ConcurrentAwaitableList) void {
    // .release: makes all prior writes visible to future acquireMutationLock calls
    // Clear mutation bit (bit 1) by ANDing with ~0b10
    const prev = self.head.fetchAnd(~@as(usize, 0b10), .release);
    std.debug.assert(prev & 0b10 != 0); // Must have been holding the lock
}

/// Add awaitable to the end of the list.
/// If list is currently in a sentinel state, transitions to list state.
/// Otherwise acquires mutation lock and appends to tail.
pub fn push(self: *ConcurrentAwaitableList, executor: ?*Executor, awaitable: *Awaitable) void {
    // Initialize awaitable as not in list
    if (builtin.mode == .Debug) {
        std.debug.assert(!awaitable.in_list);
        awaitable.in_list = true;
    }
    awaitable.next = null;
    awaitable.prev = null;

    const old_state = self.acquireMutationLock(executor);

    // First waiter - transition from sentinel to queue
    if (!old_state.isPointer()) {
        self.tail = awaitable;
        // .release: publishes tail update and awaitable initialization
        self.head.store(@intFromEnum(State.fromPtr(awaitable)), .release);
        return;
    }

    // Append to tail (safe - we have mutation lock)
    const old_tail = self.tail.?;
    awaitable.prev = old_tail;
    awaitable.next = null;
    old_tail.next = awaitable;
    self.tail = awaitable;

    self.releaseMutationLock();
}

/// Remove and return the awaitable at the front of the list.
/// Returns null if list is in a sentinel state (empty).
pub fn pop(self: *ConcurrentAwaitableList, executor: ?*Executor) ?*Awaitable {
    const old_state = self.acquireMutationLock(executor);

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

/// Remove a specific awaitable from the list.
/// Returns true if the awaitable was found and removed, false otherwise.
pub fn remove(self: *ConcurrentAwaitableList, executor: ?*Executor, awaitable: *Awaitable) bool {
    const old_state = self.acquireMutationLock(executor);

    // Check if queue is empty
    if (!old_state.isPointer()) {
        self.releaseMutationLock();
        return false;
    }

    const head = old_state.getPtr().?;

    // Check if we're actually in the list (using prev/next pointers)
    // If prev is null and we're not head, we're not in the list
    if (awaitable.prev == null and head != awaitable) {
        self.releaseMutationLock();
        return false;
    }
    // If next is null and we're not tail, we're not in the list
    if (awaitable.next == null and self.tail != awaitable) {
        self.releaseMutationLock();
        return false;
    }

    // Mark as removed from list
    if (builtin.mode == .Debug) {
        awaitable.in_list = false;
    }

    // O(1) removal with doubly-linked list
    if (awaitable.prev) |prev| {
        prev.next = awaitable.next;
    }
    if (awaitable.next) |next| {
        next.prev = awaitable.prev;
    }

    // Update head if removing head
    if (head == awaitable) {
        if (awaitable.next) |next| {
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
        if (self.tail == awaitable) {
            self.tail = awaitable.prev;
        }
        self.releaseMutationLock();
    }

    // Clear pointers
    awaitable.next = null;
    awaitable.prev = null;

    return true;
}

/// Pop one item, retrying until success or queue is empty.
/// If queue is empty (in from_sentinel state), transitions to to_sentinel.
/// Returns the popped item, or null if queue was/became empty.
///
/// This handles the race where waiters remove themselves (via cancellation)
/// between the empty check and pop by retrying in a loop.
pub fn popOrTransition(self: *ConcurrentAwaitableList, executor: ?*Executor, from_sentinel: State, to_sentinel: State) ?*Awaitable {
    std.debug.assert(!from_sentinel.isPointer());
    std.debug.assert(!to_sentinel.isPointer());

    while (true) {
        // Try to transition from empty state
        const prev_state = self.tryTransitionEx(from_sentinel, to_sentinel);

        // Success: was in from_sentinel, transitioned to to_sentinel
        if (prev_state == from_sentinel) {
            return null;
        }

        // Already in target state, nothing to do
        if (prev_state == to_sentinel) {
            return null;
        }

        // Has waiters (state is pointer), try to pop one
        if (self.pop(executor)) |awaitable| {
            return awaitable;
        }

        // Race: waiter cancelled between check and pop, retry
    }
}

test "ConcurrentAwaitableList basic operations" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var list = ConcurrentAwaitableList.init();

    // Initially in sentinel0 state
    try testing.expectEqual(State.sentinel0, list.getState());

    // Create mock awaitables - ensure proper alignment
    var awaitable1 align(8) = Awaitable{
        .kind = .task,
        .destroy_fn = struct {
            fn dummy(_: *Runtime, _: *Awaitable) void {}
        }.dummy,
    };
    var awaitable2 align(8) = Awaitable{
        .kind = .task,
        .destroy_fn = struct {
            fn dummy(_: *Runtime, _: *Awaitable) void {}
        }.dummy,
    };

    // Push items
    list.push(&runtime.executor, &awaitable1);
    try testing.expect(list.getState().isPointer());
    list.push(&runtime.executor, &awaitable2);

    // Pop items (FIFO order)
    const popped1 = list.pop(&runtime.executor);
    try testing.expectEqual(&awaitable1, popped1);

    // Remove specific item
    try testing.expectEqual(true, list.remove(&runtime.executor, &awaitable2));
    try testing.expectEqual(State.sentinel0, list.getState());

    // Remove non-existent item
    try testing.expectEqual(false, list.remove(&runtime.executor, &awaitable1));
}

test "ConcurrentAwaitableList state transitions" {
    const testing = std.testing;

    var list = ConcurrentAwaitableList.initWithState(.sentinel1);
    try testing.expectEqual(State.sentinel1, list.getState());

    // Transition between sentinels
    try testing.expectEqual(true, list.tryTransition(.sentinel1, .sentinel0));
    try testing.expectEqual(State.sentinel0, list.getState());

    // Failed transition
    try testing.expectEqual(false, list.tryTransition(.sentinel1, .sentinel0));
    try testing.expectEqual(State.sentinel0, list.getState());
}

test "ConcurrentAwaitableList double remove" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var list = ConcurrentAwaitableList.init();

    // Create mock awaitables
    var awaitable1 align(8) = Awaitable{
        .kind = .task,
        .destroy_fn = struct {
            fn dummy(_: *Runtime, _: *Awaitable) void {}
        }.dummy,
    };
    var awaitable2 align(8) = Awaitable{
        .kind = .task,
        .destroy_fn = struct {
            fn dummy(_: *Runtime, _: *Awaitable) void {}
        }.dummy,
    };
    var awaitable3 align(8) = Awaitable{
        .kind = .task,
        .destroy_fn = struct {
            fn dummy(_: *Runtime, _: *Awaitable) void {}
        }.dummy,
    };

    // Push three items
    list.push(&runtime.executor, &awaitable1);
    list.push(&runtime.executor, &awaitable2);
    list.push(&runtime.executor, &awaitable3);

    // Remove middle item
    try testing.expectEqual(true, list.remove(&runtime.executor, &awaitable2));

    // Try to remove the same item again - should return false
    try testing.expectEqual(false, list.remove(&runtime.executor, &awaitable2));

    // Remove head
    try testing.expectEqual(true, list.remove(&runtime.executor, &awaitable1));

    // Try to remove head again - should return false
    try testing.expectEqual(false, list.remove(&runtime.executor, &awaitable1));

    // Remove tail
    try testing.expectEqual(true, list.remove(&runtime.executor, &awaitable3));

    // Try to remove tail again - should return false
    try testing.expectEqual(false, list.remove(&runtime.executor, &awaitable3));

    // List should be empty (back to sentinel0)
    try testing.expectEqual(State.sentinel0, list.getState());
}

test "ConcurrentAwaitableList concurrent push and pop" {
    const testing = std.testing;

    var list = ConcurrentAwaitableList.init();

    const num_threads = 4;
    const items_per_thread = 100;
    const total_items = num_threads * items_per_thread;

    // Create awaitables for pushing
    const awaitables = try testing.allocator.alloc(Awaitable, total_items);
    defer testing.allocator.free(awaitables);

    for (awaitables) |*a| {
        a.* = .{
            .kind = .task,
            .destroy_fn = struct {
                fn dummy(_: *Runtime, _: *Awaitable) void {}
            }.dummy,
        };
    }

    // Spawn threads to push items concurrently
    var push_threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        const start = i * items_per_thread;
        const end = (i + 1) * items_per_thread;
        push_threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(l: *ConcurrentAwaitableList, items: []Awaitable) void {
                for (items) |*item| {
                    l.push(null, item);
                }
            }
        }.pushItems, .{ &list, awaitables[start..end] });
    }

    // Wait for all pushes to complete
    for (push_threads) |t| {
        t.join();
    }

    // Verify all items are in the list by popping them
    var popped_count: usize = 0;
    while (list.pop(null)) |_| {
        popped_count += 1;
    }

    try testing.expectEqual(total_items, popped_count);
    try testing.expectEqual(State.sentinel0, list.getState());
}

test "ConcurrentAwaitableList concurrent remove during modifications" {
    const testing = std.testing;

    var list = ConcurrentAwaitableList.init();

    const num_items = 200;

    // Create awaitables
    const awaitables = try testing.allocator.alloc(Awaitable, num_items);
    defer testing.allocator.free(awaitables);

    for (awaitables) |*a| {
        a.* = .{
            .kind = .task,
            .destroy_fn = struct {
                fn dummy(_: *Runtime, _: *Awaitable) void {}
            }.dummy,
        };
    }

    // Thread 1: Push all items
    const push_thread = try std.Thread.spawn(.{}, struct {
        fn pushItems(l: *ConcurrentAwaitableList, items: []Awaitable) void {
            for (items) |*item| {
                l.push(null, item);
            }
        }
    }.pushItems, .{ &list, awaitables });

    // Thread 2: Pop items
    var pop_count = std.atomic.Value(usize).init(0);
    const pop_thread = try std.Thread.spawn(.{}, struct {
        fn popItems(l: *ConcurrentAwaitableList, count: *std.atomic.Value(usize)) void {
            var local_count: usize = 0;
            while (local_count < 100) {
                if (l.pop(null)) |_| {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.popItems, .{ &list, &pop_count });

    // Thread 3: Remove specific items (every 3rd item)
    var remove_count = std.atomic.Value(usize).init(0);
    const remove_thread = try std.Thread.spawn(.{}, struct {
        fn removeItems(l: *ConcurrentAwaitableList, items: []Awaitable, count: *std.atomic.Value(usize)) void {
            var local_count: usize = 0;
            var i: usize = 0;
            while (i < items.len) : (i += 3) {
                if (l.remove(null, &items[i])) {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.removeItems, .{ &list, awaitables, &remove_count });

    // Wait for all threads
    push_thread.join();
    pop_thread.join();
    remove_thread.join();

    // Drain remaining items
    var remaining_count: usize = 0;
    while (list.pop(null)) |_| {
        remaining_count += 1;
    }

    const total_processed = pop_count.load(.monotonic) + remove_count.load(.monotonic) + remaining_count;

    // Verify all items were accounted for
    try testing.expectEqual(num_items, total_processed);
    try testing.expectEqual(State.sentinel0, list.getState());
}

test "ConcurrentAwaitableList popOrTransition with concurrent removals" {
    const testing = std.testing;

    var list = ConcurrentAwaitableList.initWithState(.sentinel0);

    const num_items = 500;

    // Create awaitables
    const awaitables = try testing.allocator.alloc(Awaitable, num_items);
    defer testing.allocator.free(awaitables);

    for (awaitables) |*a| {
        a.* = .{
            .kind = .task,
            .destroy_fn = struct {
                fn dummy(_: *Runtime, _: *Awaitable) void {}
            }.dummy,
        };
    }

    // Push all items first
    for (awaitables) |*a| {
        list.push(null, a);
    }

    // Thread 1: popOrTransition from sentinel0 to sentinel1
    var pop_count = std.atomic.Value(usize).init(0);
    var pops_done = std.atomic.Value(bool).init(false);
    const pop_thread = try std.Thread.spawn(.{}, struct {
        fn popItems(l: *ConcurrentAwaitableList, count: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
            var local_count: usize = 0;
            while (true) {
                if (l.popOrTransition(null, .sentinel0, .sentinel1)) |_| {
                    local_count += 1;
                } else {
                    // Queue became empty and transitioned
                    break;
                }
            }
            count.store(local_count, .monotonic);
            done.store(true, .monotonic);
        }
    }.popItems, .{ &list, &pop_count, &pops_done });

    // Thread 2: Remove random items while popping
    var remove_count = std.atomic.Value(usize).init(0);
    const remove_thread = try std.Thread.spawn(.{}, struct {
        fn removeItems(l: *ConcurrentAwaitableList, items: []Awaitable, count: *std.atomic.Value(usize), done: *std.atomic.Value(bool)) void {
            var local_count: usize = 0;
            // Try to remove items while the other thread is popping
            for (items) |*item| {
                if (done.load(.monotonic)) break;
                if (l.remove(null, item)) {
                    local_count += 1;
                }
            }
            count.store(local_count, .monotonic);
        }
    }.removeItems, .{ &list, awaitables, &remove_count, &pops_done });

    pop_thread.join();
    remove_thread.join();

    const total_processed = pop_count.load(.monotonic) + remove_count.load(.monotonic);

    // Verify all items were accounted for and state transitioned
    try testing.expectEqual(num_items, total_processed);
    try testing.expectEqual(State.sentinel1, list.getState());
}

test "ConcurrentAwaitableList stress test with heavy contention" {
    const testing = std.testing;

    var list = ConcurrentAwaitableList.init();

    const num_threads = 8;
    const items_per_thread = 200;
    const total_items = num_threads * items_per_thread;

    // Create awaitables
    const awaitables = try testing.allocator.alloc(Awaitable, total_items);
    defer testing.allocator.free(awaitables);

    for (awaitables) |*a| {
        a.* = .{
            .kind = .task,
            .destroy_fn = struct {
                fn dummy(_: *Runtime, _: *Awaitable) void {}
            }.dummy,
        };
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
            fn stressTest(l: *ConcurrentAwaitableList, my_items: []Awaitable, all_items: []Awaitable, thread_counts: *ThreadCounts, thread_id: usize) void {
                // Phase 1: Push all my items
                for (my_items) |*item| {
                    l.push(null, item);
                }

                // Phase 2: Simultaneously pop and remove
                var local_pop_count: usize = 0;
                var local_remove_count: usize = 0;
                for (0..100) |j| {
                    // Try to pop
                    if (l.pop(null)) |_| {
                        local_pop_count += 1;
                    }

                    // Try to remove a specific item (deterministically based on thread_id)
                    const idx = (thread_id * 13 + j * 7) % all_items.len;
                    if (l.remove(null, &all_items[idx])) {
                        local_remove_count += 1;
                    }
                }

                thread_counts.popped.store(local_pop_count, .monotonic);
                thread_counts.removed.store(local_remove_count, .monotonic);
            }
        }.stressTest, .{ &list, awaitables[start..end], awaitables, &counts[i], i });
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
    while (list.pop(null)) |_| {
        remaining += 1;
    }

    const total_accounted = total_popped + total_removed + remaining;

    // All items must be accounted for
    try testing.expectEqual(total_items, total_accounted);
    try testing.expectEqual(State.sentinel0, list.getState());
}
