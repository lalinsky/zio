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

    pub const init: Mutex = .{};

    pub fn tryLock(self: *Mutex) bool {
        const current = coroutines.getCurrent() orelse return false;

        // Try to atomically set owner from null to current
        return self.owner.cmpxchgStrong(null, current, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Mutex, runtime: *Runtime) void {
        _ = runtime;
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

    pub fn unlock(self: *Mutex, runtime: *Runtime) void {
        const current = coroutines.getCurrent() orelse unreachable;
        std.debug.assert(self.owner.load(.monotonic) == current);

        // Check if there are waiters
        if (self.wait_queue.pop()) |awaitable| {
            const task = AnyTask.fromAwaitable(awaitable);
            // Transfer ownership directly to next waiter
            self.owner.store(&task.coro, .release);
            // Wake them up (they already own the lock)
            runtime.markReady(&task.coro);
        } else {
            // No waiters, release the lock completely
            self.owner.store(null, .release);
        }
    }
};

pub const Condition = struct {
    wait_queue: AwaitableList = .{},

    pub const init: Condition = .{};

    pub fn wait(self: *Condition, runtime: *Runtime, mutex: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        // Add to wait queue before releasing mutex
        self.wait_queue.append(&task.awaitable);

        // Atomically release mutex and wait
        mutex.unlock(runtime);
        current.waitForReady();

        // Re-acquire mutex after waking
        mutex.lock(runtime);
    }

    pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
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
            .runtime = runtime,
            .condition = self,
            .awaitable = &task.awaitable,
            .coroutine = current,
            .timed_out = &timed_out,
        };

        var completion: xev.Completion = undefined;
        timer.run(
            &runtime.loop,
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
        mutex.unlock(runtime);
        current.waitForReady();

        // Re-acquire mutex first
        mutex.lock(runtime);

        // Then check if we timed out and cleanup if needed
        if (timed_out) {
            return error.Timeout;
        }

        // If we didn't timeout, we were signaled - cancel the timer and wait for cancellation
        const CancelContext = struct {
            runtime: *Runtime,
            coroutine: *coroutines.Coroutine,
        };

        var cancel_ctx = CancelContext{
            .runtime = runtime,
            .coroutine = current,
        };

        var cancel_completion: xev.Completion = undefined;
        timer.cancel(
            &runtime.loop,
            &completion,
            &cancel_completion,
            CancelContext,
            &cancel_ctx,
            struct {
                fn callback(
                    ctx: ?*CancelContext,
                    loop: *xev.Loop,
                    c: *xev.Completion,
                    result: anyerror!void,
                ) xev.CallbackAction {
                    _ = loop;
                    _ = c;
                    _ = result catch {};
                    if (ctx) |context| {
                        context.runtime.markReady(context.coroutine);
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Wait for cancellation to complete
        mutex.unlock(runtime);
        current.waitForReady();
        mutex.lock(runtime);
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
};

/// ResetEvent is a thread-safe bool which can be set to true/false ("set"/"unset").
/// It can also block coroutines until the "bool" is set with cancellation via timed waits.
/// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return.
pub const ResetEvent = struct {
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.unset),
    wait_queue: AwaitableList = .{},

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
                runtime.markReady(&task.coro);
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
    pub fn wait(self: *ResetEvent, runtime: *Runtime) void {
        _ = runtime;
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
    pub fn timedWait(self: *ResetEvent, runtime: *Runtime, timeout_ns: u64) error{Timeout}!void {
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
            .runtime = runtime,
            .reset_event = self,
            .awaitable = &task.awaitable,
            .coroutine = current,
            .timed_out = &timed_out,
        };

        var completion: xev.Completion = undefined;
        timer.run(
            &runtime.loop,
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

        // If we didn't timeout, we were signaled - cancel the timer and wait for cancellation
        const CancelContext = struct {
            runtime: *Runtime,
            coroutine: *coroutines.Coroutine,
        };

        var cancel_ctx = CancelContext{
            .runtime = runtime,
            .coroutine = current,
        };

        var cancel_completion: xev.Completion = undefined;
        timer.cancel(
            &runtime.loop,
            &completion,
            &cancel_completion,
            CancelContext,
            &cancel_ctx,
            struct {
                fn callback(
                    ctx: ?*CancelContext,
                    loop: *xev.Loop,
                    c: *xev.Completion,
                    result: anyerror!void,
                ) xev.CallbackAction {
                    _ = loop;
                    _ = c;
                    _ = result catch {};
                    if (ctx) |context| {
                        context.runtime.markReady(context.coroutine);
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Wait for cancellation to complete
        current.waitForReady();
    }
};

test "Mutex basic lock/unlock" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(rt: *Runtime, counter: *u32, mtx: *Mutex) void {
            for (0..100) |_| {
                mtx.lock(rt);
                defer mtx.unlock(rt);
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

    var mutex = Mutex.init;

    const TestFn = struct {
        fn testTryLock(rt: *Runtime, mtx: *Mutex, results: *[3]bool) void {
            results[0] = mtx.tryLock(); // Should succeed
            results[1] = mtx.tryLock(); // Should fail (already locked)
            mtx.unlock(rt);
            results[2] = mtx.tryLock(); // Should succeed again
            mtx.unlock(rt);
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
            rt.yield(); // Give waiter time to start waiting

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
            rt.yield();
            rt.yield();
            rt.yield();

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
        fn waiter(rt: *Runtime, event: *ResetEvent, finished: *bool) void {
            event.wait(rt);
            finished.* = true;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) void {
            rt.yield(); // Give waiter time to start waiting
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
        fn waiter(rt: *Runtime, event: *ResetEvent, timeout_flag: *bool) void {
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
        fn waiter(rt: *Runtime, event: *ResetEvent, counter: *u32) void {
            event.wait(rt);
            counter.* += 1;
        }

        fn setter(rt: *Runtime, event: *ResetEvent) void {
            // Give waiters time to start waiting
            rt.yield();
            rt.yield();
            rt.yield();
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
        fn waiter(rt: *Runtime, event: *ResetEvent, completed: *bool) void {
            event.wait(rt); // Should return immediately
            completed.* = true;
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &reset_event, &wait_completed }, .{});

    try testing.expect(wait_completed);
    try testing.expect(reset_event.isSet());
}

/// Queue is a coroutine-safe bounded FIFO queue implemented as a ring buffer.
/// It blocks coroutines when full (put) or empty (get).
/// NOT safe for use across OS threads - use within a single Runtime only.
pub fn Queue(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        mutex: Mutex = Mutex.init,
        not_empty: Condition = Condition.init,
        not_full: Condition = Condition.init,

        closed: bool = false,

        const Self = @This();

        /// Initialize a queue with the provided buffer.
        /// The buffer's length determines the queue capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Check if the queue is empty.
        pub fn isEmpty(self: *Self, rt: *Runtime) bool {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == 0;
        }

        /// Check if the queue is full.
        pub fn isFull(self: *Self, rt: *Runtime) bool {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == self.buffer.len;
        }

        /// Get an item from the queue, blocking if empty.
        /// Returns error.QueueClosed if the queue is closed and empty.
        pub fn get(self: *Self, rt: *Runtime) !T {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            // Wait while empty and not closed
            while (self.count == 0 and !self.closed) {
                self.not_empty.wait(rt, &self.mutex);
            }

            // If closed and empty, return error
            if (self.closed and self.count == 0) {
                return error.QueueClosed;
            }

            // Get item from head
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            // Signal that queue is not full
            self.not_full.signal(rt);

            return item;
        }

        /// Try to get an item without blocking.
        /// Returns error.QueueEmpty if empty, error.QueueClosed if closed and empty.
        pub fn tryGet(self: *Self, rt: *Runtime) !T {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.count == 0) {
                if (self.closed) {
                    return error.QueueClosed;
                }
                return error.QueueEmpty;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            self.not_full.signal(rt);

            return item;
        }

        /// Put an item into the queue, blocking if full.
        /// Returns error.QueueClosed if the queue is closed.
        pub fn put(self: *Self, rt: *Runtime, item: T) !void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.QueueClosed;
            }

            // Wait while full
            while (self.count == self.buffer.len) {
                self.not_full.wait(rt, &self.mutex);
                // Check if closed while waiting
                if (self.closed) {
                    return error.QueueClosed;
                }
            }

            // Add item to tail
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            // Signal that queue is not empty
            self.not_empty.signal(rt);
        }

        /// Try to put an item without blocking.
        /// Returns error.QueueFull if full, error.QueueClosed if closed.
        pub fn tryPut(self: *Self, rt: *Runtime, item: T) !void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.QueueClosed;
            }

            if (self.count == self.buffer.len) {
                return error.QueueFull;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            self.not_empty.signal(rt);
        }

        /// Close the queue.
        /// If immediate is true, clears all items from the queue.
        /// After closing, put operations will return error.QueueClosed.
        /// get operations will drain remaining items, then return error.QueueClosed.
        pub fn close(self: *Self, rt: *Runtime, immediate: bool) void {
            self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            self.closed = true;

            if (immediate) {
                // Clear the buffer
                self.head = 0;
                self.tail = 0;
                self.count = 0;
            }

            // Wake all waiters so they can see the queue is closed
            self.not_empty.broadcast(rt);
            self.not_full.broadcast(rt);
        }
    };
}

test "Queue: basic put and get" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), results: *[3]u32) !void {
            results[0] = try q.get(rt);
            results[1] = try q.get(rt);
            results[2] = try q.get(rt);
        }
    };

    var results: [3]u32 = undefined;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "Queue: tryPut and tryGet" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testTry(rt: *Runtime, q: *Queue(u32)) !void {
            // tryGet on empty queue should fail
            const empty_err = q.tryGet(rt);
            try testing.expectError(error.QueueEmpty, empty_err);

            // tryPut should succeed
            try q.tryPut(rt, 1);
            try q.tryPut(rt, 2);

            // tryPut on full queue should fail
            const full_err = q.tryPut(rt, 3);
            try testing.expectError(error.QueueFull, full_err);

            // tryGet should succeed
            const val1 = try q.tryGet(rt);
            try testing.expectEqual(@as(u32, 1), val1);

            const val2 = try q.tryGet(rt);
            try testing.expectEqual(@as(u32, 2), val2);

            // tryGet on empty queue should fail again
            const empty_err2 = q.tryGet(rt);
            try testing.expectError(error.QueueEmpty, empty_err2);
        }
    };

    try runtime.runUntilComplete(TestFn.testTry, .{ &runtime, &queue }, .{});
}

test "Queue: blocking behavior when empty" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn consumer(rt: *Runtime, q: *Queue(u32), result: *u32) !void {
            result.* = try q.get(rt); // Blocks until producer adds item
        }

        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            rt.yield(); // Let consumer start waiting
            try q.put(rt, 42);
        }
    };

    var result: u32 = 0;
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &result }, .{});
    defer consumer_task.deinit();
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 42), result);
}

