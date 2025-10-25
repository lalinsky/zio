const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../core/WaitNode.zig");
const FutureResult = @import("../future_result.zig").FutureResult;
const meta = @import("../meta.zig");
const select = @import("../select.zig");

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        wait_queue: WaitQueue(WaitNode) = .empty,
        value: FutureResult(T) = .{},

        // Use WaitQueue sentinel states to encode future state:
        // - sentinel0 = not set (no waiters, value not available)
        // - sentinel1 = done (no waiters, value is available)
        // - pointer = waiting (has waiters, value not available)
        const State = WaitQueue(WaitNode).State;
        const not_set = State.sentinel0;
        const done = State.sentinel1;

        /// Initialize a new Future. Use like: `var future = Future(i32).init;`
        pub const init: Self = .{};

        /// Set the future's value and wake all waiters.
        /// Returns silently if the value was already set.
        pub fn set(self: *Self, val: T) void {
            const was_set = self.value.set(val);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Pop and wake all waiters, then transition to done
            // Loop continues until popOrTransition successfully transitions not_set->done
            while (self.wait_queue.popOrTransition(not_set, done)) |wait_node| {
                wait_node.wake();
            }
        }

        /// Wait for the future's value to be set.
        /// Returns immediately if the value is already available.
        /// Returns error.Canceled if the task is canceled while waiting.
        pub fn wait(self: *Self, runtime: *Runtime) Cancelable!select.WaitResult(T) {
            return select.wait(runtime, self);
        }

        // Future protocol implementation for use with select()
        pub const Result = T;

        /// Gets the result value.
        /// This is part of the Future protocol for select().
        /// Asserts that the future has been set.
        pub fn getResult(self: *Self) T {
            return self.value.get().?;
        }

        /// Registers a wait node to be notified when the future is set.
        /// This is part of the Future protocol for select().
        /// Returns false if the future is already set (no wait needed), true if added to queue.
        pub fn asyncWait(self: *Self, wait_node: *WaitNode) bool {
            // Fast path: check if already set
            if (self.value.isSet()) {
                return false;
            }
            // Try to push to queue - only succeeds if future is not done
            // Returns false if future is done, preventing invalid transition: done -> has_waiters
            return self.wait_queue.pushUnless(done, wait_node);
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
            try testing.expectEqual(@as(i32, 42), result.value);
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
            const result = try future.wait(rt);
            return result.value;
        }

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn setter coroutine
            var setter_handle = try rt.spawn(setterTask, .{ rt, &future }, .{});
            defer setter_handle.deinit();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{ rt, &future }, .{});
            defer getter_handle.deinit();

            const result = try getter_handle.join(rt);
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
            try testing.expectEqual(expected, result.value);
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
            _ = try waiter1.join(rt);
            _ = try waiter2.join(rt);
            _ = try waiter3.join(rt);
            _ = try setter.join(rt);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
