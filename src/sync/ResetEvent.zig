//! A manual-reset synchronization event for async tasks.
//!
//! ResetEvent is a boolean flag that tasks can wait on. It can be in one of two
//! states: set or unset. Tasks can wait for the event to become set, and once set,
//! all waiting tasks are released. The event remains set until explicitly reset.
//!
//! This is similar to manual-reset events in other threading libraries. Unlike
//! auto-reset events, setting the event wakes all waiting tasks and the event
//! stays signaled until `reset()` is called.
//!
//! This implementation provides cooperative synchronization for the zio runtime.
//! Waiting tasks will suspend and yield to the executor, allowing other work
//! to proceed.
//!
//! The event provides memory ordering guarantees: memory accesses before `set()`
//! happen-before any task observing the set state via `isSet()`, `wait()`, or
//! `timedWait()`.
//!
//! ## Example
//!
//! ```zig
//! fn worker(rt: *Runtime, event: *zio.ResetEvent, id: u32) !void {
//!     // Wait for event to be signaled
//!     try event.wait(rt);
//!     std.debug.print("Worker {} proceeding\n", .{id});
//! }
//!
//! fn coordinator(rt: *Runtime, event: *zio.ResetEvent) !void {
//!     // Do some initialization work
//!     // ...
//!
//!     // Signal all waiting workers
//!     event.set(rt);
//! }
//!
//! var event = zio.ResetEvent.init;
//!
//! var task1 = try runtime.spawn(worker, .{ &runtime, &event, 1 }, .{});
//! var task2 = try runtime.spawn(worker, .{ &runtime, &event, 2 }, .{});
//! var task3 = try runtime.spawn(coordinator, .{ &runtime, &event }, .{});
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../runtime.zig").Cancelable;
const coroutines = @import("../coroutines.zig");
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const ConcurrentAwaitableList = @import("../core/ConcurrentAwaitableList.zig");

wait_queue: ConcurrentAwaitableList = ConcurrentAwaitableList.init(),

const ResetEvent = @This();

// Use ConcurrentAwaitableList sentinel states to encode event state:
// - sentinel0 = unset (no waiters, event not signaled)
// - sentinel1 = set (no waiters, event signaled)
// - pointer = waiting (has waiters, event not signaled)
const State = ConcurrentAwaitableList.State;
const unset = State.sentinel0;
const is_set = State.sentinel1;

/// Creates a new ResetEvent in the unset state.
pub const init: ResetEvent = .{};

/// Returns whether the event is currently set.
///
/// Returns `true` if `set()` has been called and `reset()` has not been called since.
/// Returns `false` otherwise.
pub fn isSet(self: *const ResetEvent) bool {
    return self.wait_queue.getState() == is_set;
}

/// Sets the event and wakes all waiting tasks.
///
/// Marks the event as set and unblocks all tasks waiting in `wait()` or `timedWait()`.
/// The event remains set until `reset()` is called. Multiple calls to `set()` while
/// already set have no effect.
pub fn set(self: *ResetEvent, runtime: *Runtime) void {
    // Extract all waiters and transition to is_set
    // Use runtime's executor for acquiring the mutation lock
    var waiters = self.wait_queue.popAll(&runtime.executor, is_set);

    // Wake all waiters
    while (waiters.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        const task_executor = Executor.fromCoroutine(&task.coro);
        task_executor.markReady(&task.coro);
    }
}

/// Resets the event to the unset state.
///
/// After calling `reset()`, the event is back in the unset state and tasks can wait
/// on it again. It is undefined behavior to call `reset()` while tasks are waiting
/// in `wait()` or `timedWait()`.
pub fn reset(self: *ResetEvent) void {
    // Transition from is_set to unset
    const success = self.wait_queue.tryTransition(is_set, unset);
    std.debug.assert(success); // Must be in is_set state when reset() is called
}

/// Waits for the event to be set.
///
/// Suspends the current task until the event is set via `set()`. If the event is
/// already set when called, returns immediately without suspending.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *ResetEvent, runtime: *Runtime) Cancelable!void {
    const state = self.wait_queue.getState();

    // Fast path: already set
    if (state == is_set) {
        return;
    }

    // Add to wait queue and suspend
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);
    self.wait_queue.push(executor, &task.awaitable);

    // Suspend until woken by set()
    executor.yield(.waiting, .allow_cancel) catch |err| {
        // On cancellation, remove from queue
        _ = self.wait_queue.remove(executor, &task.awaitable);
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();

    // Debug: verify we were removed from the list by set()
    if (builtin.mode == .Debug) {
        std.debug.assert(!task.awaitable.in_list);
    }
}