test "Queue: blocking behavior when full" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32), count: *u32) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3); // Blocks until consumer takes item
            count.* += 1;
        }

        fn consumer(rt: *Runtime, q: *Queue(u32)) !void {
            rt.yield(); // Let producer fill the queue
            rt.yield();
            _ = try q.get(rt); // Unblock producer
        }
    };

    var count: u32 = 0;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, &count }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), count);
}

test "Queue: multiple producers and consumers" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32), start: u32) !void {
            for (0..5) |i| {
                try q.put(rt, start + @as(u32, @intCast(i)));
            }
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), sum: *u32) !void {
            for (0..5) |_| {
                const val = try q.get(rt);
                sum.* += val;
            }
        }
    };

    var sum: u32 = 0;
    var producer1 = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, @as(u32, 0) }, .{});
    defer producer1.deinit();
    var producer2 = try runtime.spawn(TestFn.producer, .{ &runtime, &queue, @as(u32, 100) }, .{});
    defer producer2.deinit();
    var consumer1 = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &sum }, .{});
    defer consumer1.deinit();
    var consumer2 = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &sum }, .{});
    defer consumer2.deinit();

    try runtime.run();

    // Sum should be: (0+1+2+3+4) + (100+101+102+103+104) = 10 + 510 = 520
    try testing.expectEqual(@as(u32, 520), sum);
}

