// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A signal-triggered synchronization primitive for async tasks.
//!
//! Notify is a stateless synchronization primitive that allows tasks to wait for
//! transient signals. Unlike ResetEvent, Notify does not maintain persistent state -
//! signals are consumed immediately when they wake waiting tasks.
//!
//! The primitive provides two wake modes:
//! - `signal()`: Wakes one waiting task (FIFO order)
//! - `broadcast()`: Wakes all waiting tasks
//!
//! If no tasks are waiting when a signal or broadcast is sent, the notification
//! is lost (no-op). This makes Notify suitable for event notification scenarios
//! where the event is transient and not a persistent condition.
//!
//! This implementation provides cooperative synchronization for the zio runtime.
//! Waiting tasks will suspend and yield to the executor, allowing other work
//! to proceed.
//!
//! ## Example
//!
//! ```zig
//! fn worker(rt: *Runtime, notify: *zio.Notify, id: u32) !void {
//!     // Wait for notification
//!     try notify.wait(rt);
//!     std.debug.print("Worker {} notified\n", .{id});
//! }
//!
//! fn notifier(rt: *Runtime, notify: *zio.Notify) !void {
//!     // Do some work
//!     // ...
//!
//!     // Wake one waiting worker
//!     notify.signal();
//!
//!     // Or wake all waiting workers
//!     // notify.broadcast();
//! }
//!
//! var notify = zio.Notify.init;
//!
//! var task1 = try runtime.spawn(worker, .{runtime, &notify, 1 });
//! var task2 = try runtime.spawn(worker, .{runtime, &notify, 2 });
//! var task3 = try runtime.spawn(notifier, .{runtime, &notify });
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Duration = @import("../time.zig").Duration;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const Waiter = @import("../common.zig").Waiter;

wait_queue: WaitQueue(WaitNode) = .empty,

const Notify = @This();

// Use WaitQueue sentinel states:
// - sentinel0 = no waiters (empty)
// - pointer = has waiters
// No sentinel1 needed since there's no persistent "signaled" state
const State = WaitQueue(WaitNode).State;
const empty = State.sentinel0;

/// Creates a new Notify primitive.
pub const init: Notify = .{};

/// Wakes one waiting task in FIFO order.
///
/// If at least one task is waiting in `wait()` or `timedWait()`, the first task
/// (FIFO order) is removed from the wait queue and resumed. If no tasks are waiting,
/// this is a no-op and the signal is lost.
///
/// This is useful for work-stealing scenarios or when you want to wake tasks one
/// at a time as resources become available.
pub fn signal(self: *Notify) void {
    // Pop one waiter if available
    if (self.wait_queue.pop()) |wait_node| {
        wait_node.wake();
    }
}

/// Wakes all waiting tasks.
///
/// Unblocks all tasks currently waiting in `wait()` or `timedWait()`. If no tasks
/// are waiting, this is a no-op and the broadcast is lost.
///
/// This is useful for notifying multiple tasks about an event that affects them all.
pub fn broadcast(self: *Notify) void {
    // Pop and wake all waiters
    while (self.wait_queue.pop()) |wait_node| {
        wait_node.wake();
    }
}

/// Waits for a signal or broadcast.
///
/// Suspends the current task until `signal()` or `broadcast()` is called.
/// Unlike ResetEvent, there is no fast path - the task always suspends and waits
/// for an explicit notification.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *Notify, runtime: *Runtime) Cancelable!void {
    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init(runtime);

    // Push to wait queue
    self.wait_queue.push(&waiter.wait_node);

    // Wait for signal, handling spurious wakeups internally
    waiter.wait(1, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.wait_node);
        if (!was_in_queue) {
            // We were already removed by signal() - wait for signal to complete
            waiter.wait(1, .no_cancel);
            // Since we're being cancelled and won't process the signal,
            // wake another waiter to receive the signal instead.
            if (self.wait_queue.pop()) |next_waiter| {
                next_waiter.wake();
            }
        }
        return err;
    };

    // Acquire fence: synchronize-with signal()/broadcast()'s wake
    // Ensures visibility of all writes made before signal() was called
    _ = self.wait_queue.getState();
}

/// Waits for a signal or broadcast with a timeout.
///
/// Like `wait()`, but returns `error.Timeout` if no signal is received within the
/// specified duration. The timeout is specified in nanoseconds.
///
/// Returns `error.Timeout` if the timeout expires before a signal is received.
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn timedWait(self: *Notify, runtime: *Runtime, timeout: Duration) (Timeoutable || Cancelable)!void {
    // Stack-allocated waiter - separates operation wait node from task wait node
    var waiter: Waiter = .init(runtime);

    // Push to wait queue
    self.wait_queue.push(&waiter.wait_node);

    // Wait for signal or timeout, handling spurious wakeups internally
    waiter.timedWait(1, timeout, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = self.wait_queue.remove(&waiter.wait_node);
        if (!was_in_queue) {
            // Removed by signal() - wait for signal to complete before destroying waiter
            waiter.wait(1, .no_cancel);
            // Since we're being cancelled and won't process the signal,
            // wake another waiter to receive the signal instead.
            if (self.wait_queue.pop()) |next_waiter| {
                next_waiter.wake();
            }
        }
        return err;
    };

    // Determine winner: can we remove ourselves from queue?
    if (self.wait_queue.remove(&waiter.wait_node)) {
        // We were still in queue - timer won
        return error.Timeout;
    }

    // Acquire fence: synchronize-with signal()/broadcast()'s wake
    // Ensures visibility of all writes made before signal() was called
    _ = self.wait_queue.getState();
}

