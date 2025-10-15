//! A mutual exclusion primitive for protecting shared data in async contexts.
//!
//! This mutex is designed for use with the zio async runtime and provides
//! cooperative locking that works with coroutines. When a coroutine attempts
//! to acquire a locked mutex, it will suspend and yield to the executor,
//! allowing other tasks to run.
//!
//! Lock operations are cancelable. If a task is cancelled while waiting
//! for a mutex, it will properly handle cleanup and propagate the error.
//!
//! ## Example
//!
//! ```zig
//! var mutex: zio.Mutex = .init;
//! var shared_data: u32 = 0;
//!
//! try mutex.lock(rt);
//! defer mutex.unlock(rt);
//!
//! shared_data += 1;
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../runtime.zig").Cancelable;
const Awaitable = @import("../runtime.zig").Awaitable;
const AwaitableList = @import("../runtime.zig").AwaitableList;
const AnyTask = @import("../runtime.zig").AnyTask;

const Mutex = @This();

/// Head of FIFO wait queue with state encoded in lower bits
/// - 0b00 (0) = locked, no waiters
/// - 0b01 (1) = unlocked
/// - ptr (aligned, >1) = locked with waiters, head pointer
/// - ptr | 0b10 = locked with waiters, mutation lock held
head: std.atomic.Value(usize) = std.atomic.Value(usize).init(@intFromEnum(State.unlocked)),

/// Tail of FIFO wait queue (only valid when head is a pointer)
/// Not atomic - only accessed while holding mutation lock
tail: ?*Awaitable = null,

pub const State = enum(usize) {
    locked_once = 0b00,
    unlocked = 0b01,
    _,

    pub fn isPointer(s: State) bool {
        const val = @intFromEnum(s);
        return val > 1; // Not a sentinel (0 or 1) = pointer
    }

    pub fn hasMutationBit(s: State) bool {
        return @intFromEnum(s) & 0b10 != 0;
    }

    pub fn getPtr(s: State) ?*Awaitable {
        if (!s.isPointer()) return null;
        const addr = @intFromEnum(s) & ~@as(usize, 0b11);
        return @ptrFromInt(addr);
    }

    pub fn fromPtr(ptr: *Awaitable) State {
        const addr = @intFromPtr(ptr);
        std.debug.assert(addr & 0b11 == 0); // Must be 8-byte aligned
        return @enumFromInt(addr);
    }
};

/// Creates a new unlocked mutex.
pub const init: Mutex = .{};

// Helper functions for mutation lock

/// Acquire exclusive access to manipulate the wait queue.
/// Spins until mutation lock is acquired.
/// Returns the state before mutation bit was set.
fn acquireMutationLock(self: *Mutex) State {
    while (true) {
        // Try to set mutation bit atomically
        const old = self.head.fetchOr(0b10, .acquire);
        const old_state: State = @enumFromInt(old);

        if (!old_state.hasMutationBit()) {
            // We got it! old_state is the state before we set the bit
            return old_state;
        }

        // Someone else holds the mutation lock, spin
        std.atomic.spinLoopHint();
    }
}

/// Release exclusive access to wait queue.
fn releaseMutationLock(self: *Mutex) void {
    // Clear mutation bit
    _ = self.head.fetchXor(0b10, .release);
}

/// Attempts to acquire the mutex without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the mutex
/// is already locked by another coroutine.
/// This function will never suspend the current task. If you need blocking behavior, use `lock()` instead.
pub fn tryLock(self: *Mutex) bool {
    // Try to atomically set head from unlocked to locked_once
    // Memory ordering: acquire synchronizes-with unlock's release to see protected data
    // On failure: monotonic is sufficient since we don't access shared state
    return self.head.cmpxchgStrong(
        @intFromEnum(State.unlocked),
        @intFromEnum(State.locked_once),
        .acquire,
        .monotonic,
    ) == null;
}

