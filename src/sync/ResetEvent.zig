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
const os = @import("../os/root.zig");
const yield = @import("../runtime.zig").yield;
const Group = @import("../group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Timeout = @import("../time.zig").Timeout;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const Waiter = @import("../common.zig").Waiter;

/// Wait queue with flag indicating whether event is set.
wait_queue: WaitQueue(WaitNode) = .empty,

const ResetEvent = @This();

/// Creates a new ResetEvent in the unset state.
pub const init: ResetEvent = .{};

/// Returns whether the event is currently set.
///
/// Returns `true` if `set()` has been called and `reset()` has not been called since.
/// Returns `false` otherwise.
pub fn isSet(self: *const ResetEvent) bool {
    return self.wait_queue.isFlagSet();
}

/// Sets the event and wakes all waiting tasks.
///
/// Marks the event as set and unblocks all tasks waiting in `wait()` or `timedWait()`.
/// The event remains set until `reset()` is called. Multiple calls to `set()` while
/// already set have no effect.
pub fn set(self: *ResetEvent) void {
    // Pop and wake all waiters while setting the flag
    while (self.wait_queue.popAndSetFlag()) |node| {
        Waiter.fromNode(node).signal();
    }
}

/// Resets the event to the unset state.
///
/// After calling `reset()`, the event is back in the unset state and tasks can wait
/// on it again. It is undefined behavior to call `reset()` while tasks are waiting
/// in `wait()` or `timedWait()`.
pub fn reset(self: *ResetEvent) void {
    std.debug.assert(!self.wait_queue.hasWaiters());
    self.wait_queue.clearFlag();
}

/// Waits for the event to be set.
///
/// Suspends the current task until the event is set via `set()`. If the event is
/// already set when called, returns immediately without suspending.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *ResetEvent) Cancelable!void {
    // Fast path: already set
    if (self.wait_queue.isFlagSet()) {
        return;
    }

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Try to push to queue - only succeeds if event is not set (flag not set)
    if (!self.wait_queue.pushUnlessFlag(&waiter.node)) {
        // Event was set, return immediately
        return;
    }

    // Wait for signal, handling spurious wakeups internally
    waiter.wait(1, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.node);
        if (!was_in_queue) {
            // Removed by set() - wait for signal to complete before destroying waiter
            waiter.wait(1, .no_cancel);
        }
        return err;
    };

    // Acquire fence: synchronize-with set()'s .release in setFlag
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.isFlagSet();
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
    // Fast path: already set
    if (self.wait_queue.isFlagSet()) {
        return;
    }

    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init();

    // Try to push to queue - only succeeds if event is not set (flag not set)
    if (!self.wait_queue.pushUnlessFlag(&waiter.node)) {
        // Event was set, return immediately
        return;
    }

    // Wait for signal or timeout, handling spurious wakeups internally
    waiter.timedWait(1, timeout, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.node);
        if (!was_in_queue) {
            // Removed by set() - wait for signal to complete before destroying waiter
            waiter.wait(1, .no_cancel);
        }
        return err;
    };

    // Determine winner: can we remove ourselves from queue?
    if (self.wait_queue.remove(&waiter.node)) {
        // We were still in queue - timer won
        return error.Timeout;
    }

    // Acquire fence: synchronize-with set()'s .release in setFlag
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.isFlagSet();
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

/// Registers a waiter to be notified when the event is set.
/// This is part of the Future protocol for select().
/// Returns false if the event is already set (no wait needed), true if added to queue.
pub fn asyncWait(self: *ResetEvent, waiter: *Waiter) bool {
    // Try to push to queue - only succeeds if event is not set (flag not set)
    return self.wait_queue.pushUnlessFlag(&waiter.node);
}

/// Cancels a pending wait operation by removing the waiter.
/// This is part of the Future protocol for select().
/// Returns true if removed, false if already removed by completion (wake in-flight).
pub fn asyncCancelWait(self: *ResetEvent, waiter: *Waiter) bool {
    return self.wait_queue.remove(&waiter.node);
}