test "Queue: close graceful" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            q.close(rt, false); // Graceful close - items remain
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), results: *[3]?u32) !void {
            rt.yield(); // Let producer finish
            results[0] = q.get(rt) catch null;
            results[1] = q.get(rt) catch null;
            results[2] = q.get(rt) catch null; // Should fail with QueueClosed
        }
    };

    var results: [3]?u32 = .{ null, null, null };
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, 1), results[0]);
    try testing.expectEqual(@as(?u32, 2), results[1]);
    try testing.expectEqual(@as(?u32, null), results[2]); // Closed, no more items
}

test "Queue: close immediate" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, q: *Queue(u32)) !void {
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);
            q.close(rt, true); // Immediate close - clears all items
        }

        fn consumer(rt: *Runtime, q: *Queue(u32), result: *?u32) !void {
            rt.yield(); // Let producer finish
            result.* = q.get(rt) catch null; // Should fail immediately
        }
    };

    var result: ?u32 = null;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &queue }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &queue, &result }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, null), result);
}

test "Queue: put on closed queue" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(rt: *Runtime, q: *Queue(u32)) !void {
            q.close(rt, false);

            const put_err = q.put(rt, 1);
            try testing.expectError(error.QueueClosed, put_err);

            const tryput_err = q.tryPut(rt, 2);
            try testing.expectError(error.QueueClosed, tryput_err);
        }
    };

    try runtime.runUntilComplete(TestFn.testClosed, .{ &runtime, &queue }, .{});
}

