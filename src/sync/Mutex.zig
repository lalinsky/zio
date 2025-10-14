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
const coroutines = @import("../coroutines.zig");
const AwaitableList = @import("../runtime.zig").AwaitableList;
const AnyTask = @import("../runtime.zig").AnyTask;

owner: std.atomic.Value(?*coroutines.Coroutine) = std.atomic.Value(?*coroutines.Coroutine).init(null),
wait_queue: AwaitableList = .{},

const Mutex = @This();

/// Creates a new unlocked mutex.
pub const init: Mutex = .{};

/// Attempts to acquire the mutex without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the mutex
/// is already locked by another coroutine or if called outside a coroutine context.
/// This function will never suspend the current task. If you need blocking behavior, use `lock()` instead.
pub fn tryLock(self: *Mutex) bool {
    const current = coroutines.getCurrent() orelse return false;

    // Try to atomically set owner from null to current
    return self.owner.cmpxchgStrong(null, current, .acquire, .monotonic) == null;
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
/// Returns `error.Cancelled` if the task is cancelled while waiting for the lock.
/// ```
pub fn lock(self: *Mutex, runtime: *Runtime) Cancelable!void {
    const current = coroutines.getCurrent() orelse unreachable;
    const executor = Executor.fromCoroutine(current);

    // Fast path: try to acquire unlocked mutex
    if (self.tryLock()) return;

    // Slow path: add current task to wait queue and suspend
    const task = AnyTask.fromCoroutine(current);
    self.wait_queue.push(&task.awaitable);

    // Suspend until woken by unlock()
    executor.yield(.waiting) catch |err| {
        if (!self.wait_queue.remove(&task.awaitable)) {
            // We already inherited the lock; drop it so others can proceed.
            self.unlock(runtime);
        }
        return err;
    };

    // When we wake up, unlock() has already transferred ownership to us
    const owner = self.owner.load(.acquire);
    std.debug.assert(owner == current);
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
    const current = coroutines.getCurrent() orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    std.debug.assert(self.owner.load(.monotonic) == current);

    // Check if there are waiters
    if (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        // Transfer ownership directly to next waiter
        self.owner.store(&task.coro, .release);
        // Wake them up (they already own the lock)
        executor.markReady(&task.coro);
    } else {
        // No waiters, release the lock completely
        self.owner.store(null, .release);
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
