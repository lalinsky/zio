// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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
//! try mutex.lock();
//! defer mutex.unlock();
//! while (!ready) {
//!     try condition.wait(&mutex);
//! }
//! // ... proceed with work ...
//!
//! // Signaler task
//! try mutex.lock();
//! ready = true;
//! mutex.unlock();
//! condition.signal();
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const beginShield = @import("../runtime.zig").beginShield;
const endShield = @import("../runtime.zig").endShield;
const checkCancel = @import("../runtime.zig").checkCancel;
const yield = @import("../runtime.zig").yield;
const Group = @import("../group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Timeout = @import("../time.zig").Timeout;
const Mutex = @import("Mutex.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const Waiter = @import("../common.zig").Waiter;

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
/// try mutex.lock();
/// defer mutex.unlock();
/// while (!condition_is_true) {
///     try condition.wait(&mutex);
/// }
/// ```
///
/// Returns `error.Canceled` if the task is cancelled while waiting. The mutex
/// will still be held when returning with an error.
pub fn wait(self: *Condition, mutex: *Mutex) Cancelable!void {
    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Add to wait queue before releasing mutex
    self.wait_queue.push(&waiter.node);

    // Atomically release mutex
    mutex.unlock();

    // Wait for signal, handling spurious wakeups internally
    waiter.wait(1, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.node);
        if (!was_in_queue) {
            // We were already removed by signal() - wait for signal to complete
            waiter.wait(1, .no_cancel);
            // Since we're being cancelled and won't process the signal,
            // wake another waiter to receive the signal instead.
            if (self.wait_queue.pop()) |next_waiter| {
                Waiter.fromNode(next_waiter).signal();
            }
        }
        // Must reacquire mutex before returning
        mutex.lockUncancelable();
        return err;
    };

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockUncancelable();
    checkCancel() catch |err| {
        // We won't process the signal, so wake another waiter to receive it.
        if (self.wait_queue.pop()) |next_waiter| {
            Waiter.fromNode(next_waiter).signal();
        }
        return err;
    };
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
/// `Runtime.checkCancel()` after this function returns.
pub fn waitUncancelable(self: *Condition, mutex: *Mutex) void {
    beginShield();
    defer endShield();
    self.wait(mutex) catch unreachable;
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
pub fn waitTimeout(self: *Condition, mutex: *Mutex, timeout: Timeout) (Timeoutable || Cancelable)!void {
    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    self.wait_queue.push(&waiter.node);

    // Atomically release mutex
    mutex.unlock();

    // Wait for signal or timeout, handling spurious wakeups internally
    var timed_out = false;
    waiter.timedWait(1, timeout, .allow_cancel) catch |err| switch (err) {
        // The timer fired, but signal() may have claimed this waiter just
        // behind it: whoever can still remove the node decides.
        error.Timeout => {
            if (self.wait_queue.remove(&waiter.node)) {
                timed_out = true;
            } else {
                // Claimed by signal() - take the signal instead of the
                // timeout, and wait for it to land before destroying the
                // waiter.
                waiter.wait(1, .no_cancel);
            }
        },
        error.Canceled => {
            // On cancellation, try to remove from queue
            const was_in_queue = self.wait_queue.remove(&waiter.node);
            if (!was_in_queue) {
                // Removed by signal() - wait for signal to complete before destroying waiter
                waiter.wait(1, .no_cancel);
                // Since we're being cancelled and won't process the signal,
                // wake another waiter to receive the signal instead.
                if (self.wait_queue.pop()) |next_waiter| {
                    Waiter.fromNode(next_waiter).signal();
                }
            }

            // Must reacquire mutex before returning
            mutex.lockUncancelable();

            return err;
        },
    };

    // Re-acquire mutex after waking - propagate cancellation if it occurred during lock
    mutex.lockUncancelable();
    checkCancel() catch |err| {
        // We won't process the signal, so wake another waiter to receive it.
        if (!timed_out) {
            if (self.wait_queue.pop()) |next_waiter| {
                Waiter.fromNode(next_waiter).signal();
            }
        }
        return err;
    };

    if (timed_out) {
        return error.Timeout;
    }
}

/// Alias for `waitTimeout`. Deprecated, will be removed in a future release.
pub const timedWait = waitTimeout;

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
/// try mutex.lock();
/// shared_state = new_value;
/// mutex.unlock();
/// condition.signal();
/// ```
pub fn signal(self: *Condition) void {
    if (self.wait_queue.pop()) |wait_node| {
        Waiter.fromNode(wait_node).signal();
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
/// try mutex.lock();
/// shutdown_flag = true;
/// mutex.unlock();
/// condition.broadcast();
/// ```
pub fn broadcast(self: *Condition) void {
    while (self.wait_queue.pop()) |wait_node| {
        Waiter.fromNode(wait_node).signal();
    }
}

test "Condition basic wait/signal" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;
    var ready = false;
    var waiter_ready = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn waiter(mtx: *Mutex, cond: *Condition, ready_flag: *bool, waiter_flag: *std.atomic.Value(bool)) !void {
            try mtx.lock();
            defer mtx.unlock();
            waiter_flag.store(true, .release);

            while (!ready_flag.*) {
                try cond.wait(mtx);
            }
        }

        fn signaler(mtx: *Mutex, cond: *Condition, ready_flag: *bool, waiter_flag: *std.atomic.Value(bool)) !void {
            // Wait for waiter to be ready
            while (!waiter_flag.load(.acquire)) {
                try yield();
            }

            try mtx.lock();
            ready_flag.* = true;
            mtx.unlock();

            cond.signal();
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.waiter, .{ &mutex, &condition, &ready, &waiter_ready });
    try group.spawn(TestFn.signaler, .{ &mutex, &condition, &ready, &waiter_ready });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(ready);
}

test "Condition waitTimeout timeout" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;

    try mutex.lock();
    defer mutex.unlock();

    const result = condition.waitTimeout(&mutex, .{ .duration = .fromMilliseconds(10) });
    try std.testing.expectError(error.Timeout, result);
}

test "Condition broadcast" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var mutex = Mutex.init;
    var condition = Condition.init;
    var ready = false;
    var waiter_count: u32 = 0;
    var waiters_ready = std.atomic.Value(u32).init(0);

    const TestFn = struct {
        fn waiter(mtx: *Mutex, cond: *Condition, ready_flag: *bool, counter: *u32, waiters_flag: *std.atomic.Value(u32)) !void {
            try mtx.lock();
            defer mtx.unlock();
            _ = waiters_flag.fetchAdd(1, .release);

            while (!ready_flag.*) {
                try cond.wait(mtx);
            }
            counter.* += 1;
        }

        fn broadcaster(mtx: *Mutex, cond: *Condition, ready_flag: *bool, waiters_flag: *std.atomic.Value(u32)) !void {
            // Wait for all waiters to be ready
            while (waiters_flag.load(.acquire) < 3) {
                try yield();
            }

            try mtx.lock();
            ready_flag.* = true;
            mtx.unlock();

            cond.broadcast();
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.waiter, .{ &mutex, &condition, &ready, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.waiter, .{ &mutex, &condition, &ready, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.waiter, .{ &mutex, &condition, &ready, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.broadcaster, .{ &mutex, &condition, &ready, &waiters_ready });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(ready);
    try std.testing.expectEqual(3, waiter_count);
}

test "Condition: a waiter canceled while reacquiring the mutex passes the signal on" {
    // The first waiter is signaled and resumes, then blocks reacquiring the
    // mutex, and only then is canceled. It returns the cancellation without
    // acting on the signal, so the signal must go to the second waiter.
    //
    // One executor, so the order of events is pinned every time.
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    const State = struct {
        mutex: Mutex = .init,
        cond: Condition = .init,
        items: u32 = 0,
        entered: std.atomic.Value(u32) = .init(0),
    };

    const Outcome = struct {
        err: ?anyerror = null,
        took_item: bool = false,
    };

    const Tasks = struct {
        fn waiter(state: *State, timeout: Timeout, out: *Outcome) !void {
            try state.mutex.lock();
            defer state.mutex.unlock();
            _ = state.entered.fetchAdd(1, .release);
            while (state.items == 0) {
                const result = if (timeout == .none)
                    state.cond.wait(&state.mutex)
                else
                    state.cond.waitTimeout(&state.mutex, timeout);
                result catch |err| {
                    out.err = err;
                    return;
                };
            }
            state.items -= 1;
            out.took_item = true;
        }
    };

    for ([_]Timeout{ .none, .{ .duration = .fromSeconds(10) } }) |timeout| {
        var state: State = .{};
        var first_out: Outcome = .{};
        var second_out: Outcome = .{};

        var first = try runtime.spawn(Tasks.waiter, .{ &state, timeout, &first_out });
        while (state.entered.load(.acquire) < 1) try yield();
        try yield(); // let the first waiter park
        var second = try runtime.spawn(Tasks.waiter, .{ &state, timeout, &second_out });
        while (state.entered.load(.acquire) < 2) try yield();
        try yield(); // let the second waiter park

        try state.mutex.lock();
        state.items = 1;
        state.cond.signal();
        try yield(); // let the first waiter wake and block on the mutex
        first.awaitable.?.cancel(); // request only, the handle's cancel() would wait
        state.mutex.unlock();
        try first.join();

        for (0..10) |_| try yield();
        const second_took_item = second_out.took_item;
        second.cancel();
        try second.join();

        try std.testing.expectEqual(@as(?anyerror, error.Canceled), first_out.err);
        try std.testing.expect(second_took_item);
    }
}