test "Queue: ring buffer wrapping" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var queue = Queue(u32).init(&buffer);

    const TestFn = struct {
        fn testWrap(rt: *Runtime, q: *Queue(u32)) !void {
            // Fill the queue
            try q.put(rt, 1);
            try q.put(rt, 2);
            try q.put(rt, 3);

            // Empty it
            _ = try q.get(rt);
            _ = try q.get(rt);
            _ = try q.get(rt);

            // Fill it again (should wrap around)
            try q.put(rt, 4);
            try q.put(rt, 5);
            try q.put(rt, 6);

            // Verify items
            const v1 = try q.get(rt);
            const v2 = try q.get(rt);
            const v3 = try q.get(rt);

            try testing.expectEqual(@as(u32, 4), v1);
            try testing.expectEqual(@as(u32, 5), v2);
            try testing.expectEqual(@as(u32, 6), v3);
        }
    };

    try runtime.runUntilComplete(TestFn.testWrap, .{ &runtime, &queue }, .{});
}

/// Semaphore is a coroutine-safe counting semaphore.
/// It blocks coroutines when the permit count is zero.
/// NOT safe for use across OS threads - use within a single Runtime only.
pub const Semaphore = struct {
    mutex: Mutex = Mutex.init,
    cond: Condition = Condition.init,
    /// It is OK to initialize this field to any value.
    permits: usize = 0,

    /// Block until a permit is available, then decrement the permit count.
    pub fn wait(self: *Semaphore, rt: *Runtime) void {
        self.mutex.lock(rt);
        defer self.mutex.unlock(rt);

        while (self.permits == 0) {
            self.cond.wait(rt, &self.mutex);
        }

        self.permits -= 1;
        if (self.permits > 0) {
            self.cond.signal(rt);
        }
    }

    /// Block until a permit is available or timeout expires.
    /// Returns error.Timeout if the timeout expires before a permit becomes available.
    pub fn timedWait(self: *Semaphore, rt: *Runtime, timeout_ns: u64) error{Timeout}!void {
        var timeout_timer = std.time.Timer.start() catch unreachable;

        self.mutex.lock(rt);
        defer self.mutex.unlock(rt);

        while (self.permits == 0) {
            const elapsed = timeout_timer.read();
            if (elapsed > timeout_ns) {
                return error.Timeout;
            }

            const local_timeout_ns = timeout_ns - elapsed;
            try self.cond.timedWait(rt, &self.mutex, local_timeout_ns);
        }

        self.permits -= 1;
        if (self.permits > 0) {
            self.cond.signal(rt);
        }
    }

    /// Increment the permit count and wake one waiting coroutine.
    pub fn post(self: *Semaphore, rt: *Runtime) void {
        self.mutex.lock(rt);
        defer self.mutex.unlock(rt);

        self.permits += 1;
        self.cond.signal(rt);
    }
};

test "Semaphore: basic wait/post" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 1 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore, n: *i32) void {
            s.wait(rt);
            n.* += 1;
            s.post(rt);
        }
    };

    var n: i32 = 0;
    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem, &n }, .{});
    defer task3.deinit();

    try runtime.run();

    try testing.expectEqual(@as(i32, 3), n);
}

test "Semaphore: timedWait timeout" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, timeout_flag: *bool) void {
            s.timedWait(rt, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ &runtime, &sem, &timed_out }, .{});

    try testing.expect(timed_out);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: timedWait success" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var got_permit = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, flag: *bool) void {
            s.timedWait(rt, 100_000_000) catch return;
            flag.* = true;
        }

        fn poster(rt: *Runtime, s: *Semaphore) void {
            rt.yield();
            s.post(rt);
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ &runtime, &sem, &got_permit }, .{});
    defer waiter_task.deinit();
    var poster_task = try runtime.spawn(TestFn.poster, .{ &runtime, &sem }, .{});
    defer poster_task.deinit();

    try runtime.run();

    try testing.expect(got_permit);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: multiple permits" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 3 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore) void {
            s.wait(rt);
            // Don't post - consume the permit
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &sem }, .{});
    defer task3.deinit();

    try runtime.run();

    try testing.expectEqual(@as(usize, 0), sem.permits);
}
