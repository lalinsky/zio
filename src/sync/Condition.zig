//! A condition variable for coordinating async tasks.
//!
//! Condition variables allow tasks to wait for certain conditions to become true
//! while cooperating with other tasks. They are always used in conjunction with
//! a Mutex to protect the shared state being checked.
//!
//! This implementation is designed for the zio async runtime and provides
//! cooperative waiting that works with coroutines. When a coroutine waits on
//! a condition, it suspends and yields to the executor, allowing other tasks
//! to run.
//!
//! The standard pattern for using a condition variable is:
//! 1. Lock the mutex
//! 2. Check the condition in a loop
//! 3. If condition is false, wait on the condition variable (this atomically
//!    releases the mutex and suspends)
//! 4. When woken, the mutex is automatically reacquired
//! 5. Loop back to check condition again
//! 6. Once condition is true, proceed with work
//! 7. Unlock the mutex
//!
//! Wait operations are cancelable. If a task is cancelled while waiting,
//! the mutex will be reacquired before the error is returned, maintaining
//! the invariant that wait() always holds the mutex on return.
//!
//! ## Example
//!
//! ```zig
//! var mutex: zio.Mutex = .init;
//! var condition: zio.Condition = .init;
//! var ready = false;
//!
//! // Waiter task
//! try mutex.lock(rt);
//! defer mutex.unlock(rt);
//! while (!ready) {
//!     try condition.wait(rt, &mutex);
//! }
//! // ... proceed with work ...
//!
//! // Signaler task
//! try mutex.lock(rt);
//! ready = true;
//! mutex.unlock(rt);
//! condition.signal(rt);
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../runtime.zig").Cancelable;
const coroutines = @import("../coroutines.zig");
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const Mutex = @import("Mutex.zig");
const LockFreeAwaitableQueue = @import("LockFreeAwaitableQueue.zig");

wait_queue: LockFreeAwaitableQueue = LockFreeAwaitableQueue.init(),

const Condition = @This();

/// Creates a new condition variable.
pub const init: Condition = .{};

/// Atomically releases the mutex and waits for a signal.
///
/// This function must be called while holding the mutex. It will:
/// 1. Add the current task to the wait queue
/// 2. Release the mutex
/// 3. Suspend until signaled by `signal()` or `broadcast()`
/// 4. Reacquire the mutex before returning
///
/// This function should typically be called in a loop that checks the condition:
/// ```zig
/// try mutex.lock(rt);
/// defer mutex.unlock(rt);
/// while (!condition_is_true) {
///     try condition.wait(rt, &mutex);
/// }
/// ```
///
/// Returns `error.Canceled` if the task is cancelled while waiting. The mutex
/// will still be held when returning with an error.
pub fn wait(self: *Condition, runtime: *Runtime, mutex: *Mutex) Cancelable!void {
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);

    // Add to wait queue before releasing mutex
    self.wait_queue.push(executor, &task.awaitable);

    // Atomically release mutex and wait
    mutex.unlock(runtime);
    executor.yield(.waiting, .allow_cancel) catch |err| {
        // On cancellation, remove from queue and reacquire mutex
        _ = self.wait_queue.remove(executor, &task.awaitable);
        // Must reacquire mutex before returning
        mutex.lockNoCancel(runtime);
        return err;
    };

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockNoCancel(runtime);
    try runtime.checkCanceled();
}

/// Atomically releases the mutex and waits for a signal with a timeout.
///
/// Like `wait()`, but will return `error.Timeout` if no signal is received
/// within the specified duration.
///
/// The timeout is specified in nanoseconds. If a signal is received before
/// the timeout expires, the function returns successfully with the mutex held.
/// If the timeout expires first, `error.Timeout` is returned with the mutex held.
///
/// Returns `error.Canceled` if the task is cancelled while waiting. Cancellation
/// takes priority over timeout - if both occur, `error.Canceled` is returned.
/// The mutex will be held when returning with any error.
pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) error{ Timeout, Canceled }!void {
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);

    self.wait_queue.push(executor, &task.awaitable);

    const TimeoutContext = struct {
        wait_queue: *LockFreeAwaitableQueue,
        awaitable: *Awaitable,
        executor: *Executor,
    };

    var timeout_ctx = TimeoutContext{
        .wait_queue = &self.wait_queue,
        .awaitable = &task.awaitable,
        .executor = executor,
    };

    // Atomically release mutex and wait
    mutex.unlock(runtime);

    executor.timedWaitForReadyWithCallback(
        timeout_ns,
        TimeoutContext,
        &timeout_ctx,
        struct {
            fn onTimeout(ctx: *TimeoutContext) bool {
                // Try to remove from wait queue - if successful, we timed out
                // If failed, we were already signaled
                return ctx.wait_queue.remove(ctx.executor, ctx.awaitable);
            }
        }.onTimeout,
    ) catch |err| {
        // Remove from queue if canceled (timeout already handled by callback)
        if (err == error.Canceled) {
            _ = self.wait_queue.remove(executor, &task.awaitable);
        }
        // Must reacquire mutex before returning
        mutex.lockNoCancel(runtime);
        // Cancellation during lock has priority over timeout
        try runtime.checkCanceled();
        return err;
    };

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockNoCancel(runtime);
    try runtime.checkCanceled();
}

