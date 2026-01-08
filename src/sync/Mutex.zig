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
//! try mutex.lock(rt);
//! defer mutex.unlock(rt);
//!
//! shared_data += 1;
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../common.zig").Cancelable;
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const resumeTask = @import("../runtime/task.zig").resumeTask;
const WaitNode = @import("../runtime/WaitNode.zig");
const CompactWaitQueue = @import("../utils/wait_queue.zig").CompactWaitQueue;
const Waiter = @import("common.zig").Waiter;

const Mutex = @This();

/// FIFO wait queue with lock state encoded in sentinel values:
/// - sentinel0 (0b00) = locked, no waiters
/// - sentinel1 (0b01) = unlocked
/// - pointer = locked with waiters
queue: CompactWaitQueue(WaitNode) = .initWithState(.sentinel1),

const State = CompactWaitQueue(WaitNode).State;
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
pub fn lock(self: *Mutex, runtime: *Runtime) Cancelable!void {
    const task = runtime.getCurrentTask();
    const executor = task.getExecutor();

    // Fast path: try to acquire unlocked mutex
    if (self.queue.tryTransition(unlocked, locked_once)) {
        return;
    }

    // Slow path: add to FIFO wait queue

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init(&task.awaitable);

    // Transition to preparing_to_wait state before adding to queue
    task.state.store(.preparing_to_wait, .release);

    // Try to push to queue, or if mutex is unlocked, acquire it atomically
    // This prevents the race: unlocked -> has_waiters (skipping locked_once)
    const result = self.queue.pushOrTransition(unlocked, locked_once, &waiter.wait_node);
    if (result == .transitioned) {
        // Mutex was unlocked, we acquired it via transition to locked_once
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If someone wakes us before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // Cancellation - try to remove ourselves from queue
        if (!self.queue.remove(&waiter.wait_node)) {
            // Already inherited the lock
            self.unlock(runtime);
        }
        return err;
    };

    // Acquire fence: synchronize-with unlock()'s .release in pop()
    // Ensures visibility of all writes made by the previous lock holder
    _ = self.queue.getState();
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
pub fn lockUncancelable(self: *Mutex, runtime: *Runtime) void {
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
    // Pop one waiter or transition from locked_once to unlocked
    // Handles cancellation race by retrying internally
    if (self.queue.popOrTransition(locked_once, unlocked)) |wait_node| {
        wait_node.wake();
    }
}

test "Mutex basic lock/unlock" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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

    var task1 = try runtime.spawn(TestFn.worker, .{ runtime, &shared_counter, &mutex }, .{});
    defer task1.cancel(runtime);
    var task2 = try runtime.spawn(TestFn.worker, .{ runtime, &shared_counter, &mutex }, .{});
    defer task2.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(u32, 200), shared_counter);
}

test "Mutex tryLock" {
    const testing = std.testing;

    const rt = try Runtime.init(testing.allocator, .{});
    defer rt.deinit();

    var mutex = Mutex.init;

    try testing.expect(mutex.tryLock()); // Should succeed
    try testing.expect(!mutex.tryLock()); // Should fail (already locked)
    mutex.unlock(rt);
    try testing.expect(mutex.tryLock()); // Should succeed again
    mutex.unlock(rt);
}
