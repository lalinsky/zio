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
                e.yield(.ready, .no_cancel);
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
