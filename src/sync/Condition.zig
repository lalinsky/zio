// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

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
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const coroutines = @import("../coroutines.zig");
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const resumeTask = @import("../core/task.zig").resumeTask;
const Mutex = @import("Mutex.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../core/WaitNode.zig");
const Timeout = @import("../core/timeout.zig").Timeout;

wait_queue: WaitQueue(WaitNode) = .empty,

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
    const task = runtime.getCurrentTask() orelse unreachable;
    const executor = task.getExecutor();

    // Transition to preparing_to_wait state before adding to queue
    task.state.store(.preparing_to_wait, .release);

    // Add to wait queue before releasing mutex
    self.wait_queue.push(&task.awaitable.wait_node);

    // Atomically release mutex
    mutex.unlock(runtime);

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If someone wakes us before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&task.awaitable.wait_node);
        if (!was_in_queue) {
            // We were already removed by signal() which will wake us.
            // Since we're being cancelled and won't process the signal,
            // wake another waiter to receive the signal instead.
            if (self.wait_queue.pop()) |next_waiter| {
                next_waiter.wake();
            }
        }
        // Must reacquire mutex before returning
        mutex.lockUncancelable(runtime);
        return err;
    };

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockUncancelable(runtime);
    try runtime.checkCanceled();
}

/// Atomically releases the mutex and waits for a signal with cancellation shielding.
///
/// Like `wait()`, but guarantees the wait operation completes even if cancellation
/// occurs. Cancellation requests are ignored during the wait operation.
///
/// This function must be called while holding the mutex. It will:
/// 1. Add the current task to the wait queue
/// 2. Release the mutex
/// 3. Suspend until signaled by `signal()` or `broadcast()`
/// 4. Reacquire the mutex before returning
///
/// This is useful in critical sections where you must wait for a condition regardless
/// of cancellation (e.g., cleanup operations that need to wait for resources to be freed).
///
/// If you need to propagate cancellation after the wait completes, call
/// `runtime.checkCanceled()` after this function returns.
pub fn waitUncancelable(self: *Condition, runtime: *Runtime, mutex: *Mutex) void {
    runtime.beginShield();
    defer runtime.endShield();
    self.wait(runtime, mutex) catch unreachable;
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
pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) (Timeoutable || Cancelable)!void {
    const task = runtime.getCurrentTask() orelse unreachable;
    const executor = task.getExecutor();

    // Transition to preparing_to_wait state before adding to queue
    task.state.store(.preparing_to_wait, .release);

    self.wait_queue.push(&task.awaitable.wait_node);

    // Set up timeout
    var timeout = Timeout.init;
    defer timeout.clear(runtime);
    timeout.set(runtime, timeout_ns);

    // Atomically release mutex
    mutex.unlock(runtime);

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If someone wakes us before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // Try to remove from queue
        const was_in_queue = self.wait_queue.remove(&task.awaitable.wait_node);
        if (!was_in_queue) {
            // We were already removed by signal() which will wake us.
            // Since we're being cancelled and won't process the signal,
            // wake another waiter to receive the signal instead.
            if (self.wait_queue.pop()) |next_waiter| {
                next_waiter.wake();
            }
        }

        // Clear timeout before reacquiring mutex to prevent spurious timeout during lock wait
        timeout.clear(runtime);

        // Must reacquire mutex before returning
        mutex.lockUncancelable(runtime);
        // Cancellation during lock has priority over timeout
        try runtime.checkCanceled();

        // Check if this timeout triggered, otherwise it was user cancellation
        try runtime.checkTimeout(&timeout);
        return err;
    };

    // Clear timeout before reacquiring mutex to prevent spurious timeout during lock wait
    timeout.clear(runtime);

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockUncancelable(runtime);
    try runtime.checkCanceled();

    // If timeout fired, we should have received error.Canceled from yield or checkCanceled
    std.debug.assert(!timeout.triggered);
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
    _ = runtime;
    if (self.wait_queue.pop()) |wait_node| {
        wait_node.wake();
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
    _ = runtime;
    while (self.wait_queue.pop()) |wait_node| {
        wait_node.wake();
    }
}

test "Condition basic wait/signal" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ runtime, &mutex, &condition, &ready }, .{});
    defer waiter_task.cancel(runtime);
    var signaler_task = try runtime.spawn(TestFn.signaler, .{ runtime, &mutex, &condition, &ready }, .{});
    defer signaler_task.cancel(runtime);

    try runtime.run();

    try testing.expect(ready);
}

test "Condition timedWait timeout" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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

    try runtime.runUntilComplete(TestFn.waiter, .{ runtime, &mutex, &condition, &timed_out }, .{});

    try testing.expect(timed_out);
}

test "Condition broadcast" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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

    var waiter1 = try runtime.spawn(TestFn.waiter, .{ runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter1.cancel(runtime);
    var waiter2 = try runtime.spawn(TestFn.waiter, .{ runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter2.cancel(runtime);
    var waiter3 = try runtime.spawn(TestFn.waiter, .{ runtime, &mutex, &condition, &ready, &waiter_count }, .{});
    defer waiter3.cancel(runtime);
    var broadcaster_task = try runtime.spawn(TestFn.broadcaster, .{ runtime, &mutex, &condition, &ready }, .{});
    defer broadcaster_task.cancel(runtime);

    try runtime.run();

    try testing.expect(ready);
    try testing.expectEqual(@as(u32, 3), waiter_count);
}
