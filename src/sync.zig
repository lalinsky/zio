const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const coroutines = @import("coroutines.zig");
const AwaitableList = @import("runtime.zig").AwaitableList;
const Awaitable = @import("runtime.zig").Awaitable;
const AnyTask = @import("runtime.zig").AnyTask;
const xev = @import("xev");

pub const Mutex = struct {
    owner: std.atomic.Value(?*coroutines.Coroutine) = std.atomic.Value(?*coroutines.Coroutine).init(null),
    wait_queue: AwaitableList = .{},
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
        const task = AnyTask.fromCoroutine(current);
        self.wait_queue.append(&task.awaitable);

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
        if (self.wait_queue.pop()) |awaitable| {
            const task = AnyTask.fromAwaitable(awaitable);
            // Transfer ownership directly to next waiter
            self.owner.store(&task.coro, .release);
            // Wake them up (they already own the lock)
            self.runtime.markReady(&task.coro);
        } else {
            // No waiters, release the lock completely
            self.owner.store(null, .release);
        }
    }
};

pub const Condition = struct {
    wait_queue: AwaitableList = .{},
    runtime: *Runtime,

    pub fn init(runtime: *Runtime) Condition {
        return .{ .runtime = runtime };
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        // Add to wait queue before releasing mutex
        self.wait_queue.append(&task.awaitable);

        // Atomically release mutex and wait
        mutex.unlock();
        current.waitForReady();

        // Re-acquire mutex after waking
        mutex.lock();
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        self.wait_queue.append(&task.awaitable);

        // Setup timer for timeout
        var timed_out = false;
        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        const TimeoutContext = struct {
            runtime: *Runtime,
            condition: *Condition,
            awaitable: *Awaitable,
            coroutine: *coroutines.Coroutine,
            timed_out: *bool,
        };

        var timeout_ctx = TimeoutContext{
            .runtime = self.runtime,
            .condition = self,
            .awaitable = &task.awaitable,
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
                        if (context.condition.wait_queue.remove(context.awaitable)) {
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
        if (self.wait_queue.pop()) |awaitable| {
            const task = AnyTask.fromAwaitable(awaitable);
            self.runtime.markReady(&task.coro);
        }
    }

    pub fn broadcast(self: *Condition) void {
        while (self.wait_queue.pop()) |awaitable| {
            const task = AnyTask.fromAwaitable(awaitable);
            self.runtime.markReady(&task.coro);
        }
    }
};

/// ResetEvent is a thread-safe bool which can be set to true/false ("set"/"unset").
/// It can also block coroutines until the "bool" is set with cancellation via timed waits.
/// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return.
pub const ResetEvent = struct {
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.unset),
    wait_queue: AwaitableList = .{},
    runtime: *Runtime,

    const State = enum(u8) {
        unset = 0,
        waiting = 1,
        is_set = 2,
    };

    pub fn init(runtime: *Runtime) ResetEvent {
        return .{ .runtime = runtime };
    }

    /// Returns if the ResetEvent was set().
    /// Once reset() is called, this returns false until the next set().
    /// The memory accesses before the set() can be said to happen before isSet() returns true.
    pub fn isSet(self: *const ResetEvent) bool {
        return self.state.load(.acquire) == .is_set;
    }

    /// Marks the ResetEvent as "set" and unblocks any coroutines in wait() or timedWait() to observe the new state.
    /// The ResetEvent stays "set" until reset() is called, making future set() calls do nothing semantically.
    /// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return successfully.
    pub fn set(self: *ResetEvent) void {
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
                self.runtime.markReady(&task.coro);
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
    pub fn wait(self: *ResetEvent) void {
        // Try to atomically register as a waiter
        var state = self.state.load(.acquire);
        if (state == .unset) {
            state = self.state.cmpxchgStrong(.unset, .waiting, .acquire, .acquire) orelse .waiting;
        }

        // If we're now in waiting state, add to queue and block
        if (state == .waiting) {
            const current = coroutines.getCurrent() orelse unreachable;
            const task = AnyTask.fromCoroutine(current);
            self.wait_queue.append(&task.awaitable);

            // Suspend until woken by set()
            current.waitForReady();
        }

        // If state is is_set, we return immediately (event already set)
        std.debug.assert(state == .is_set or state == .waiting);
    }

    /// Blocks the caller's coroutine until the ResetEvent is set(), or until the corresponding timeout expires.
    /// If the timeout expires before the ResetEvent is set, `error.Timeout` is returned.
    /// The memory accesses before the set() can be said to happen before timedWait() returns without error.
    pub fn timedWait(self: *ResetEvent, timeout_ns: u64) error{Timeout}!void {
        // Try to atomically register as a waiter
        var state = self.state.load(.acquire);
        if (state == .unset) {
            state = self.state.cmpxchgStrong(.unset, .waiting, .acquire, .acquire) orelse .waiting;
        }

        // If event is already set, return immediately
        if (state == .is_set) {
            return;
        }

        // We're now in waiting state, add to queue and setup timeout
        std.debug.assert(state == .waiting);
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        self.wait_queue.append(&task.awaitable);

        // Setup timer for timeout
        var timed_out = false;
        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        const TimeoutContext = struct {
            runtime: *Runtime,
            reset_event: *ResetEvent,
            awaitable: *Awaitable,
            coroutine: *coroutines.Coroutine,
            timed_out: *bool,
        };

        var timeout_ctx = TimeoutContext{
            .runtime = self.runtime,
            .reset_event = self,
            .awaitable = &task.awaitable,
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
                        if (context.reset_event.wait_queue.remove(context.awaitable)) {
                            context.timed_out.* = true;
                            context.runtime.markReady(context.coroutine);
                        }
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Suspend until woken by set() or timeout
        current.waitForReady();

        // Check if we timed out
        if (timed_out) {
            return error.Timeout;
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
    try runtime.runUntilComplete(TestFn.testTryLock, .{ &runtime, &mutex, &results }, .{});

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

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &mutex, &condition, &timed_out }, .{});

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

test "ResetEvent basic set/reset/isSet" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var reset_event = ResetEvent.init(&runtime);

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

    var reset_event = ResetEvent.init(&runtime);
    var waiter_finished = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, finished: *bool) void {
            _ = rt;
            event.wait();
            finished.* = true;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) void {
            rt.yield(); // Give waiter time to start waiting
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

    var reset_event = ResetEvent.init(&runtime);
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, timeout_flag: *bool) void {
            _ = rt;
            // Should timeout after 10ms
            event.timedWait(10_000_000) catch |err| {
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

    var reset_event = ResetEvent.init(&runtime);
    var waiter_count: u32 = 0;

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, counter: *u32) void {
            _ = rt;
            event.wait();
            counter.* += 1;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) void {
            // Give waiters time to start waiting
            rt.yield();
            rt.yield();
            rt.yield();
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

    var reset_event = ResetEvent.init(&runtime);
    var wait_completed = false;

    // Set event before waiting
    reset_event.set();

    const TestFn = struct {
        fn waiter(rt: *Runtime, event: *ResetEvent, completed: *bool) void {
            _ = rt;
            event.wait(); // Should return immediately
            completed.* = true;
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &reset_event, &wait_completed }, .{});

    try testing.expect(wait_completed);
    try testing.expect(reset_event.isSet());
}
