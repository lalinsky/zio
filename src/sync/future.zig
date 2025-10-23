const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../runtime.zig").Cancelable;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../core/WaitNode.zig");
const FutureResult = @import("../future_result.zig").FutureResult;
const meta = @import("../meta.zig");

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        wait_queue: WaitQueue(WaitNode) = .empty,
        future_result: FutureResult(T) = .{},

        /// Initialize a new Future. Use like: `var future = Future(i32).init;`
        pub const init: Self = .{};

        /// Set the future's value and wake all waiters.
        /// Returns silently if the value was already set.
        pub fn set(self: *Self, value: T) void {
            const was_set = self.future_result.set(value);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Wake all waiters
            while (self.wait_queue.pop()) |wait_node| {
                wait_node.wake();
            }
        }

        /// Wait for the future's value to be set.
        /// Returns immediately if the value is already available.
        /// Returns error.Canceled if the task is canceled while waiting.
        pub fn wait(self: *Self, runtime: *Runtime) Cancelable!meta.Payload(T) {
            // Fast path: check if already set
            if (self.future_result.get()) |res| {
                return res;
            }

            // Must be called from a coroutine context
            const task = runtime.getCurrentTask() orelse {
                @panic("Future.wait() must be called from a coroutine");
            };
            const executor = task.getExecutor();

            // Transition to preparing_to_wait state before adding to queue
            task.coro.state.store(.preparing_to_wait, .release);

            // Add to wait queue
            self.wait_queue.push(&task.awaitable.wait_node);

            // Double-check before suspending (avoid lost wakeup)
            if (self.future_result.get()) |res| {
                // Value was set between our check and adding to queue
                _ = self.wait_queue.remove(&task.awaitable.wait_node);
                return res;
            }

            // Yield and wait for signal
            executor.yield(.preparing_to_wait, .waiting_sync, .allow_cancel) catch |err| {
                // On cancellation, remove from queue
                _ = self.wait_queue.remove(&task.awaitable.wait_node);
                return err;
            };

            // We were woken up, result must be available
            return self.future_result.get().?;
        }

        // Future protocol implementation for use with select()
        pub const Result = T;

        /// Gets the result value.
        /// This is part of the Future protocol for select().
        /// Asserts that the future has been set.
        pub fn getResult(self: *Self) T {
            return self.future_result.get().?;
        }

        /// Registers a wait node to be notified when the future is set.
        /// This is part of the Future protocol for select().
        /// Returns false if the future is already set (no wait needed), true if added to queue.
        pub fn asyncWait(self: *Self, wait_node: *WaitNode) bool {
            if (self.future_result.get() != null) {
                return false;
            }
            self.wait_queue.push(wait_node);
            return true;
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        pub fn asyncCancelWait(self: *Self, wait_node: *WaitNode) void {
            _ = self.wait_queue.remove(wait_node);
        }
    };
}

test "Future: basic set and get" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Set value
            future.set(42);

            // Get value (should return immediately since already set)
            const result = try future.wait(rt);
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "Future: await from coroutine" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn setterTask(rt: *Runtime, future: *Future(i32)) !void {
            // Simulate async work
            try rt.yield();
            try rt.yield();
            future.set(123);
        }

        fn getterTask(rt: *Runtime, future: *Future(i32)) !i32 {
            // This will block until setter sets the value
            return future.wait(rt);
        }

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn setter coroutine
            var setter_handle = try rt.spawn(setterTask, .{ rt, &future }, .{});
            defer setter_handle.deinit();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{ rt, &future }, .{});
            defer getter_handle.deinit();

            const result = try getter_handle.join();
            try testing.expectEqual(@as(i32, 123), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "Future: multiple waiters" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn waiterTask(rt: *Runtime, future: *Future(i32), expected: i32) !void {
            const result = try future.wait(rt);
            try testing.expectEqual(expected, result);
        }

        fn setterTask(rt: *Runtime, future: *Future(i32)) !void {
            // Let waiters block first
            try rt.yield();
            try rt.yield();
            future.set(999);
        }

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn multiple waiters
            var waiter1 = try rt.spawn(waiterTask, .{ rt, &future, @as(i32, 999) }, .{});
            defer waiter1.deinit();
            var waiter2 = try rt.spawn(waiterTask, .{ rt, &future, @as(i32, 999) }, .{});
            defer waiter2.deinit();
            var waiter3 = try rt.spawn(waiterTask, .{ rt, &future, @as(i32, 999) }, .{});
            defer waiter3.deinit();

            // Spawn setter
            var setter = try rt.spawn(setterTask, .{ rt, &future }, .{});
            defer setter.deinit();

            // Wait for all to complete
            _ = try waiter1.join();
            _ = try waiter2.join();
            _ = try waiter3.join();
            _ = try setter.join();
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
