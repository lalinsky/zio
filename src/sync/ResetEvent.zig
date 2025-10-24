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
//!     event.set();
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
const resumeTask = @import("../runtime.zig").resumeTask;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../core/WaitNode.zig");

wait_queue: WaitQueue(WaitNode) = .empty,

const ResetEvent = @This();

// Use WaitQueue sentinel states to encode event state:
// - sentinel0 = unset (no waiters, event not signaled)
// - sentinel1 = set (no waiters, event signaled)
// - pointer = waiting (has waiters, event not signaled)
const State = WaitQueue(WaitNode).State;
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
pub fn set(self: *ResetEvent) void {
    // Pop and wake all waiters, then transition to is_set
    // Loop continues until popOrTransition successfully transitions unset->is_set
    // This handles: already set (is_set->is_set fails, pop returns null),
    // has waiters (pops them all until last pop transitions to unset),
    // and cancellation races (retry loop inside popOrTransition)
    while (self.wait_queue.popOrTransition(unset, is_set)) |wait_node| {
        wait_node.wake();
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
    const task = runtime.getCurrentTask() orelse unreachable;
    const executor = task.getExecutor();

    // Transition to preparing_to_wait state before adding to queue
    task.coro.state.store(.preparing_to_wait, .release);

    // Try to push to queue - only succeeds if event is not set
    // Returns false if event is set, preventing invalid transition: is_set -> has_waiters
    if (!self.wait_queue.pushUnless(is_set, &task.awaitable.wait_node)) {
        // Event was set, return immediately
        task.coro.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting_sync)
    // If someone wakes us before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting_sync, .allow_cancel) catch |err| {
        // On cancellation, remove from queue
        _ = self.wait_queue.remove(&task.awaitable.wait_node);
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();

    // Debug: verify we were removed from the list by set()
    if (builtin.mode == .Debug) {
        std.debug.assert(!task.awaitable.wait_node.in_list);
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
    const task = runtime.getCurrentTask() orelse unreachable;
    const executor = task.getExecutor();

    // Transition to preparing_to_wait state before adding to queue
    task.coro.state.store(.preparing_to_wait, .release);

    // Try to push to queue - only succeeds if event is not set
    // Returns false if event is set, preventing invalid transition: is_set -> has_waiters
    if (!self.wait_queue.pushUnless(is_set, &task.awaitable.wait_node)) {
        // Event was set, return immediately
        task.coro.state.store(.ready, .release);
        return;
    }

    const TimeoutContext = struct {
        wait_queue: *WaitQueue(WaitNode),
        wait_node: *WaitNode,
    };

    var timeout_ctx = TimeoutContext{
        .wait_queue = &self.wait_queue,
        .wait_node = &task.awaitable.wait_node,
    };

    // Yield with atomic state transition (.preparing_to_wait -> .waiting_sync)
    // If someone wakes us before the yield, the CAS inside yield() will fail and we won't suspend
    executor.timedWaitForReadyWithCallback(
        .preparing_to_wait,
        .waiting_sync,
        timeout_ns,
        TimeoutContext,
        &timeout_ctx,
        struct {
            fn onTimeout(ctx: *TimeoutContext) bool {
                // Try to remove from wait queue - if successful, we timed out
                // If failed, we were already signaled
                return ctx.wait_queue.remove(ctx.wait_node);
            }
        }.onTimeout,
    ) catch |err| {
        // Remove from queue if canceled (timeout already handled by callback)
        if (err == error.Canceled) {
            _ = self.wait_queue.remove(&task.awaitable.wait_node);
        }
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();

    // Debug: verify we were removed from the list by set() or timeout
    if (builtin.mode == .Debug) {
        std.debug.assert(!task.awaitable.wait_node.in_list);
    }
}

// Future protocol implementation for use with select()
pub const Result = void;

/// Returns true if the event is set (has a result).
/// This is part of the Future protocol for select().
pub fn hasResult(self: *const ResetEvent) bool {
    return self.isSet();
}

/// Gets the result (void) of the event.
/// This is part of the Future protocol for select().
pub fn getResult(self: *const ResetEvent) void {
    _ = self;
    return;
}

/// Registers a wait node to be notified when the event is set.
/// This is part of the Future protocol for select().
/// Returns false if the event is already set (no wait needed), true if added to queue.
pub fn asyncWait(self: *ResetEvent, wait_node: *WaitNode) bool {
    // Try to push to queue - only succeeds if event is not set
    // Returns false if event is set, preventing invalid transition: is_set -> has_waiters
    return self.wait_queue.pushUnless(is_set, wait_node);
}

/// Cancels a pending wait operation by removing the wait node.
/// This is part of the Future protocol for select().
pub fn asyncCancelWait(self: *ResetEvent, wait_node: *WaitNode) void {
    _ = self.wait_queue.remove(wait_node);
}

test "ResetEvent basic set/reset/isSet" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;

    // Initially unset
    try testing.expect(!reset_event.isSet());

    // Set the event
    reset_event.set();
    try testing.expect(reset_event.isSet());

    // Setting again should be no-op
    reset_event.set();
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
            event.set();
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
            event.set();
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
    reset_event.set();

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

test "ResetEvent size" {
    const testing = std.testing;
    // ConcurrentQueue with mutex will be larger than a single pointer
    // but still reasonably sized
    _ = testing;
    _ = @sizeOf(ResetEvent);
}

test "ResetEvent: select" {
    const select = @import("../select.zig").select;

    const TestContext = struct {
        fn setterTask(rt: *Runtime, event: *ResetEvent) !void {
            try rt.sleep(5);
            event.set();
            try rt.sleep(5);
        }

        fn asyncTask(rt: *Runtime) !void {
            var reset_event = ResetEvent.init;

            var task = try rt.spawn(setterTask, .{ rt, &reset_event }, .{});
            defer task.deinit();

            const result = try select(rt, .{ .event = &reset_event, .task = task });
            try std.testing.expectEqual(.event, result);
        }
    };

    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
