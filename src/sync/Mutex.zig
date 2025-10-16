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
const AnyTask = @import("../runtime.zig").AnyTask;
const ConcurrentAwaitableList = @import("../core/ConcurrentAwaitableList.zig");

const Mutex = @This();

/// FIFO wait queue with lock state encoded in sentinel values:
/// - sentinel0 (0b00) = locked, no waiters
/// - sentinel1 (0b01) = unlocked
/// - pointer = locked with waiters
queue: ConcurrentAwaitableList = ConcurrentAwaitableList.initWithState(.sentinel1),

const State = ConcurrentAwaitableList.State;
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
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);

    // Fast path: try to acquire unlocked mutex
    if (self.queue.tryTransition(unlocked, locked_once)) {
        return;
    }

    // Slow path: add to FIFO wait queue
    const task = AnyTask.fromCoroutine(current);
    const awaitable = &task.awaitable;

    self.queue.push(executor, awaitable);

    // Suspend until woken by unlock()
    executor.yield(.waiting, .allow_cancel) catch |err| {
        // Cancellation - try to remove ourselves from queue
        if (!self.queue.remove(executor, awaitable)) {
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
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);

    while (true) {
        // Try fast path: no waiters
        if (self.queue.tryTransition(locked_once, unlocked)) {
            return;
        }

        // Slow path: has waiters, pop one and wake it
        if (self.queue.pop(executor)) |awaitable| {
            wakeWaiter(awaitable);
            return;
        }

        // Race: waiter removed itself (via cancellation) between check and pop.
        // Loop and retry - either:
        // 1. New waiter arrived → pop will succeed next iteration
        // 2. No new waiters → tryTransition will succeed next iteration
    }
}

fn wakeWaiter(awaitable: *Awaitable) void {
    const task = AnyTask.fromAwaitable(awaitable);
    const executor = Executor.fromCoroutine(&task.coro);
    executor.markReady(&task.coro);
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
