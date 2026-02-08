// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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
//! try mutex.lock();
//! defer mutex.unlock();
//!
//! shared_data += 1;
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const WaitNode = @import("../runtime/WaitNode.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const Waiter = @import("../common.zig").Waiter;

const Mutex = @This();

/// FIFO wait queue with lock state encoded in sentinel values:
/// - sentinel0 (0b00) = locked, no waiters
/// - sentinel1 (0b01) = unlocked
/// - pointer = locked with waiters
queue: WaitQueue(WaitNode) = .initWithState(.sentinel1),

const State = WaitQueue(WaitNode).State;
const locked_once: State = .sentinel0;
const unlocked: State = .sentinel1;

/// Creates a new unlocked mutex.
pub const init: Mutex = .{};

/// Attempts to acquire the mutex without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the mutex
/// is already locked by another coroutine.
/// This function will never suspend the current task. If you need blocking behavior, use `lock()` instead.
pub fn tryLock(self: *Mutex) bool {
    return self.queue.tryTransition(unlocked, locked_once);
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
pub fn lock(self: *Mutex) Cancelable!void {
    // Fast path: try to acquire unlocked mutex
    if (self.queue.tryTransition(unlocked, locked_once)) {
        return;
    }

    // Slow path: add to FIFO wait queue

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Try to push to queue, or if mutex is unlocked, acquire it atomically
    // This prevents the race: unlocked -> has_waiters (skipping locked_once)
    const result = self.queue.pushOrTransition(unlocked, locked_once, &waiter.wait_node);
    if (result == .transitioned) {
        // Mutex was unlocked, we acquired it via transition to locked_once
        return;
    }

    // Wait for lock, handling spurious wakeups internally
    waiter.wait(1, .allow_cancel) catch |err| {
        // Cancellation - try to remove ourselves from queue
        if (!self.queue.remove(&waiter.wait_node)) {
            // Already inherited the lock - wait for signal to complete, then unlock
            waiter.wait(1, .no_cancel);
            self.unlock();
        }
        return err;
    };

    // Acquire fence: synchronize-with unlock()'s .release in pop()
    // Ensures visibility of all writes made by the previous lock holder
    _ = self.queue.getState();
}

/// Acquires the mutex, ignoring cancellation.
///
/// Like `lock()`, but cancellation requests are ignored during the lock
/// acquisition. This always acquires the lock and never returns an error.
///
/// This is useful in critical sections where you must hold the mutex regardless
/// of cancellation (e.g., cleanup operations like close(), post()).
///
/// If you need to propagate cancellation after acquiring the lock, call
/// `Runtime.checkCancel()` after this function returns.
pub fn lockUncancelable(self: *Mutex) void {
    // Fast path: try to acquire unlocked mutex
    if (self.queue.tryTransition(unlocked, locked_once)) {
        return;
    }

    // Slow path: add to FIFO wait queue
    var waiter: Waiter = .init();

    // Try to push to queue, or if mutex is unlocked, acquire it atomically
    const result = self.queue.pushOrTransition(unlocked, locked_once, &waiter.wait_node);
    if (result == .transitioned) {
        // Mutex was unlocked, we acquired it via transition to locked_once
        return;
    }

    // Wait with .no_cancel - ignores cancellation
    waiter.wait(1, .no_cancel);

    // Acquire fence: synchronize-with unlock()'s .release in pop()
    _ = self.queue.getState();
}

/// Releases the mutex.
///
/// This function must be called by the coroutine that currently holds the lock.
/// If there are tasks waiting for the lock, the next waiter will be woken and
/// given ownership of the mutex. If there are no waiters, the mutex is released
/// to the unlocked state.
///
/// It is undefined behavior if the current coroutine does not hold the lock.
pub fn unlock(self: *Mutex) void {
    // Pop one waiter or transition from locked_once to unlocked
    // Last waiter stays in locked_once (inherits the lock)
    // Handles cancellation race by retrying internally
    if (self.queue.popOrTransition(locked_once, unlocked, locked_once)) |wait_node| {
        Waiter.fromWaitNode(wait_node).signal();
    }
}

test "Mutex basic lock/unlock" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(counter: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
                try mtx.lock();
                defer mtx.unlock();
                counter.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.worker, .{ &shared_counter, &mutex });
    try group.spawn(TestFn.worker, .{ &shared_counter, &mutex });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(200, shared_counter);
}

test "Mutex tryLock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();

    var mutex = Mutex.init;

    try std.testing.expect(mutex.tryLock()); // Should succeed
    try std.testing.expect(!mutex.tryLock()); // Should fail (already locked)
    mutex.unlock();
    try std.testing.expect(mutex.tryLock()); // Should succeed again
    mutex.unlock();
}

test "Mutex contention" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(ctr: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
                try mtx.lock();
                defer mtx.unlock();
                ctr.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    for (0..4) |_| {
        try group.spawn(TestFn.worker, .{ &counter, &mutex });
    }

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(400, counter);
}
