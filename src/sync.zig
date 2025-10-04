const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const coroutines = @import("coroutines.zig");
const AwaitableList = @import("runtime.zig").AwaitableList;
const Awaitable = @import("runtime.zig").Awaitable;
const AnyTask = @import("runtime.zig").AnyTask;
const xev = @import("xev");

pub const Mutex = struct {
    state: State,

    // TODO: Waiters are currently LIFO (new waiters prepend to head), should be FIFO for fairness
    // EventLoop achieves this by storing both head and tail pointers using fiber result space

    pub const State = enum(usize) {
        locked_once = 0b00,
        unlocked = 0b01,
        contended = 0b10,
        /// Pointer to head of wait queue (*Awaitable)
        _,

        pub fn isUnlocked(state: State) bool {
            return @intFromEnum(state) & @intFromEnum(State.unlocked) == @intFromEnum(State.unlocked);
        }
    };

    pub const init: Mutex = .{ .state = .unlocked };

    pub fn tryLock(mutex: *Mutex) bool {
        const prev_state: State = @enumFromInt(@atomicRmw(
            usize,
            @as(*usize, @ptrCast(&mutex.state)),
            .And,
            ~@intFromEnum(State.unlocked),
            .acquire,
        ));
        return prev_state.isUnlocked();
    }

    pub fn lock(mutex: *Mutex, runtime: *Runtime) void {
        const prev_state: State = @enumFromInt(@atomicRmw(
            usize,
            @as(*usize, @ptrCast(&mutex.state)),
            .And,
            ~@intFromEnum(State.unlocked),
            .acquire,
        ));
        if (prev_state.isUnlocked()) {
            @branchHint(.likely);
            return;
        }

        // Slow path: contention
        _ = runtime;
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);
        var state = prev_state;

        while (true) {
            switch (state) {
                .unlocked => {
                    // Try to acquire (might have become unlocked)
                    state = @cmpxchgWeak(Mutex.State, &mutex.state, .unlocked, .locked_once, .acquire, .acquire) orelse {
                        return; // Got the lock!
                    };
                },
                else => {
                    // Build intrusive queue: current.next = state (head)
                    task.awaitable.next = @ptrFromInt(@intFromEnum(state));
                    // CAS: if state unchanged, make current the new head
                    state = @cmpxchgWeak(Mutex.State, &mutex.state, state, @enumFromInt(@intFromPtr(&task.awaitable)), .release, .acquire) orelse {
                        current.waitForReady();
                        return;
                    };
                },
            }
        }
    }

    pub fn unlock(mutex: *Mutex, runtime: *Runtime) void {
        const prev_state = @cmpxchgWeak(State, &mutex.state, .locked_once, .unlocked, .release, .acquire) orelse {
            @branchHint(.likely);
            return;
        };
        std.debug.assert(prev_state != .unlocked); // mutex not locked

        // Slow path: wake waiting coroutine
        var maybe_waiting: ?*Awaitable = @ptrFromInt(@intFromEnum(prev_state));

        while (if (maybe_waiting) |waiting|
            @cmpxchgWeak(
                Mutex.State,
                &mutex.state,
                @enumFromInt(@intFromPtr(waiting)),
                @enumFromInt(@intFromPtr(waiting.next)),
                .release,
                .acquire,
            )
        else
            @cmpxchgWeak(Mutex.State, &mutex.state, .locked_once, .unlocked, .release, .acquire) orelse return) |next_state|
        {
            maybe_waiting = @ptrFromInt(@intFromEnum(next_state));
        }

        maybe_waiting.?.next = null;
        const task = AnyTask.fromAwaitable(maybe_waiting.?);
        runtime.markReady(&task.coro);
    }
};