/// Wakes one task waiting on this condition variable.
///
/// If there are tasks waiting, one will be woken and made ready to run.
/// The woken task will attempt to reacquire the mutex before continuing.
///
/// If no tasks are waiting, this function does nothing.
///
/// It is typically called after modifying the shared state and releasing
/// the mutex:
/// ```zig
/// try mutex.lock(rt);
/// shared_state = new_value;
/// mutex.unlock(rt);
/// condition.signal(rt);
/// ```
pub fn signal(self: *Condition, runtime: *Runtime) void {
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    if (self.wait_queue.pop(executor)) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        const task_executor = Executor.fromCoroutine(&task.coro);
        task_executor.markReady(&task.coro);
    }
}

/// Wakes all tasks waiting on this condition variable.
///
/// All waiting tasks will be woken and made ready to run. Each woken task
/// will attempt to reacquire the mutex before continuing, so they will
/// wake up one at a time as the mutex becomes available.
///
/// If no tasks are waiting, this function does nothing.
///
/// Use this when the condition change might allow multiple waiters to proceed:
/// ```zig
/// try mutex.lock(rt);
/// shutdown_flag = true;
/// mutex.unlock(rt);
/// condition.broadcast(rt);
/// ```
pub fn broadcast(self: *Condition, runtime: *Runtime) void {
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    while (self.wait_queue.pop(executor)) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        const task_executor = Executor.fromCoroutine(&task.coro);
        task_executor.markReady(&task.coro);
    }
}

test "Condition basic wait/signal" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;
    var ready = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) !void {
            try mtx.lock(rt);
            defer mtx.unlock(rt);

            while (!ready_flag.*) {
                try cond.wait(rt, mtx);
            }
        }

        fn signaler(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) !void {
            try rt.yield(); // Give waiter time to start waiting

            try mtx.lock(rt);
            ready_flag.* = true;
            mtx.unlock(rt);

            cond.signal(rt);
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ &runtime, &mutex, &condition, &ready }, .{});
    defer waiter_task.deinit();
    var signaler_task = try runtime.spawn(TestFn.signaler, .{ &runtime, &mutex, &condition, &ready }, .{});
    defer signaler_task.deinit();

    try runtime.run();

    try testing.expect(ready);
}

test "Condition timedWait timeout" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, timeout_flag: *bool) !void {
            try mtx.lock(rt);
            defer mtx.unlock(rt);

            // Should timeout after 10ms
            cond.timedWait(rt, mtx, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &mutex, &condition, &timed_out }, .{});

    try testing.expect(timed_out);
}

test "Condition broadcast" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;
    var ready = false;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool, counter: *u32) !void {
            try mtx.lock(rt);
            defer mtx.unlock(rt);

            while (!ready_flag.*) {
                try cond.wait(rt, mtx);
            }
            counter.* += 1;
        }

        fn broadcaster(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) !void {
            // Give waiters time to start waiting
            try rt.yield();
            try rt.yield();
            try rt.yield();

            try mtx.lock(rt);
            ready_flag.* = true;
            mtx.unlock(rt);

            cond.broadcast(rt);
        }
    };

    var waiter1 = try runtime.spawn(TestFn.waiter, .{ &runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter1.deinit();
    var waiter2 = try runtime.spawn(TestFn.waiter, .{ &runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter2.deinit();
    var waiter3 = try runtime.spawn(TestFn.waiter, .{ &runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter3.deinit();
    var broadcaster_task = try runtime.spawn(TestFn.broadcaster, .{ &runtime, &mutex, &condition, &ready }, .{});
    defer broadcaster_task.deinit();

    try runtime.run();

    try testing.expect(ready);
    try testing.expectEqual(@as(u32, 3), waiter_count);
}
