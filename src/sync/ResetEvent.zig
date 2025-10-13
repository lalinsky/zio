const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../runtime.zig").Cancelable;
const coroutines = @import("../coroutines.zig");
const AwaitableList = @import("../runtime.zig").AwaitableList;
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;

/// ResetEvent is a thread-safe bool which can be set to true/false ("set"/"unset").
/// It can also block coroutines until the "bool" is set with cancellation via timed waits.
/// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return.
state: std.atomic.Value(State) = std.atomic.Value(State).init(.unset),
wait_queue: AwaitableList = .{},

const ResetEvent = @This();

const State = enum(u8) {
    unset = 0,
    waiting = 1,
    is_set = 2,
};

pub const init: ResetEvent = .{};

/// Returns if the ResetEvent was set().
/// Once reset() is called, this returns false until the next set().
/// The memory accesses before the set() can be said to happen before isSet() returns true.
pub fn isSet(self: *const ResetEvent) bool {
    return self.state.load(.acquire) == .is_set;
}

/// Marks the ResetEvent as "set" and unblocks any coroutines in wait() or timedWait() to observe the new state.
/// The ResetEvent stays "set" until reset() is called, making future set() calls do nothing semantically.
/// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return successfully.
pub fn set(self: *ResetEvent, runtime: *Runtime) void {
    _ = runtime;
    // Quick check if already set to avoid unnecessary atomic operations
    if (self.state.load(.monotonic) == .is_set) {
        return;
    }

    // Atomically set to is_set and get the previous state
    const prev_state = self.state.swap(.is_set, .release);

    // Only wake waiters if previous state was waiting (there were waiters)
    if (prev_state == .waiting) {
        while (self.wait_queue.pop()) |awaitable| {
            const task = AnyTask.fromAwaitable(awaitable);
            const executor = Executor.fromCoroutine(&task.coro);
            executor.markReady(&task.coro);
        }
    }
}

/// Unmarks the ResetEvent from its "set" state if set() was called previously.
/// It is undefined behavior if reset() is called while coroutines are blocked in wait() or timedWait().
/// Concurrent calls to set(), isSet() and reset() are allowed.
pub fn reset(self: *ResetEvent) void {
    self.state.store(.unset, .monotonic);
}

/// Blocks the caller's coroutine until the ResetEvent is set().
/// This is effectively a more efficient version of `while (!isSet()) {}`.
/// The memory accesses before the set() can be said to happen before wait() returns.
pub fn wait(self: *ResetEvent, runtime: *Runtime) Cancelable!void {
    _ = runtime;
    // Try to atomically register as a waiter
    var state = self.state.load(.acquire);
    if (state == .unset) {
        state = self.state.cmpxchgStrong(.unset, .waiting, .acquire, .acquire) orelse .waiting;
    }

    // If we're now in waiting state, add to queue and block
    if (state == .waiting) {
        const current = coroutines.getCurrent() orelse unreachable;
        const executor = Executor.fromCoroutine(current);
        const task = AnyTask.fromCoroutine(current);
        self.wait_queue.push(&task.awaitable);

        // Suspend until woken by set()
        executor.yield(.waiting) catch |err| {
            // On cancellation, remove from queue
            _ = self.wait_queue.remove(&task.awaitable);
            return err;
        };
    }

    // If state is is_set, we return immediately (event already set)
    std.debug.assert(state == .is_set or state == .waiting);
}

/// Blocks the caller's coroutine until the ResetEvent is set(), or until the corresponding timeout expires.
/// If the timeout expires before the ResetEvent is set, `error.Timeout` is returned.
/// The memory accesses before the set() can be said to happen before timedWait() returns without error.
pub fn timedWait(self: *ResetEvent, runtime: *Runtime, timeout_ns: u64) error{ Timeout, Canceled }!void {
    _ = runtime;
    // Try to atomically register as a waiter
    var state = self.state.load(.acquire);
    if (state == .unset) {
        state = self.state.cmpxchgStrong(.unset, .waiting, .acquire, .acquire) orelse .waiting;
    }

    // If event is already set, return immediately
    if (state == .is_set) {
        return;
    }

    // We're now in waiting state, add to queue and wait with timeout
    std.debug.assert(state == .waiting);
    const current = coroutines.getCurrent() orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);

    self.wait_queue.push(&task.awaitable);

    const TimeoutContext = struct {
        wait_queue: *AwaitableList,
        awaitable: *Awaitable,
    };

    var timeout_ctx = TimeoutContext{
        .wait_queue = &self.wait_queue,
        .awaitable = &task.awaitable,
    };

    executor.timedWaitForReadyWithCallback(
        timeout_ns,
        TimeoutContext,
        &timeout_ctx,
        struct {
            fn onTimeout(ctx: *TimeoutContext) bool {
                // Try to remove from wait queue - if successful, we timed out
                // If failed, we were already signaled
                return ctx.wait_queue.remove(ctx.awaitable);
            }
        }.onTimeout,
    ) catch |err| {
        // Remove from queue if canceled (timeout already handled by callback)
        if (err == error.Canceled) {
            _ = self.wait_queue.remove(&task.awaitable);
        }
        return err;
    };
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