// Future protocol implementation for use with select()
pub const Result = void;

/// Gets the result (void) of the notification.
/// This is part of the Future protocol for select().
pub fn getResult(self: *const Notify) void {
    _ = self;
    return;
}

/// Registers a wait node to be notified when signal() or broadcast() is called.
/// This is part of the Future protocol for select().
/// Always returns true since Notify has no persistent state (never pre-completed).
pub fn asyncWait(self: *Notify, _: *Runtime, wait_node: *WaitNode) bool {
    self.wait_queue.push(wait_node);
    return true;
}

/// Cancels a pending wait operation by removing the wait node.
/// This is part of the Future protocol for select().
pub fn asyncCancelWait(self: *Notify, _: *Runtime, wait_node: *WaitNode) void {
    const was_in_queue = self.wait_queue.remove(wait_node);
    if (!was_in_queue) {
        // We were already removed by signal() which will wake us.
        // Since we're being cancelled and won't process the signal,
        // wake another waiter to receive the signal instead.
        if (self.wait_queue.pop()) |next_waiter| {
            next_waiter.wake();
        }
    }
}

test "Notify basic signal/wait" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;
    var waiter_finished = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, n: *Notify, finished: *bool) !void {
            try n.wait(rt);
            finished.* = true;
        }

        fn signaler(rt: *Runtime, n: *Notify) !void {
            try rt.yield(); // Give waiter time to start waiting
            n.signal();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_finished });
    try group.spawn(runtime, TestFn.signaler, .{ runtime, &notify });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(waiter_finished);
}

test "Notify signal with no waiters" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;

    // Signal with no waiters - should be no-op
    notify.signal();
    notify.broadcast();

    // Verify state is still empty
    try std.testing.expectEqual(empty, notify.wait_queue.getState());
}

test "Notify broadcast to multiple waiters" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, n: *Notify, counter: *u32) !void {
            try n.wait(rt);
            counter.* += 1;
        }

        fn broadcaster(rt: *Runtime, n: *Notify) !void {
            // Give waiters time to start waiting
            try rt.yield();
            try rt.yield();
            try rt.yield();
            n.broadcast();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.broadcaster, .{ runtime, &notify });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(3, waiter_count);
}

test "Notify multiple signals to multiple waiters" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, n: *Notify, counter: *u32) !void {
            try n.wait(rt);
            counter.* += 1;
        }

        fn signaler(rt: *Runtime, n: *Notify) !void {
            // Give waiters time to start waiting
            try rt.yield();
            try rt.yield();
            try rt.yield();
            // Signal three times to wake all three waiters one by one (FIFO)
            n.signal();
            n.signal();
            n.signal();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &waiter_count });
    try group.spawn(runtime, TestFn.signaler, .{ runtime, &notify });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(3, waiter_count);
}

test "Notify timedWait timeout" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, n: *Notify, timeout_flag: *bool) !void {
            // Should timeout after 10ms
            n.timedWait(rt, .fromMilliseconds(10)) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    var handle = try runtime.spawn(TestFn.waiter, .{ runtime, &notify, &timed_out });
    try handle.join(runtime);

    try std.testing.expect(timed_out);
}

test "Notify timedWait success" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var notify = Notify.init;
    var wait_succeeded = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, n: *Notify, success_flag: *bool) !void {
            // Should be signaled before timeout
            try n.timedWait(rt, .fromSeconds(1));
            success_flag.* = true;
        }

        fn signaler(rt: *Runtime, n: *Notify) !void {
            try rt.yield(); // Give waiter time to start waiting
            n.signal();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.waiter, .{ runtime, &notify, &wait_succeeded });
    try group.spawn(runtime, TestFn.signaler, .{ runtime, &notify });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(wait_succeeded);
}

test "Notify size and alignment" {
    // Should be the same size as WaitQueue (one pointer for head, one for tail)
    try std.testing.expectEqual(@sizeOf(WaitQueue(WaitNode)), @sizeOf(Notify));
    _ = @alignOf(Notify);
}

test "Notify: select" {
    const select = @import("../select.zig").select;

    const TestContext = struct {
        fn signalerTask(rt: *Runtime, notify: *Notify) !void {
            try rt.sleep(.fromMilliseconds(5));
            notify.signal();
        }

        fn asyncTask(rt: *Runtime) !void {
            var notify = Notify.init;

            var task = try rt.spawn(signalerTask, .{ rt, &notify });
            defer task.cancel(rt);

            const result = try select(rt, .{ .notify = &notify, .task = &task });
            try std.testing.expectEqual(.notify, result);
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try handle.join(runtime);
}