test "ResetEvent basic set/reset/isSet" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
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
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_finished = false;
    var waiter_ready = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn waiter(event: *ResetEvent, finished: *bool, ready_flag: *std.atomic.Value(bool)) !void {
            ready_flag.store(true, .release);
            try event.wait();
            finished.* = true;
        }

        fn setter(event: *ResetEvent, ready_flag: *std.atomic.Value(bool)) !void {
            // Wait for waiter to be ready
            while (!ready_flag.load(.acquire)) {
                try yield();
            }
            event.set();
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.waiter, .{ &reset_event, &waiter_finished, &waiter_ready });
    try group.spawn(TestFn.setter, .{ &reset_event, &waiter_ready });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(waiter_finished);
    try std.testing.expect(reset_event.isSet());
}

test "ResetEvent timedWait timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var reset_event = ResetEvent.init;

    // Should timeout after 10ms
    try std.testing.expectError(error.Timeout, reset_event.timedWait(.fromMilliseconds(10)));
    try std.testing.expect(!reset_event.isSet());
}

test "ResetEvent multiple waiters broadcast" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var waiter_count = std.atomic.Value(u32).init(0);
    var waiters_ready = std.atomic.Value(u32).init(0);

    const TestFn = struct {
        fn waiter(event: *ResetEvent, counter: *std.atomic.Value(u32), ready_flag: *std.atomic.Value(u32)) !void {
            _ = ready_flag.fetchAdd(1, .release);
            try event.wait();
            _ = counter.fetchAdd(1, .monotonic);
        }

        fn setter(event: *ResetEvent, ready_flag: *std.atomic.Value(u32)) !void {
            // Wait for all waiters to be ready
            while (ready_flag.load(.acquire) < 3) {
                try yield();
            }
            event.set();
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.waiter, .{ &reset_event, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.waiter, .{ &reset_event, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.waiter, .{ &reset_event, &waiter_count, &waiters_ready });
    try group.spawn(TestFn.setter, .{ &reset_event, &waiters_ready });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(reset_event.isSet());
    try std.testing.expectEqual(3, waiter_count.load(.monotonic));
}

test "ResetEvent wait on already set event" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
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
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
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
    defer waiter_task.cancel();

    // Wait until waiter has actually started and is blocked
    while (!started.load(.acquire)) {
        try yield();
    }
    // One more yield to ensure waiter is actually blocked in wait()
    try yield();

    waiter_task.cancel();

    try std.testing.expectError(error.Canceled, waiter_task.join());
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
            defer task.cancel();

            const result = try select(.{ .event = &reset_event, .task = &task });
            try std.testing.expectEqual(.event, result);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try handle.join();
}

test "ResetEvent: foreign thread signals async task" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var task_ready = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn taskWait(event: *ResetEvent, ready: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) !void {
            ready.store(true, .release);
            try event.wait();
            done.store(true, .release);
        }

        fn threadSet(event: *ResetEvent, ready: *std.atomic.Value(bool)) void {
            // Wait for task to be ready
            while (!ready.load(.acquire)) {
                os.thread.yield();
            }
            event.set();
        }
    };

    var handle = try runtime.spawn(TestFn.taskWait, .{ &reset_event, &task_ready, &finished });
    defer handle.cancel();

    const thread = try std.Thread.spawn(.{}, TestFn.threadSet, .{ &reset_event, &task_ready });

    try handle.join();
    thread.join();

    try std.testing.expect(finished.load(.acquire));
    try std.testing.expect(reset_event.isSet());
}

test "ResetEvent: async task signals foreign thread" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = ResetEvent.init;
    var thread_ready = std.atomic.Value(bool).init(false);
    var thread_done = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn threadWait(event: *ResetEvent, ready: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            ready.store(true, .release);
            event.wait() catch unreachable;
            done.store(true, .release);
        }

        fn taskSet(event: *ResetEvent, ready: *std.atomic.Value(bool)) !void {
            // Wait for thread to be ready
            while (!ready.load(.acquire)) {
                try yield();
            }
            event.set();
        }
    };

    const thread = try std.Thread.spawn(.{}, TestFn.threadWait, .{ &reset_event, &thread_ready, &thread_done });

    var handle = try runtime.spawn(TestFn.taskSet, .{ &reset_event, &thread_ready });
    defer handle.cancel();

    try handle.join();

    thread.join();

    try std.testing.expect(thread_done.load(.acquire));
    try std.testing.expect(reset_event.isSet());
}