/// Acquires the mutex, blocking if it is already locked.
///
/// If the mutex is currently unlocked, this function acquires it immediately.
/// If the mutex is locked by another coroutine, the current task will be
/// suspended until the lock becomes available.
///
/// This function must be called from within a coroutine context managed by
/// the zio runtime.
///
/// Returns `error.Canceled` if the task is cancelled while waiting for the lock.
pub fn lock(self: *Mutex, runtime: *Runtime) Cancelable!void {
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);

    // Fast path: try to acquire unlocked mutex
    if (self.tryLock()) return;

    // Slow path: add to FIFO wait queue (enqueue at tail)
    const task = AnyTask.fromCoroutine(current);
    const awaitable = &task.awaitable;

    // Initialize awaitable as not in list
    awaitable.next = null;
    awaitable.prev = null;

    while (true) {
        const state_val = self.head.load(.acquire);
        const state: State = @enumFromInt(state_val);

        // Check if became unlocked (race)
        if (state == .unlocked) {
            if (self.head.cmpxchgWeak(
                @intFromEnum(State.unlocked),
                @intFromEnum(State.locked_once),
                .acquire,
                .acquire,
            )) |_| {
                continue;
            }
            return; // Got lock
        }

        // First waiter - no mutation lock needed, we're creating the queue
        if (state == .locked_once) {
            if (self.head.cmpxchgWeak(
                @intFromEnum(State.locked_once),
                @intFromEnum(State.fromPtr(awaitable)),
                .release,
                .monotonic,
            )) |_| {
                continue;
            }
            // Success - we're the first and only waiter
            self.tail = awaitable;
            break;
        }

        // Queue exists - acquire mutation lock to append to tail
        if (state.hasMutationBit()) {
            // Spin until mutation lock is free
            std.atomic.spinLoopHint();
            continue;
        }

        const old_state = self.acquireMutationLock();

        // Check state didn't change to unlocked/locked_once while we waited
        if (old_state == .unlocked or old_state == .locked_once) {
            self.releaseMutationLock();
            continue;
        }

        // Append to tail (safe - we have mutation lock)
        const old_tail = self.tail.?;
        awaitable.prev = old_tail;
        awaitable.next = null;
        old_tail.next = awaitable;
        self.tail = awaitable;

        self.releaseMutationLock();
        break; // Successfully enqueued
    }

    // Suspend until woken by unlock()
    executor.yield(.waiting) catch |err| {
        // Cancellation - try to remove ourselves from queue
        if (!tryRemoveFromQueue(self, awaitable)) {
            // Already inherited the lock
            self.unlock(runtime);
        }
        return err;
    };
}

/// Acquires the mutex with cancellation shielding.
///
/// Like `lock()`, but guarantees the mutex is held when returning, even if
/// cancellation occurs during acquisition. Cancellation requests are ignored
/// during the lock operation.
///
/// This is useful in critical sections where you must hold the mutex regardless
/// of cancellation (e.g., cleanup operations like close(), post()).
///
/// If you need to propagate cancellation after acquiring the lock, call
/// `runtime.checkCanceled()` after this function returns.
pub fn lockNoCancel(self: *Mutex, runtime: *Runtime) void {
    runtime.beginShield();
    defer runtime.endShield();
    self.lock(runtime) catch unreachable;
}

