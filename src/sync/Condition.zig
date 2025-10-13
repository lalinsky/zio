const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Cancelable = @import("../runtime.zig").Cancelable;
const coroutines = @import("../coroutines.zig");
const AwaitableList = @import("../runtime.zig").AwaitableList;
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const Mutex = @import("Mutex.zig");

wait_queue: AwaitableList = .{},

const Condition = @This();

pub const init: Condition = .{};

pub fn wait(self: *Condition, runtime: *Runtime, mutex: *Mutex) Cancelable!void {
    const current = coroutines.getCurrent() orelse unreachable;
    const executor = Executor.fromCoroutine(current);
    const task = AnyTask.fromCoroutine(current);

    // Add to wait queue before releasing mutex
    self.wait_queue.push(&task.awaitable);

    // Atomically release mutex and wait
    mutex.unlock(runtime);
    executor.yield(.waiting) catch |err| {
        // On cancellation, remove from queue and reacquire mutex
        _ = self.wait_queue.remove(&task.awaitable);
        // Must reacquire mutex before returning, retry if canceled
        while (true) {
            mutex.lock(runtime) catch continue;
            break;
        }
        return err;
    };

    // Re-acquire mutex after waking
    try mutex.lock(runtime);
}

pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) error{ Timeout, Canceled }!void {
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

    var was_canceled = false;

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
                return ctx.wait_queue.remove(ctx.awaitable);
            }
        }.onTimeout,
    ) catch |err| {
        // Remove from queue if canceled (timeout already handled by callback)
        if (err == error.Canceled) {
            _ = self.wait_queue.remove(&task.awaitable);
        }
        // Re-acquire mutex before returning - retry if canceled
        while (true) {
            mutex.lock(runtime) catch {
                was_canceled = true;
                continue;
            };
            break;
        }
        // Cancellation has priority over timeout
        if (was_canceled) {
            return error.Canceled;
        }
        return err;
    };

    // Re-acquire mutex before returning - retry if canceled
    while (true) {
        mutex.lock(runtime) catch {
            was_canceled = true;
            continue;
        };
        break;
    }

    // Cancellation has priority
    if (was_canceled) {
        return error.Canceled;
    }
}

pub fn signal(self: *Condition, runtime: *Runtime) void {
    _ = runtime;
    if (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        const executor = Executor.fromCoroutine(&task.coro);
        executor.markReady(&task.coro);
    }
}

pub fn broadcast(self: *Condition, runtime: *Runtime) void {
    _ = runtime;
    while (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        const executor = Executor.fromCoroutine(&task.coro);
        executor.markReady(&task.coro);
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
