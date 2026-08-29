// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A manual-reset synchronization event for async tasks.
//!
//! Event is a boolean flag that tasks can wait on. It can be in one of two
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
//! `waitTimeout()`.
//!
//! ## Example
//!
//! ```zig
//! fn worker(event: *zio.Event, id: u32) !void {
//!     // Wait for event to be signaled
//!     try event.wait();
//!     std.debug.print("Worker {} proceeding\n", .{id});
//! }
//!
//! fn coordinator(rt: *Runtime, event: *zio.Event) !void {
//!     // Do some initialization work
//!     // ...
//!
//!     // Signal all waiting workers
//!     event.set();
//! }
//!
//! var event = zio.Event.init;
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
const common = @import("../common.zig");
const Cancelable = common.Cancelable;
const Timeoutable = common.Timeoutable;
const Timeout = @import("../time.zig").Timeout;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const Waiter = @import("../common.zig").Waiter;

/// Wait queue with flag indicating whether event is set.
wait_queue: WaitQueue(WaitNode) = .empty,

const Event = @This();

/// Creates a new Event in the unset state.
pub const init: Event = .{};

/// Returns whether the event is currently set.
///
/// Returns `true` if `set()` has been called and `reset()` has not been called since.
/// Returns `false` otherwise.
pub fn isSet(self: *const Event) bool {
    return self.wait_queue.isFlagSet();
}

/// Sets the event and wakes all waiting tasks.
///
/// Marks the event as set and unblocks all tasks waiting in `wait()` or `waitTimeout()`.
/// The event remains set until `reset()` is called. Multiple calls to `set()` while
/// already set have no effect.
pub fn set(self: *Event) void {
    // Pop and wake all waiters while setting the flag.
    //
    // UAF safety: `self` may live on a coroutine stack belonging to a waiting task.
    // Signaling the last waiter can resume that task on another executor, which may
    // return and free its stack before we touch `self` again. Break out of the loop
    // as soon as we've popped the last waiter so we never touch `self` afterwards.
    while (self.wait_queue.popAndSetFlag()) |result| {
        Waiter.fromNode(result.node).signal();
        if (result.is_last) break;
    }
}

/// Resets the event to the unset state.
///
/// After calling `reset()`, the event is back in the unset state and tasks can wait
/// on it again. It is undefined behavior to call `reset()` while tasks are waiting
/// in `wait()` or `waitTimeout()`.
pub fn reset(self: *Event) void {
    std.debug.assert(!self.wait_queue.hasWaiters());
    self.wait_queue.clearFlag();
}

/// Waits for the event to be set.
///
/// Suspends the current task until the event is set via `set()`. If the event is
/// already set when called, returns immediately without suspending.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *Event) Cancelable!void {
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
pub fn waitTimeout(self: *Event, timeout: Timeout) (Timeoutable || Cancelable)!void {
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
    waiter.timedWait(1, timeout, .allow_cancel) catch |err| switch (err) {
        // The timer fired, but set() may have claimed this waiter just behind
        // it: whoever can still remove the node decides.
        error.Timeout => {
            if (self.wait_queue.remove(&waiter.node)) return error.Timeout;
            // Claimed by set() - take the signal instead of the timeout, and
            // wait for it to land before destroying the waiter.
            waiter.wait(1, .no_cancel);
        },
        error.Canceled => {
            // On cancellation, try to remove from queue
            const was_in_queue = self.wait_queue.remove(&waiter.node);
            if (!was_in_queue) {
                // Removed by set() - wait for signal to complete before destroying waiter
                waiter.wait(1, .no_cancel);
            }
            return err;
        },
    };

    // Acquire fence: synchronize-with set()'s .release in setFlag
    // Ensures visibility of all writes made before set() was called
    _ = self.wait_queue.isFlagSet();
}

/// Alias for `waitTimeout`. Deprecated, will be removed in a future release.
pub const timedWait = waitTimeout;

// Future protocol implementation for use with select()
pub const Result = void;

/// Returns true if the event is set (has a result).
/// This is part of the Future protocol for select().
pub fn hasResult(self: *const Event) bool {
    return self.isSet();
}

/// Gets the result (void) of the event.
/// This is part of the Future protocol for select().
pub fn getResult(self: *const Event) void {
    _ = self;
    return;
}

/// Registers a waiter to be notified when the event is set, or claims the
/// select if it already is.
/// This is part of the Future protocol for select().
pub fn asyncWait(self: *Event, waiter: *Waiter) common.AsyncWaitState {
    return common.waitOnFlagQueue(&self.wait_queue, waiter);
}

/// Cancels a pending wait operation by removing the waiter.
/// This is part of the Future protocol for select().
/// Returns true if removed, false if already removed by completion (wake in-flight).
pub fn asyncCancelWait(self: *Event, waiter: *Waiter) bool {
    return self.wait_queue.remove(&waiter.node);
}