/// Releases the mutex.
///
/// This function must be called by the coroutine that currently holds the lock.
/// If there are tasks waiting for the lock, the next waiter will be woken and
/// given ownership of the mutex. If there are no waiters, the mutex is released
/// to the unlocked state.
///
/// It is undefined behavior if the current coroutine does not hold the lock.
pub fn unlock(self: *Mutex, runtime: *Runtime) void {
    _ = runtime;

    while (true) {
        const state_val = self.head.load(.acquire);
        const state: State = @enumFromInt(state_val);

        // No waiters - transition to unlocked
        if (state == .locked_once) {
            if (self.head.cmpxchgWeak(
                @intFromEnum(State.locked_once),
                @intFromEnum(State.unlocked),
                .release,
                .acquire,
            )) |_| {
                continue;
            }
            return; // Successfully unlocked
        }

        // Has waiters - acquire mutation lock to pop head
        if (state.hasMutationBit()) {
            std.atomic.spinLoopHint();
            continue;
        }

        const old_state = self.acquireMutationLock();

        // Check state didn't change
        if (old_state == .locked_once or old_state == .unlocked) {
            self.releaseMutationLock();
            continue;
        }

        const old_head = old_state.getPtr().?;
        const next = old_head.next;

        // Clear old head's pointers
        old_head.next = null;
        old_head.prev = null;

        if (next == null) {
            // Last waiter - transition to locked_once
            self.tail = null;
            self.head.store(@intFromEnum(State.locked_once), .release);
        } else {
            // More waiters - update head
            next.?.prev = null;
            self.head.store(@intFromEnum(State.fromPtr(next.?)), .release);
            // tail unchanged - still points to same tail node
        }

        // Wake the waiter (now holds the lock)
        wakeWaiter(old_head);
        return;
    }
}

// Helper functions

fn wakeWaiter(awaitable: *Awaitable) void {
    const task = AnyTask.fromAwaitable(awaitable);
    const executor = Executor.fromCoroutine(&task.coro);
    executor.markReady(&task.coro);
}

fn tryRemoveFromQueue(self: *Mutex, awaitable: *Awaitable) bool {
    while (true) {
        const state_val = self.head.load(.acquire);
        const state: State = @enumFromInt(state_val);

        // Not in queue
        if (state == .unlocked or state == .locked_once) {
            return false;
        }

        // Spin if mutation in progress
        if (state.hasMutationBit()) {
            std.atomic.spinLoopHint();
            continue;
        }

        const old_state = self.acquireMutationLock();
        defer self.releaseMutationLock();

        // Check still in queue
        if (old_state == .unlocked or old_state == .locked_once) {
            return false;
        }

        const head = old_state.getPtr().?;

        // Check if we're actually in the list (using prev/next pointers)
        // If prev is null and we're not head, we're not in the list
        if (awaitable.prev == null and head != awaitable) {
            return false; // Not in list
        }

        // O(1) removal with doubly-linked list
        // Note: Even if unlock() is processing this node concurrently, it's safe
        // because both operations hold the mutation lock (cannot overlap), and
        // wakeWaiter() only reads the node (doesn't modify it). The node remains
        // valid memory since it lives on the coroutine's stack.
        if (awaitable.prev) |prev| {
            prev.next = awaitable.next;
        }
        if (awaitable.next) |next| {
            next.prev = awaitable.prev;
        }

        // Update head if removing head
        if (head == awaitable) {
            if (awaitable.next) |next| {
                self.head.store(@intFromEnum(State.fromPtr(next)), .release);
            } else {
                // Was only waiter
                self.head.store(@intFromEnum(State.locked_once), .release);
                self.tail = null;
            }
        } else if (self.tail == awaitable) {
            // Update tail if removing tail
            self.tail = awaitable.prev;
        }

        // Clear pointers
        awaitable.next = null;
        awaitable.prev = null;

        return true;
    }
}

test "Mutex basic lock/unlock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(rt: *Runtime, counter: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
                try mtx.lock(rt);
                defer mtx.unlock(rt);
                counter.* += 1;
            }
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task2.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 200), shared_counter);
}

test "Mutex tryLock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init;

    const TestFn = struct {
        fn testTryLock(rt: *Runtime, mtx: *Mutex, results: *[3]bool) void {
            results[0] = mtx.tryLock(); // Should succeed
            results[1] = mtx.tryLock(); // Should fail (already locked)
            mtx.unlock(rt);
            results[2] = mtx.tryLock(); // Should succeed again
            mtx.unlock(rt);
        }
    };

    var results: [3]bool = undefined;
    try runtime.runUntilComplete(TestFn.testTryLock, .{ &runtime, &mutex, &results }, .{});

    try testing.expect(results[0]); // First tryLock should succeed
    try testing.expect(!results[1]); // Second tryLock should fail
    try testing.expect(results[2]); // Third tryLock should succeed
}
