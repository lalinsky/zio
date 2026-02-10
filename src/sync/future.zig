// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("../runtime.zig").Runtime;
const yield = @import("../runtime.zig").yield;
const Cancelable = @import("../common.zig").Cancelable;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const meta = @import("../meta.zig");
const select = @import("../select.zig");

fn FutureResult(comptime T: type) type {
    const E = meta.ErrorSet(T);
    const P = meta.Payload(T);

    return struct {
        const Self = @This();
        const State = enum(u8) { not_set, setting, ok, err };

        state: std.atomic.Value(State) = std.atomic.Value(State).init(.not_set),
        err_value: E = undefined,
        ok_value: P = undefined,

        pub fn set(self: *Self, value: T) bool {
            const prev = self.state.cmpxchgStrong(.not_set, .setting, .release, .monotonic);
            if (prev == null) {
                const is_error_union = @typeInfo(T) == .error_union;
                if (is_error_union) {
                    if (value) |ok| {
                        self.ok_value = ok;
                        self.state.store(.ok, .release);
                    } else |err| {
                        self.err_value = err;
                        self.state.store(.err, .release);
                    }
                } else {
                    self.ok_value = value;
                    self.state.store(.ok, .release);
                }
                return true;
            }
            return false;
        }

        pub fn isSet(self: *const Self) bool {
            const state = self.state.load(.acquire);
            return state == .ok or state == .err;
        }

        pub fn get(self: *const Self) ?T {
            const state = self.state.load(.acquire);
            const is_error_union = @typeInfo(T) == .error_union;
            if (is_error_union) {
                return switch (state) {
                    .ok => self.ok_value,
                    .err => self.err_value,
                    else => null,
                };
            } else {
                if (state == .ok) {
                    return self.ok_value;
                }
                return null;
            }
        }
    };
}

pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();

        wait_queue: WaitQueue(WaitNode) = .empty,
        value: FutureResult(T) = .{},

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

            // Set flag FIRST to ensure isFlagSet() returns true before we wake any waiters
            self.wait_queue.setFlag();

            // Pop and wake all waiters
            while (self.wait_queue.pop()) |wait_node| {
                wait_node.wake();
            }
        }

        /// Wait for the future's value to be set.
        /// Returns immediately if the value is already available.
        /// Returns error.Canceled if the task is canceled while waiting.
        pub fn wait(self: *Self) Cancelable!select.WaitResult(T) {
            return select.wait(self);
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
            // Try to push to queue - only succeeds if future is not done (flag not set)
            return self.wait_queue.pushUnlessFlag(wait_node);
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *Self, wait_node: *WaitNode) bool {
            return self.wait_queue.remove(wait_node);
        }
    };
}

test "Future: basic set and get" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask() !void {
            var future = Future(i32).init;

            // Set value
            future.set(42);

            // Get value (should return immediately since already set)
            const result = try future.wait();
            try std.testing.expectEqual(42, result.value);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{});
    try handle.join();
}

test "Future: await from coroutine" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const TestContext = struct {
        fn setterTask(future: *Future(i32)) !void {
            // Simulate async work
            try yield();
            try yield();
            future.set(123);
        }

        fn getterTask(future: *Future(i32)) !i32 {
            // This will block until setter sets the value
            const result = try future.wait();
            return result.value;
        }

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn setter coroutine
            var setter_handle = try rt.spawn(setterTask, .{&future});
            defer setter_handle.cancel();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{&future});
            defer getter_handle.cancel();

            const result = try getter_handle.join();
            try std.testing.expectEqual(123, result);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try handle.join();
}

test "Future: multiple waiters" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    const TestContext = struct {
        fn waiterTask(future: *Future(i32), expected: i32) !void {
            const result = try future.wait();
            try std.testing.expectEqual(expected, result.value);
        }

        fn setterTask(future: *Future(i32)) !void {
            // Let waiters block first
            try yield();
            try yield();
            future.set(999);
        }

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn multiple waiters
            var waiter1 = try rt.spawn(waiterTask, .{ &future, 999 });
            defer waiter1.cancel();
            var waiter2 = try rt.spawn(waiterTask, .{ &future, 999 });
            defer waiter2.cancel();
            var waiter3 = try rt.spawn(waiterTask, .{ &future, 999 });
            defer waiter3.cancel();

            // Spawn setter
            var setter = try rt.spawn(setterTask, .{&future});
            defer setter.cancel();

            // Wait for all to complete
            _ = try waiter1.join();
            _ = try waiter2.join();
            _ = try waiter3.join();
            _ = try setter.join();
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime});
    try handle.join();
}
