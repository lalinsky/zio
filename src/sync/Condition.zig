const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const coroutines = @import("../coroutines.zig");
const AwaitableList = @import("../runtime.zig").AwaitableList;
const Awaitable = @import("../runtime.zig").Awaitable;
const AnyTask = @import("../runtime.zig").AnyTask;
const Mutex = @import("Mutex.zig");

wait_queue: AwaitableList = .{},

const Condition = @This();

pub const init: Condition = .{};

pub fn wait(self: *Condition, runtime: *Runtime, mutex: *Mutex) void {
    const current = coroutines.getCurrent() orelse unreachable;
    const task = AnyTask.fromCoroutine(current);

    // Add to wait queue before releasing mutex
    self.wait_queue.push(&task.awaitable);

    // Atomically release mutex and wait
    mutex.unlock(runtime);
    runtime.yield(.waiting);

    // Re-acquire mutex after waking
    mutex.lock(runtime);
}

pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
    const current = coroutines.getCurrent() orelse unreachable;
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

    // Atomically release mutex and wait
    mutex.unlock(runtime);
    defer mutex.lock(runtime);

    try runtime.timedWaitForReadyWithCallback(
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
    );
}

pub fn signal(self: *Condition, runtime: *Runtime) void {
    if (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        runtime.markReady(&task.coro);
    }
}

pub fn broadcast(self: *Condition, runtime: *Runtime) void {
    while (self.wait_queue.pop()) |awaitable| {
        const task = AnyTask.fromAwaitable(awaitable);
        runtime.markReady(&task.coro);
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
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            mtx.lock(rt);
            defer mtx.unlock(rt);

            while (!ready_flag.*) {
                cond.wait(rt, mtx);
            }
        }

        fn signaler(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            rt.yield(.ready); // Give waiter time to start waiting

            mtx.lock(rt);
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
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, timeout_flag: *bool) void {
            mtx.lock(rt);
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
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool, counter: *u32) void {
            mtx.lock(rt);
            defer mtx.unlock(rt);

            while (!ready_flag.*) {
                cond.wait(rt, mtx);
            }
            counter.* += 1;
        }

        fn broadcaster(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            // Give waiters time to start waiting
            rt.yield(.ready);
            rt.yield(.ready);
            rt.yield(.ready);

            mtx.lock(rt);
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
