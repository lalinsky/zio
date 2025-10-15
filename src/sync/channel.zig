const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");

/// A bounded FIFO channel for communication between async tasks.
///
/// Channels provide a way to send values between tasks with backpressure. A channel
/// has a fixed capacity and maintains FIFO ordering. When the channel is full,
/// senders will block until space becomes available. When empty, receivers will
/// block until a value is sent.
///
/// This is implemented as a ring buffer for efficient memory usage and operation.
///
/// This implementation provides cooperative synchronization for the zio runtime.
/// Blocked tasks will suspend and yield to the executor, allowing other work to
/// proceed.
///
/// Channels can be closed to signal that no more values will be sent. After closing,
/// receivers can drain any remaining buffered values before receiving `error.ChannelClosed`.
///
/// ## Example
///
/// ```zig
/// fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
///     for (0..10) |i| {
///         try ch.send(rt, @intCast(i));
///     }
/// }
///
/// fn consumer(rt: *Runtime, ch: *Channel(u32)) !void {
///     while (ch.receive(rt)) |value| {
///         std.debug.print("Received: {}\n", .{value});
///     } else |err| switch (err) {
///         error.ChannelClosed => {}, // Normal shutdown
///         else => return err,
///     }
/// }
///
/// var buffer: [5]u32 = undefined;
/// var channel = Channel(u32).init(&buffer);
///
/// var task1 = try runtime.spawn(producer, .{ &runtime, &channel }, .{});
/// var task2 = try runtime.spawn(consumer, .{ &runtime, &channel }, .{});
/// ```
pub fn Channel(comptime T: type) type {
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

        /// Initializes a channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Checks if the channel is empty.
        pub fn isEmpty(self: *Self, rt: *Runtime) !bool {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == 0;
        }

        /// Checks if the channel is full.
        pub fn isFull(self: *Self, rt: *Runtime) !bool {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);
            return self.count == self.buffer.len;
        }

        /// Receives a value from the channel, blocking if empty.
        ///
        /// Suspends the current task if the channel is empty until a value is sent.
        /// Values are received in FIFO order.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn receive(self: *Self, rt: *Runtime) !T {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            // Wait while empty and not closed
            while (self.count == 0 and !self.closed) {
                try self.not_empty.wait(rt, &self.mutex);
            }

            // If closed and empty, return error
            if (self.closed and self.count == 0) {
                return error.ChannelClosed;
            }

            // Get item from head
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            // Signal that channel is not full
            self.not_full.signal(rt);

            return item;
        }

        /// Tries to receive a value without blocking.
        ///
        /// Returns immediately with a value if available, otherwise returns an error.
        ///
        /// Returns `error.ChannelEmpty` if the channel is empty.
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        /// Returns `error.Canceled` if the task is cancelled while acquiring the lock.
        pub fn tryReceive(self: *Self, rt: *Runtime) !T {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.count == 0) {
                if (self.closed) {
                    return error.ChannelClosed;
                }
                return error.ChannelEmpty;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            self.not_full.signal(rt);

            return item;
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, rt: *Runtime, item: T) !void {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.ChannelClosed;
            }

            // Wait while full
            while (self.count == self.buffer.len) {
                try self.not_full.wait(rt, &self.mutex);
                // Check if closed while waiting
                if (self.closed) {
                    return error.ChannelClosed;
                }
            }

            // Add item to tail
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            // Signal that channel is not empty
            self.not_empty.signal(rt);
        }

        /// Tries to send a value without blocking.
        ///
        /// Returns immediately with success if space is available, otherwise returns an error.
        ///
        /// Returns `error.ChannelFull` if the channel is full.
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while acquiring the lock.
        pub fn trySend(self: *Self, rt: *Runtime, item: T) !void {
            try self.mutex.lock(rt);
            defer self.mutex.unlock(rt);

            if (self.closed) {
                return error.ChannelClosed;
            }

            if (self.count == self.buffer.len) {
                return error.ChannelFull;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            self.not_empty.signal(rt);
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.ChannelClosed`.
        /// Receive operations can still drain any buffered values before returning
        /// `error.ChannelClosed`.
        ///
        /// If `immediate` is true, clears all buffered items immediately. This causes
        /// receivers to get `error.ChannelClosed` right away instead of draining.
        ///
        /// This operation is shielded from cancellation to ensure the close completes.
        pub fn close(self: *Self, rt: *Runtime, immediate: bool) void {
            self.mutex.lockNoCancel(rt);
            defer self.mutex.unlock(rt);

            self.closed = true;

            if (immediate) {
                // Clear the buffer
                self.head = 0;
                self.tail = 0;
                self.count = 0;
            }

            // Wake all waiters so they can see the channel is closed
            self.not_empty.broadcast(rt);
            self.not_full.broadcast(rt);
        }
    };
}

test "Channel: basic send and receive" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), results: *[3]u32) !void {
            results[0] = try ch.receive(rt);
            results[1] = try ch.receive(rt);
            results[2] = try ch.receive(rt);
        }
    };

    var results: [3]u32 = undefined;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &channel }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "Channel: trySend and tryReceive" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testTry(rt: *Runtime, ch: *Channel(u32)) !void {
            // tryReceive on empty channel should fail
            const empty_err = ch.tryReceive(rt);
            try testing.expectError(error.ChannelEmpty, empty_err);

            // trySend should succeed
            try ch.trySend(rt, 1);
            try ch.trySend(rt, 2);

            // trySend on full channel should fail
            const full_err = ch.trySend(rt, 3);
            try testing.expectError(error.ChannelFull, full_err);

            // tryReceive should succeed
            const val1 = try ch.tryReceive(rt);
            try testing.expectEqual(@as(u32, 1), val1);

            const val2 = try ch.tryReceive(rt);
            try testing.expectEqual(@as(u32, 2), val2);

            // tryReceive on empty channel should fail again
            const empty_err2 = ch.tryReceive(rt);
            try testing.expectError(error.ChannelEmpty, empty_err2);
        }
    };

    try runtime.runUntilComplete(TestFn.testTry, .{ &runtime, &channel }, .{});
}

test "Channel: blocking behavior when empty" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn consumer(rt: *Runtime, ch: *Channel(u32), result: *u32) !void {
            result.* = try ch.receive(rt); // Blocks until producer adds item
        }

        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield(); // Let consumer start waiting
            try ch.send(rt, 42);
        }
    };

    var result: u32 = 0;
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &result }, .{});
    defer consumer_task.deinit();
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &channel }, .{});
    defer producer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 42), result);
}

test "Channel: blocking behavior when full" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32), count: *u32) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3); // Blocks until consumer takes item
            count.* += 1;
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield(); // Let producer fill the channel
            try rt.yield();
            _ = try ch.receive(rt); // Unblock producer
        }
    };

    var count: u32 = 0;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &channel, &count }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), count);
}

test "Channel: multiple producers and consumers" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32), start: u32) !void {
            for (0..5) |i| {
                try ch.send(rt, start + @as(u32, @intCast(i)));
            }
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), sum: *u32) !void {
            for (0..5) |_| {
                const val = try ch.receive(rt);
                sum.* += val;
            }
        }
    };

    var sum: u32 = 0;
    var producer1 = try runtime.spawn(TestFn.producer, .{ &runtime, &channel, @as(u32, 0) }, .{});
    defer producer1.deinit();
    var producer2 = try runtime.spawn(TestFn.producer, .{ &runtime, &channel, @as(u32, 100) }, .{});
    defer producer2.deinit();
    var consumer1 = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &sum }, .{});
    defer consumer1.deinit();
    var consumer2 = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &sum }, .{});
    defer consumer2.deinit();

    try runtime.run();

    // Sum should be: (0+1+2+3+4) + (100+101+102+103+104) = 10 + 510 = 520
    try testing.expectEqual(@as(u32, 520), sum);
}

test "Channel: close graceful" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            ch.close(rt, false); // Graceful close - items remain
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), results: *[3]?u32) !void {
            try rt.yield(); // Let producer finish
            results[0] = ch.receive(rt) catch null;
            results[1] = ch.receive(rt) catch null;
            results[2] = ch.receive(rt) catch null; // Should fail with ChannelClosed
        }
    };

    var results: [3]?u32 = .{ null, null, null };
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &channel }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &results }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, 1), results[0]);
    try testing.expectEqual(@as(?u32, 2), results[1]);
    try testing.expectEqual(@as(?u32, null), results[2]); // Closed, no more items
}

test "Channel: close immediate" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
            ch.close(rt, true); // Immediate close - clears all items
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), result: *?u32) !void {
            try rt.yield(); // Let producer finish
            result.* = ch.receive(rt) catch null; // Should fail immediately
        }
    };

    var result: ?u32 = null;
    var producer_task = try runtime.spawn(TestFn.producer, .{ &runtime, &channel }, .{});
    defer producer_task.deinit();
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ &runtime, &channel, &result }, .{});
    defer consumer_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, null), result);
}

test "Channel: send on closed channel" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(rt: *Runtime, ch: *Channel(u32)) !void {
            ch.close(rt, false);

            const put_err = ch.send(rt, 1);
            try testing.expectError(error.ChannelClosed, put_err);

            const tryput_err = ch.trySend(rt, 2);
            try testing.expectError(error.ChannelClosed, tryput_err);
        }
    };

    try runtime.runUntilComplete(TestFn.testClosed, .{ &runtime, &channel }, .{});
}

test "Channel: ring buffer wrapping" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testWrap(rt: *Runtime, ch: *Channel(u32)) !void {
            // Fill the channel
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);

            // Empty it
            _ = try ch.receive(rt);
            _ = try ch.receive(rt);
            _ = try ch.receive(rt);

            // Fill it again (should wrap around)
            try ch.send(rt, 4);
            try ch.send(rt, 5);
            try ch.send(rt, 6);

            // Verify items
            const v1 = try ch.receive(rt);
            const v2 = try ch.receive(rt);
            const v3 = try ch.receive(rt);

            try testing.expectEqual(@as(u32, 4), v1);
            try testing.expectEqual(@as(u32, 5), v2);
            try testing.expectEqual(@as(u32, 6), v3);
        }
    };

    try runtime.runUntilComplete(TestFn.testWrap, .{ &runtime, &channel }, .{});
}