test "Event basic set/reset/isSet" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = Event.init;

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

test "Event wait/set signaling" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = Event.init;
    var waiter_finished = false;
    var waiter_ready = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn waiter(event: *Event, finished: *bool, ready_flag: *std.atomic.Value(bool)) !void {
            ready_flag.store(true, .release);
            try event.wait();
            finished.* = true;
        }

        fn setter(event: *Event, ready_flag: *std.atomic.Value(bool)) !void {
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

test "Event waitTimeout timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var reset_event = Event.init;

    // Should timeout after 10ms
    try std.testing.expectError(error.Timeout, reset_event.waitTimeout(.fromMilliseconds(10)));
    try std.testing.expect(!reset_event.isSet());
}

test "Event multiple waiters broadcast" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var reset_event = Event.init;
    var waiter_count = std.atomic.Value(u32).init(0);
    var waiters_ready = std.atomic.Value(u32).init(0);

    const TestFn = struct {
        fn waiter(event: *Event, counter: *std.atomic.Value(u32), ready_flag: *std.atomic.Value(u32)) !void {
            _ = ready_flag.fetchAdd(1, .release);
            try event.wait();
            _ = counter.fetchAdd(1, .monotonic);
        }

        fn setter(event: *Event, ready_flag: *std.atomic.Value(u32)) !void {
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

test "Event wait on already set event" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var reset_event = Event.init;

    // Set event before waiting
    reset_event.set();

    try reset_event.wait(); // Should return immediately
    try std.testing.expect(reset_event.isSet());
}

test "Event size" {
    // ConcurrentQueue with mutex will be larger than a single pointer
    // but still reasonably sized
    _ = @sizeOf(Event);
}

test "Event: cancel waiting task" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = Event.init;
    var started = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn waiter(event: *Event, started_flag: *std.atomic.Value(bool)) !void {
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

test "Event: select" {
    const select = @import("../select.zig").select;

    const TestContext = struct {
        fn setterTask(rt: *Runtime, event: *Event) !void {
            try rt.sleep(.fromMilliseconds(5));
            event.set();
            try rt.sleep(.fromMilliseconds(5));
        }

        fn asyncTask(rt: *Runtime) !void {
            var reset_event = Event.init;

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

test "Event: foreign thread signals async task" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = Event.init;
    var task_ready = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn taskWait(event: *Event, ready: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) !void {
            ready.store(true, .release);
            try event.wait();
            done.store(true, .release);
        }

        fn threadSet(event: *Event, ready: *std.atomic.Value(bool)) void {
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

test "Event: async task signals foreign thread" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var reset_event = Event.init;
    var thread_ready = std.atomic.Value(bool).init(false);
    var thread_done = std.atomic.Value(bool).init(false);

    const TestFn = struct {
        fn threadWait(event: *Event, ready: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            ready.store(true, .release);
            event.wait() catch unreachable;
            done.store(true, .release);
        }

        fn taskSet(event: *Event, ready: *std.atomic.Value(bool)) !void {
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

test "Event: a set that races the commit fence is not lost" {
    // The select's sweep holds the commit fence for another arm when set()
    // pops this arm and signals it. That signal cannot claim the winner word,
    // and a re-poll afterwards cannot recover it either, because reset() has
    // since cleared the flag. The bounced arm must be recorded instead.
    const NO_WINNER = common.NO_WINNER;

    var event = Event.init;

    var parent = Waiter.init();
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var gen: std.atomic.Value(u32) = .init(0);
    var pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiter = Waiter.initSelect(&parent, &winner, &gen, &pending, 3);

    // .requeued on a first call: a flag-queue source cannot tell a first
    // registration from one whose predecessor was popped and signaled, so the
    // select resolves it (see the protocol comment in select.zig).
    try std.testing.expectEqual(.requeued, event.asyncWait(&waiter));

    // Owner's sweep is committing a different arm.
    winner.store(common.COMMITTING, .seq_cst);
    event.set();

    // set() popped every waiter, so reset() is legal here.
    winner.store(NO_WINNER, .seq_cst);
    event.reset();

    // Re-polling cannot see it: the flag is clear again. (.requeued, not
    // .queued: the source knows its earlier registration was signaled, which
    // is what keeps the settle accounting balanced.)
    try std.testing.expectEqual(.requeued, event.asyncWait(&waiter));

    // The arm's identity survived, so the select still reports it.
    try std.testing.expectEqual(3, pending.load(.acquire));
    try std.testing.expect(Waiter.promotePending(&winner, &pending));
    try std.testing.expectEqual(3, winner.load(.acquire));
}