/// Waits for the event to be set with a timeout.
///
/// Like `wait()`, but returns `error.Timeout` if the event is not set within the
/// specified duration. The timeout is specified in nanoseconds.
///
/// If the event is already set when called, returns immediately without suspending.
///
/// Returns `error.Timeout` if the timeout expires before the event is set.
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn timedWait(self: *ResetEvent, runtime: *Runtime, timeout_ns: u64) error{ Timeout, Canceled }!void {
    const state = self.wait_queue.getState();

    // Fast path: already set
    if (state == is_set) {
        return;
    }

    // Add to wait queue and wait with timeout
    const current = runtime.executor.current_coroutine orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);

    self.wait_queue.push(executor, &task.awaitable);

    const TimeoutContext = struct {
        wait_queue: *ConcurrentAwaitableList,
        awaitable: *Awaitable,
        executor: *Executor,
    };

    var timeout_ctx = TimeoutContext{
        .wait_queue = &self.wait_queue,
        .awaitable = &task.awaitable,
        .executor = executor,
    };

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
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();

    // Debug: verify we were removed from the list by set() or timeout
    if (builtin.mode == .Debug) {
        std.debug.assert(!task.awaitable.in_list);
    }
}

test "ResetEvent basic set/reset/isSet" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;

    // Initially unset
    try testing.expect(!reset_event.isSet());

    // Set the event
    reset_event.set(&runtime);
    try testing.expect(reset_event.isSet());

    // Setting again should be no-op
    reset_event.set(&runtime);
    try testing.expect(reset_event.isSet());

    // Reset the event
    reset_event.reset();
    try testing.expect(!reset_event.isSet());
}

test "ResetEvent wait/set signaling" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_finished = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, finished: *bool) !void {
            try event.wait(rt);
            finished.* = true;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) !void {
            try rt.yield(); // Give waiter time to start waiting
            event.set(rt);
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ &runtime, &reset_event, &waiter_finished }, .{});
    defer waiter_task.deinit();
    var setter_task = try runtime.spawn(TestFn.setter, .{ &runtime, &reset_event }, .{});
    defer setter_task.deinit();

    try runtime.run();

    try testing.expect(waiter_finished);
    try testing.expect(reset_event.isSet());
}

test "ResetEvent timedWait timeout" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, timeout_flag: *bool) !void {
            // Should timeout after 10ms
            event.timedWait(rt, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &reset_event, &timed_out }, .{});

    try testing.expect(timed_out);
    try testing.expect(!reset_event.isSet());
}

test "ResetEvent multiple waiters broadcast" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, counter: *u32) !void {
            try event.wait(rt);
            counter.* += 1;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) !void {
            // Give waiters time to start waiting
            try rt.yield();
            try rt.yield();
            try rt.yield();
            event.set(rt);
        }
    };

    var waiter1 = try runtime.spawn(TestFn.waiter, .{ &runtime, &reset_event, &waiter_count }, .{});
    defer waiter1.deinit();
    var waiter2 = try runtime.spawn(TestFn.waiter, .{ &runtime, &reset_event, &waiter_count }, .{});
    defer waiter2.deinit();
    var waiter3 = try runtime.spawn(TestFn.waiter, .{ &runtime, &reset_event, &waiter_count }, .{});
    defer waiter3.deinit();
    var setter_task = try runtime.spawn(TestFn.setter, .{ &runtime, &reset_event }, .{});
    defer setter_task.deinit();

    try runtime.run();

    try testing.expect(reset_event.isSet());
    try testing.expectEqual(@as(u32, 3), waiter_count);
}

test "ResetEvent wait on already set event" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var wait_completed = false;

    // Set event before waiting
    reset_event.set(&runtime);

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, completed: *bool) !void {
            try event.wait(rt); // Should return immediately
            completed.* = true;
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &reset_event, &wait_completed }, .{});

    try testing.expect(wait_completed);
    try testing.expect(reset_event.isSet());
}