pub const Condition = struct {
    state: u64 = 0,

    // TODO: Waiters are currently LIFO (new waiters prepend to head), should be FIFO for fairness
    // EventLoop achieves this by storing both head and tail pointers using fiber result space

    pub const init: Condition = .{};

    pub fn wait(self: *Condition, runtime: *Runtime, mutex: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        // Add to wait queue atomically (LIFO - prepend to head)
        var state = @atomicLoad(u64, &self.state, .acquire);
        while (true) {
            task.awaitable.next = if (state == 0) null else @ptrFromInt(state);
            const new_state = @intFromPtr(&task.awaitable);
            state = @cmpxchgWeak(u64, &self.state, state, new_state, .release, .acquire) orelse break;
        }

        // Atomically release mutex and wait
        mutex.unlock(runtime);
        current.waitForReady();

        // Re-acquire mutex after waking
        mutex.lock(runtime);
    }

    pub fn timedWait(self: *Condition, runtime: *Runtime, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        // Add to wait queue atomically (LIFO - prepend to head)
        var state = @atomicLoad(u64, &self.state, .acquire);
        while (true) {
            task.awaitable.next = if (state == 0) null else @ptrFromInt(state);
            const new_state = @intFromPtr(&task.awaitable);
            state = @cmpxchgWeak(u64, &self.state, state, new_state, .release, .acquire) orelse break;
        }

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
                        if (context.condition.removeAwaitable(context.awaitable)) {
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
    }

    pub fn signal(self: *Condition, runtime: *Runtime) void {
        var state = @atomicLoad(u64, &self.state, .acquire);
        while (state != 0) {
            const head: *Awaitable = @ptrFromInt(state);
            const next_state = if (head.next) |next| @intFromPtr(next) else 0;

            state = @cmpxchgWeak(u64, &self.state, state, next_state, .release, .acquire) orelse {
                // Successfully dequeued head, wake it up
                head.next = null;
                const task = AnyTask.fromAwaitable(head);
                runtime.markReady(&task.coro);
                return;
            };
        }
    }

    pub fn broadcast(self: *Condition, runtime: *Runtime) void {
        // Atomically take the entire queue
        const head_state = @atomicRmw(u64, &self.state, .Xchg, 0, .acquire);
        if (head_state == 0) return;

        // Wake all waiters in the queue
        var current: ?*Awaitable = @ptrFromInt(head_state);
        while (current) |awaitable| {
            const next = awaitable.next;
            awaitable.next = null;
            const task = AnyTask.fromAwaitable(awaitable);
            runtime.markReady(&task.coro);
            current = next;
        }
    }

    // Helper function to remove a specific awaitable from the queue
    // Returns true if the awaitable was found and removed
    fn removeAwaitable(self: *Condition, target: *Awaitable) bool {
        var state = @atomicLoad(u64, &self.state, .acquire);

        while (state != 0) {
            const head: *Awaitable = @ptrFromInt(state);

            // Check if target is the head
            if (head == target) {
                const next_state = if (head.next) |next| @intFromPtr(next) else 0;
                state = @cmpxchgWeak(u64, &self.state, state, next_state, .release, .acquire) orelse {
                    head.next = null;
                    return true;
                };
                continue;
            }

            // Scan the list to find the target
            var prev = head;
            var current = head.next;
            while (current) |node| {
                if (node == target) {
                    // Found it - unlink from the list
                    prev.next = node.next;
                    node.next = null;
                    return true;
                }
                prev = node;
                current = node.next;
            }

            // Not found in this snapshot, reload and retry
            return false;
        }

        return false;
    }
};

/// ResetEvent is a thread-safe bool which can be set to true/false ("set"/"unset").
/// It can also block coroutines until the "bool" is set with cancellation via timed waits.
/// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return.
pub const ResetEvent = struct {
    state: State,

    // TODO: Waiters are currently LIFO (new waiters prepend to head), should be FIFO for fairness
    // EventLoop achieves this by storing both head and tail pointers using fiber result space

    pub const State = enum(usize) {
        unset = 0,
        is_set = 1,
        /// Pointer to head of wait queue (*Awaitable)
        _,

        pub fn isSet(state: State) bool {
            return state == .is_set;
        }
    };

    pub const init: ResetEvent = .{ .state = .unset };

    /// Returns if the ResetEvent was set().
    /// Once reset() is called, this returns false until the next set().
    /// The memory accesses before the set() can be said to happen before isSet() returns true.
    pub fn isSet(self: *const ResetEvent) bool {
        const state: State = @enumFromInt(@atomicLoad(usize, @as(*usize, @ptrCast(@constCast(&self.state))), .acquire));
        return state.isSet();
    }

    /// Marks the ResetEvent as "set" and unblocks any coroutines in wait() or timedWait() to observe the new state.
    /// The ResetEvent stays "set" until reset() is called, making future set() calls do nothing semantically.
    /// The memory accesses before set() can be said to happen before isSet() returns true or wait()/timedWait() return successfully.
    pub fn set(self: *ResetEvent, runtime: *Runtime) void {
        // Atomically swap to is_set and get previous state
        const prev_state: State = @enumFromInt(@atomicRmw(
            usize,
            @as(*usize, @ptrCast(&self.state)),
            .Xchg,
            @intFromEnum(State.is_set),
            .release,
        ));

        // If already set, nothing to do
        if (prev_state == .is_set) {
            return;
        }

        // If there were waiters (state was a pointer), wake them all
        if (prev_state != .unset) {
            var current: ?*Awaitable = @ptrFromInt(@intFromEnum(prev_state));
            while (current) |awaitable| {
                const next = awaitable.next;
                awaitable.next = null;
                const task = AnyTask.fromAwaitable(awaitable);
                runtime.markReady(&task.coro);
                current = next;
            }
        }
    }

    /// Unmarks the ResetEvent from its "set" state if set() was called previously.
    /// It is undefined behavior if reset() is called while coroutines are blocked in wait() or timedWait().
    /// Concurrent calls to set(), isSet() and reset() are allowed.
    pub fn reset(self: *ResetEvent) void {
        @atomicStore(usize, @as(*usize, @ptrCast(&self.state)), @intFromEnum(State.unset), .monotonic);
    }

    /// Blocks the caller's coroutine until the ResetEvent is set().
    /// This is effectively a more efficient version of `while (!isSet()) {}`.
    /// The memory accesses before the set() can be said to happen before wait() returns.
    pub fn wait(self: *ResetEvent, runtime: *Runtime) void {
        _ = runtime;
        var state: State = @enumFromInt(@atomicLoad(usize, @as(*usize, @ptrCast(&self.state)), .acquire));

        // Fast path: already set
        if (state == .is_set) {
            return;
        }

        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        while (true) {
            switch (state) {
                .is_set => return,
                .unset => {
                    // Try to add ourselves as first waiter
                    task.awaitable.next = null;
                    state = @cmpxchgWeak(State, &self.state, .unset, @enumFromInt(@intFromPtr(&task.awaitable)), .release, .acquire) orelse {
                        current.waitForReady();
                        return;
                    };
                },
                else => {
                    // Add to existing queue
                    task.awaitable.next = @ptrFromInt(@intFromEnum(state));
                    state = @cmpxchgWeak(State, &self.state, state, @enumFromInt(@intFromPtr(&task.awaitable)), .release, .acquire) orelse {
                        current.waitForReady();
                        return;
                    };
                },
            }
        }
    }

    /// Blocks the caller's coroutine until the ResetEvent is set(), or until the corresponding timeout expires.
    /// If the timeout expires before the ResetEvent is set, `error.Timeout` is returned.
    /// The memory accesses before the set() can be said to happen before timedWait() returns without error.
    pub fn timedWait(self: *ResetEvent, runtime: *Runtime, timeout_ns: u64) error{Timeout}!void {
        var state: State = @enumFromInt(@atomicLoad(usize, @as(*usize, @ptrCast(&self.state)), .acquire));

        // Fast path: already set
        if (state == .is_set) {
            return;
        }

        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        // Add to wait queue
        while (true) {
            switch (state) {
                .is_set => return,
                .unset => {
                    task.awaitable.next = null;
                    state = @cmpxchgWeak(State, &self.state, .unset, @enumFromInt(@intFromPtr(&task.awaitable)), .release, .acquire) orelse break;
                },
                else => {
                    task.awaitable.next = @ptrFromInt(@intFromEnum(state));
                    state = @cmpxchgWeak(State, &self.state, state, @enumFromInt(@intFromPtr(&task.awaitable)), .release, .acquire) orelse break;
                },
            }
        }

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
                        if (context.reset_event.removeAwaitable(context.awaitable)) {
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

    // Helper function to remove a specific awaitable from the queue
    // Returns true if the awaitable was found and removed
    fn removeAwaitable(self: *ResetEvent, target: *Awaitable) bool {
        var state: State = @enumFromInt(@atomicLoad(usize, @as(*usize, @ptrCast(&self.state)), .acquire));

        while (true) {
            switch (state) {
                .is_set => return false, // Waiter was already woken
                .unset => return false, // No waiters
                else => {
                    // State is a pointer to wait queue
                    const head: *Awaitable = @ptrFromInt(@intFromEnum(state));

                    // Check if target is the head
                    if (head == target) {
                        const next_state: State = if (head.next) |next| @enumFromInt(@intFromPtr(next)) else .unset;
                        state = @cmpxchgWeak(State, &self.state, state, next_state, .release, .acquire) orelse {
                            head.next = null;
                            return true;
                        };
                        continue;
                    }

                    // Scan the list to find the target
                    var prev = head;
                    var current = head.next;
                    while (current) |node| {
                        if (node == target) {
                            // Found it - unlink from the list
                            prev.next = node.next;
                            node.next = null;
                            return true;
                        }
                        prev = node;
                        current = node.next;
                    }

                    // Not found in this snapshot
                    return false;
                },
            }
        }
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
