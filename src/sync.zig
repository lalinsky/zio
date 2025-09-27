const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const coroutines = @import("coroutines.zig");
const AnyTaskList = @import("runtime.zig").AnyTaskList;
const AnyTask = @import("runtime.zig").AnyTask;
const xev = @import("xev");

pub const Mutex = struct {
    owner: std.atomic.Value(?*coroutines.Coroutine) = std.atomic.Value(?*coroutines.Coroutine).init(null),
    wait_queue: AnyTaskList = .{},
    runtime: *Runtime,

    pub fn init(runtime: *Runtime) Mutex {
        return .{ .runtime = runtime };
    }

    pub fn tryLock(self: *Mutex) bool {
        const current = coroutines.getCurrent() orelse return false;

        // Try to atomically set owner from null to current
        return self.owner.cmpxchgStrong(null, current, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;

        // Fast path: try to acquire unlocked mutex
        if (self.tryLock()) return;

        // Slow path: add current task to wait queue and suspend
        const task_node = Runtime.taskPtrFromCoroPtr(current);
        self.wait_queue.append(task_node);

        // Suspend until woken by unlock()
        current.waitForReady();

        // When we wake up, unlock() has already transferred ownership to us
        const owner = self.owner.load(.acquire);
        std.debug.assert(owner == current);
    }

    pub fn unlock(self: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        std.debug.assert(self.owner.load(.monotonic) == current);

        // Check if there are waiters
        if (self.wait_queue.pop()) |task_node| {
            // Transfer ownership directly to next waiter
            self.owner.store(&task_node.coro, .release);
            // Wake them up (they already own the lock)
            self.runtime.markReady(&task_node.coro);
        } else {
            // No waiters, release the lock completely
            self.owner.store(null, .release);
        }
    }
};

pub const Condition = struct {
    wait_queue: AnyTaskList = .{},
    runtime: *Runtime,

    pub fn init(runtime: *Runtime) Condition {
        return .{ .runtime = runtime };
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task_node = Runtime.taskPtrFromCoroPtr(current);

        // Add to wait queue before releasing mutex
        self.wait_queue.append(task_node);

        // Atomically release mutex and wait
        mutex.unlock();
        current.waitForReady();

        // Re-acquire mutex after waking
        mutex.lock();
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task_node = Runtime.taskPtrFromCoroPtr(current);

        self.wait_queue.append(task_node);

        // Setup timer for timeout
        var timed_out = false;
        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        const TimeoutContext = struct {
            runtime: *Runtime,
            condition: *Condition,
            task_node: *AnyTask,
            coroutine: *coroutines.Coroutine,
            timed_out: *bool,
        };

        var timeout_ctx = TimeoutContext{
            .runtime = self.runtime,
            .condition = self,
            .task_node = task_node,
            .coroutine = current,
            .timed_out = &timed_out,
        };

        var completion: xev.Completion = undefined;
        timer.run(
            &self.runtime.loop,
            &completion,
            timeout_ns / 1_000_000, // Convert to ms
            TimeoutContext,
            &timeout_ctx,
            struct {
                fn callback(
                    ctx: ?*TimeoutContext,
                    loop: *xev.Loop,
                    c: *xev.Completion,
                    result: anyerror!void,
                ) xev.CallbackAction {
                    _ = loop;
                    _ = c;
                    _ = result catch {};
                    if (ctx) |context| {
                        if (context.condition.wait_queue.remove(context.task_node)) {
                            context.timed_out.* = true;
                            context.runtime.markReady(context.coroutine);
                        }
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Release mutex and wait
        mutex.unlock();
        current.waitForReady();

        // Re-acquire mutex first
        mutex.lock();

        // Then check if we timed out and cleanup if needed
        if (timed_out) {
            return error.Timeout;
        }
    }

    pub fn signal(self: *Condition) void {
        if (self.wait_queue.pop()) |task_node| {
            self.runtime.markReady(&task_node.coro);
        }
    }

    pub fn broadcast(self: *Condition) void {
        while (self.wait_queue.pop()) |task_node| {
            self.runtime.markReady(&task_node.coro);
        }
    }
};

test "Mutex basic lock/unlock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init(&runtime);

    const TestFn = struct {
        fn worker(rt: *Runtime, counter: *u32, mtx: *Mutex) void {
            _ = rt;
            for (0..100) |_| {
                mtx.lock();
                defer mtx.unlock();
                counter.* += 1;
            }
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &shared_counter, &mutex }, .{});
    defer task2.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 200), shared_counter);
}

test "Mutex tryLock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init(&runtime);

    const TestFn = struct {
        fn testTryLock(rt: *Runtime, mtx: *Mutex, results: *[3]bool) void {
            _ = rt;
            results[0] = mtx.tryLock(); // Should succeed
            results[1] = mtx.tryLock(); // Should fail (already locked)
            mtx.unlock();
            results[2] = mtx.tryLock(); // Should succeed again
            mtx.unlock();
        }
    };

    var results: [3]bool = undefined;
    var task = try runtime.spawn(TestFn.testTryLock, .{ &runtime, &mutex, &results }, .{});
    defer task.deinit();

    try runtime.run();

    try testing.expect(results[0]); // First tryLock should succeed
    try testing.expect(!results[1]); // Second tryLock should fail
    try testing.expect(results[2]); // Third tryLock should succeed
}

test "Condition basic wait/signal" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init(&runtime);
    var condition = Condition.init(&runtime);
    var ready = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            _ = rt;
            mtx.lock();
            defer mtx.unlock();

            while (!ready_flag.*) {
                cond.wait(mtx);
            }
        }

        fn signaler(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            rt.yield(); // Give waiter time to start waiting

            mtx.lock();
            ready_flag.* = true;
            mtx.unlock();

            cond.signal();
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

    var mutex = Mutex.init(&runtime);
    var condition = Condition.init(&runtime);
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, timeout_flag: *bool) void {
            _ = rt;
            mtx.lock();
            defer mtx.unlock();

            // Should timeout after 10ms
            cond.timedWait(mtx, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    var task = try runtime.spawn(TestFn.waiter, .{ &runtime, &mutex, &condition, &timed_out }, .{});
    defer task.deinit();

    try runtime.run();

    try testing.expect(timed_out);
}

test "Condition broadcast" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var mutex = Mutex.init(&runtime);
    var condition = Condition.init(&runtime);
    var ready = false;
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool, counter: *u32) void {
            _ = rt;
            mtx.lock();
            defer mtx.unlock();

            while (!ready_flag.*) {
                cond.wait(mtx);
            }
            counter.* += 1;
        }

        fn broadcaster(rt: *Runtime, mtx: *Mutex, cond: *Condition, ready_flag: *bool) void {
            // Give waiters time to start waiting
            rt.yield();
            rt.yield();
            rt.yield();

            mtx.lock();
            ready_flag.* = true;
            mtx.unlock();

            cond.broadcast();
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