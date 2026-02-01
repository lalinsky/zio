// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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
//! fn worker(event: *zio.ResetEvent, id: u32) !void {
//!     // Wait for event to be signaled
//!     try event.wait();
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
//! var task1 = try runtime.spawn(worker, .{runtime, &event, 1 });
//! var task2 = try runtime.spawn(worker, .{runtime, &event, 2 });
//! var task3 = try runtime.spawn(coordinator, .{runtime, &event });
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Duration = @import("../time.zig").Duration;
const Timeout = @import("../time.zig").Timeout;
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const Waiter = @import("../common.zig").Waiter;

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
    const prev = self.wait_queue.tryTransitionEx(is_set, unset);
    std.debug.assert(prev == is_set or prev == unset);
}

/// Waits for the event to be set.
///
/// Suspends the current task until the event is set via `set()`. If the event is
/// already set when called, returns immediately without suspending.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *ResetEvent) Cancelable!void {
    const state = self.wait_queue.getState();

    // Fast path: already set
    if (state == is_set) {
        return;
    }

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Try to push to queue - only succeeds if event is not set
    // Returns false if event is set, preventing invalid transition: is_set -> has_waiters
    if (!self.wait_queue.pushUnless(is_set, &waiter.wait_node)) {
        // Event was set, return immediately
        return;
    }

    // Wait for signal, handling spurious wakeups internally
    waiter.wait(1, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.wait_node);
        if (!was_in_queue) {
            // Removed by set() - wait for signal to complete before destroying waiter
            waiter.wait(1, .no_cancel);
        }
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();
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
pub fn timedWait(self: *ResetEvent, timeout: Timeout) (Timeoutable || Cancelable)!void {
    const state = self.wait_queue.getState();

    // Fast path: already set
    if (state == is_set) {
        return;
    }

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Try to push to queue - only succeeds if event is not set
    // Returns false if event is set, preventing invalid transition: is_set -> has_waiters
    if (!self.wait_queue.pushUnless(is_set, &waiter.wait_node)) {
        // Event was set, return immediately
        return;
    }

    // Wait for signal or timeout, handling spurious wakeups internally
    waiter.timedWait(1, timeout, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.wait_node);
        if (!was_in_queue) {
            // Removed by set() - wait for signal to complete before destroying waiter
            waiter.wait(1, .no_cancel);
        }
        return err;
    };

    // Determine winner: can we remove ourselves from queue?
    if (self.wait_queue.remove(&waiter.wait_node)) {
        // We were still in queue - timer won
        return error.Timeout;
    }

    // Acquire fence: synchronize-with set()'s .release in popAll
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.getState();
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
/// Returns true if removed, false if already removed by completion (wake in-flight).
pub fn asyncCancelWait(self: *ResetEvent, wait_node: *WaitNode) bool {
    return self.wait_queue.remove(wait_node);
}

test "ResetEvent basic set/reset/isSet" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;

    // Initially unset
    try std.testing.expect(!reset_event.isSet());

    // Set the event
    reset_event.set();
    try std.testing.expect(reset_event.isSet());

    // Setting again should be no-op
    reset_event.set();
    try std.testing.expect(reset_event.isSet());

    // Reset the event
    reset_event.reset();
    try std.testing.expect(!reset_event.isSet());

    // Resetting again should be no-op
    reset_event.reset();
    try std.testing.expect(!reset_event.isSet());
}

test "ResetEvent wait/set signaling" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_finished = false;

    const TestFn = struct {
        fn waiter(event: *ResetEvent, finished: *bool) !void {
            try event.wait();
            finished.* = true;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) !void {
            try rt.yield(); // Give waiter time to start waiting
            event.set();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ &reset_event, &waiter_finished });
    try group.spawn(runtime, TestFn.setter, .{ runtime, &reset_event });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(waiter_finished);
    try std.testing.expect(reset_event.isSet());
}

test "ResetEvent timedWait timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var reset_event = ResetEvent.init;

    // Should timeout after 10ms
    try std.testing.expectError(error.Timeout, reset_event.timedWait(.fromMilliseconds(10)));
    try std.testing.expect(!reset_event.isSet());
}

test "ResetEvent multiple waiters broadcast" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(event: *ResetEvent, counter: *u32) !void {
            try event.wait();
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ &reset_event, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ &reset_event, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ &reset_event, &waiter_count });
    try group.spawn(runtime, TestFn.setter, .{ runtime, &reset_event });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(reset_event.isSet());
    try std.testing.expectEqual(3, waiter_count);
}

test "ResetEvent wait on already set event" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var reset_event = ResetEvent.init;

    // Set event before waiting
    reset_event.set();

    try reset_event.wait(); // Should return immediately
    try std.testing.expect(reset_event.isSet());
}

test "ResetEvent size" {
    // ConcurrentQueue with mutex will be larger than a single pointer
    // but still reasonably sized
    _ = @sizeOf(ResetEvent);
}

test "ResetEvent: cancel waiting task" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var started = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn waiter(event: *ResetEvent, started_flag: *std.atomic.Value(bool)) !void {
            // Signal that we're about to wait
            started_flag.store(true, .release);
            try event.wait();
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ &reset_event, &started });
    defer waiter_task.cancel(runtime);

    // Wait until waiter has actually started and is blocked
    while (!started.load(.acquire)) {
        try runtime.yield();
    }
    // One more yield to ensure waiter is actually blocked in wait()
    try runtime.yield();

    waiter_task.cancel(runtime);

    try std.testing.expectError(error.Canceled, waiter_task.join(runtime));
}

test "ResetEvent: select" {
    const select = @import("../select.zig").select;

    const TestContext = struct {
        fn setterTask(rt: *Runtime, event: *ResetEvent) !void {
            try rt.sleep(.fromMilliseconds(5));
            event.set();
            try rt.sleep(.fromMilliseconds(5));
        }

        fn asyncTask(rt: *Runtime) !void {
            var reset_event = ResetEvent.init;

            var task = try rt.spawn(setterTask, .{ rt, &reset_event });
            defer task.cancel(rt);

            const result = try select(rt, .{ .event = &reset_event, .task = &task });
            try std.testing.expectEqual(.event, result);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try handle.join(runtime);
}
