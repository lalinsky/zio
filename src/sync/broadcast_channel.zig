const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");
const Barrier = @import("Barrier.zig");

/// A broadcast channel for sending values to multiple consumers.
///
/// A broadcast channel allows sending values to multiple independent consumers,
/// where each consumer receives all messages sent after they subscribe. This is
/// implemented as a fixed-capacity ring buffer with non-blocking sends.
///
/// Unlike regular channels, broadcast channels have these characteristics:
/// - Producers never block - sending always succeeds immediately
/// - When full, new messages overwrite the oldest buffered messages
/// - Each consumer maintains its own read position
/// - Slow consumers that fall too far behind receive `error.Lagged`
/// - New subscribers only receive messages sent after subscription
///
/// This design is similar to Tokio's broadcast channel and is useful for
/// implementing pub/sub patterns, event distribution, or message broadcasting.
///
/// This implementation provides cooperative synchronization for the zio runtime.
/// Consumers waiting for messages will suspend and yield to the executor.
///
/// ## Example
///
/// ```zig
/// fn broadcaster(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
///     for (0..10) |i| {
///         try ch.send(rt, @intCast(i));
///     }
/// }
///
/// fn listener(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
///     var consumer = BroadcastChannel(u32).Consumer{};
///     try ch.subscribe(rt, &consumer);
///     defer ch.unsubscribe(rt, &consumer);
///
///     while (ch.receive(rt, &consumer)) |value| {
///         std.debug.print("Received: {}\n", .{value});
///     } else |err| switch (err) {
///         error.Closed => {},
///         error.Lagged => {}, // Fell behind, continue from current position
///         else => return err,
///     }
/// }
///
/// var buffer: [5]u32 = undefined;
/// var channel = BroadcastChannel(u32).init(&buffer);
///
/// var task1 = try runtime.spawn(broadcaster, .{runtime, &channel }, .{});
/// var task2 = try runtime.spawn(listener, .{runtime, &channel }, .{});
/// var task3 = try runtime.spawn(listener, .{runtime, &channel }, .{});
/// ```
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        buffer: []T,
        write_pos: usize = 0, // Monotonically increasing write position

        consumers: ConsumerList = .{},
        mutex: Mutex = Mutex.init,
        not_empty: Condition = Condition.init,

        closed: bool = false,

        const Self = @This();

        /// Consumer handle for receiving broadcast messages.
        /// Must remain valid while subscribed to the channel.
        pub const Consumer = struct {
            read_pos: usize = 0,
            prev: ?*Consumer = null,
            next: ?*Consumer = null,
        };

        const ConsumerList = struct {
            first: ?*Consumer = null,
            last: ?*Consumer = null,

            fn append(self: *ConsumerList, consumer: *Consumer) void {
                consumer.prev = self.last;
                consumer.next = null;
                if (self.last) |last| {
                    last.next = consumer;
                } else {
                    self.first = consumer;
                }
                self.last = consumer;
            }

            fn remove(self: *ConsumerList, consumer: *Consumer) void {
                if (consumer.prev) |prev| {
                    prev.next = consumer.next;
                } else {
                    self.first = consumer.next;
                }
                if (consumer.next) |next| {
                    next.prev = consumer.prev;
                } else {
                    self.last = consumer.prev;
                }
                consumer.prev = null;
                consumer.next = null;
            }
        };

        /// Initialize a broadcast channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Subscribes a consumer to the channel.
        ///
        /// The consumer begins at the current write position and will only receive
        /// messages sent after subscription. Past messages are not available.
        ///
        /// The consumer must remain valid until `unsubscribe()` is called.
        pub fn subscribe(self: *Self, runtime: *Runtime, consumer: *Consumer) !void {
            try self.mutex.lock(runtime);
            defer self.mutex.unlock(runtime);

            consumer.read_pos = self.write_pos;
            self.consumers.append(consumer);
        }

        /// Unsubscribes a consumer from the channel.
        ///
        /// This operation is shielded from cancellation to ensure cleanup completes.
        pub fn unsubscribe(self: *Self, runtime: *Runtime, consumer: *Consumer) void {
            self.mutex.lockUncancelable(runtime);
            defer self.mutex.unlock(runtime);

            self.consumers.remove(consumer);
        }

        /// Receives the next message for this consumer, blocking if none available.
        ///
        /// Suspends the current task if no new messages are available until one is sent.
        ///
        /// Returns `error.Lagged` if the consumer has fallen too far behind (more than
        /// buffer capacity) and missed messages. After a Lagged error, the consumer is
        /// automatically advanced to the oldest available message and can continue receiving.
        ///
        /// Returns `error.Closed` if the channel is closed and no more messages are available.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn receive(self: *Self, runtime: *Runtime, consumer: *Consumer) !T {
            try self.mutex.lock(runtime);
            defer self.mutex.unlock(runtime);

            // Check if we've been lapped (more than buffer.len behind)
            if (consumer.read_pos + self.buffer.len < self.write_pos) {
                // Skip to the oldest available message
                consumer.read_pos = self.write_pos - self.buffer.len;
                return error.Lagged;
            }

            // Wait while caught up and not closed
            while (consumer.read_pos >= self.write_pos and !self.closed) {
                try self.not_empty.wait(runtime, &self.mutex);

                // Recheck lag after waking (could have happened while waiting)
                if (consumer.read_pos + self.buffer.len < self.write_pos) {
                    consumer.read_pos = self.write_pos - self.buffer.len;
                    return error.Lagged;
                }
            }

            // If closed and caught up, return error
            if (self.closed and consumer.read_pos >= self.write_pos) {
                return error.Closed;
            }

            const item = self.buffer[consumer.read_pos % self.buffer.len];
            consumer.read_pos += 1;

            return item;
        }

        /// Tries to receive a message without blocking.
        ///
        /// Returns immediately with a message if available, otherwise returns an error.
        ///
        /// Returns `error.WouldBlock` if no new messages are available.
        /// Returns `error.Lagged` if the consumer has fallen too far behind.
        /// Returns `error.Closed` if the channel is closed and no more messages are available.
        /// Returns `error.Canceled` if the task is cancelled while acquiring the lock.
        pub fn tryReceive(self: *Self, runtime: *Runtime, consumer: *Consumer) !T {
            try self.mutex.lock(runtime);
            defer self.mutex.unlock(runtime);

            // Check if we've been lapped
            if (consumer.read_pos + self.buffer.len < self.write_pos) {
                consumer.read_pos = self.write_pos - self.buffer.len;
                return error.Lagged;
            }

            // Check if caught up
            if (consumer.read_pos >= self.write_pos) {
                if (self.closed) {
                    return error.Closed;
                }
                return error.WouldBlock;
            }

            const item = self.buffer[consumer.read_pos % self.buffer.len];
            consumer.read_pos += 1;

            return item;
        }

        /// Broadcasts a message to all consumers.
        ///
        /// This operation never blocks. If the buffer is full, the oldest message is
        /// overwritten. Slow consumers that haven't read the overwritten message will
        /// receive `error.Lagged` on their next receive attempt.
        ///
        /// Returns `error.Closed` if the channel has been closed.
        /// Returns `error.Canceled` if the task is cancelled while acquiring the lock.
        pub fn send(self: *Self, runtime: *Runtime, item: T) !void {
            try self.mutex.lock(runtime);
            defer self.mutex.unlock(runtime);

            if (self.closed) {
                return error.Closed;
            }

            self.buffer[self.write_pos % self.buffer.len] = item;
            self.write_pos += 1;

            // Wake all waiting consumers
            self.not_empty.broadcast(runtime);
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.Closed`.
        /// Consumers can still drain any buffered messages before receiving `error.Closed`.
        pub fn close(self: *Self, runtime: *Runtime) !void {
            try self.mutex.lock(runtime);
            defer self.mutex.unlock(runtime);

            self.closed = true;

            // Wake all waiting consumers so they can see the channel is closed
            self.not_empty.broadcast(runtime);
        }
    };
}

test "BroadcastChannel: basic send and receive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(rt); // Wait for receiver to subscribe
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[3]u32, b: *Barrier) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);
            _ = try b.wait(rt); // Signal that we're subscribed

            results[0] = try ch.receive(rt, consumer);
            results[1] = try ch.receive(rt, consumer);
            results[2] = try ch.receive(rt, consumer);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var results: [3]u32 = undefined;

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel, &barrier }, .{});
    defer sender_task.deinit();
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer, &results, &barrier }, .{});
    defer receiver_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "BroadcastChannel: multiple consumers receive same messages" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(4); // 3 receivers + 1 sender

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(rt); // Wait for all consumers to subscribe
            try ch.send(rt, 10);
            try ch.send(rt, 20);
            try ch.send(rt, 30);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, sum: *u32, b: *Barrier) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);
            _ = try b.wait(rt); // Signal that we're subscribed

            sum.* += try ch.receive(rt, consumer);
            sum.* += try ch.receive(rt, consumer);
            sum.* += try ch.receive(rt, consumer);
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var consumer3 = BroadcastChannel(u32).Consumer{};
    var sum1: u32 = 0;
    var sum2: u32 = 0;
    var sum3: u32 = 0;

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel, &barrier }, .{});
    defer sender_task.deinit();
    var receiver1_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer1, &sum1, &barrier }, .{});
    defer receiver1_task.deinit();
    var receiver2_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer2, &sum2, &barrier }, .{});
    defer receiver2_task.deinit();
    var receiver3_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer3, &sum3, &barrier }, .{});
    defer receiver3_task.deinit();

    try runtime.run();

    // All consumers should receive all messages
    try testing.expectEqual(@as(u32, 60), sum1);
    try testing.expectEqual(@as(u32, 60), sum2);
    try testing.expectEqual(@as(u32, 60), sum3);
}

test "BroadcastChannel: lagged consumer" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_lag(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);

            // Send more items than buffer capacity without consuming
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
            try ch.send(rt, 4); // This overwrites item 1
            try ch.send(rt, 5); // This overwrites item 2

            // First receive should return Lagged since we missed items 1 and 2
            const err = ch.receive(rt, consumer);
            try testing.expectError(error.Lagged, err);

            // After lag, we should be positioned at the oldest available (3)
            const val1 = try ch.receive(rt, consumer);
            try testing.expectEqual(@as(u32, 3), val1);

            const val2 = try ch.receive(rt, consumer);
            try testing.expectEqual(@as(u32, 4), val2);

            const val3 = try ch.receive(rt, consumer);
            try testing.expectEqual(@as(u32, 5), val3);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    try runtime.runUntilComplete(TestFn.test_lag, .{ runtime, &channel, &consumer }, .{});
}

test "BroadcastChannel: tryReceive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_try(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);

            // tryReceive on empty channel should return WouldBlock
            const err1 = ch.tryReceive(rt, consumer);
            try testing.expectError(error.WouldBlock, err1);

            // Send some items
            try ch.send(rt, 42);
            try ch.send(rt, 43);

            // tryReceive should succeed
            const val1 = try ch.tryReceive(rt, consumer);
            try testing.expectEqual(@as(u32, 42), val1);

            const val2 = try ch.tryReceive(rt, consumer);
            try testing.expectEqual(@as(u32, 43), val2);

            // tryReceive on caught-up consumer should return WouldBlock
            const err2 = ch.tryReceive(rt, consumer);
            try testing.expectError(error.WouldBlock, err2);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    try runtime.runUntilComplete(TestFn.test_try, .{ runtime, &channel, &consumer }, .{});
}

test "BroadcastChannel: new subscriber doesn't receive old messages" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_new_subscriber(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            // Send messages before subscribing
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);

            // Now subscribe
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);

            // Send new message
            try ch.send(rt, 4);

            // Should only receive message 4, not 1, 2, 3
            const val = try ch.receive(rt, consumer);
            try testing.expectEqual(@as(u32, 4), val);

            // tryReceive should return WouldBlock (no more messages)
            const err = ch.tryReceive(rt, consumer);
            try testing.expectError(error.WouldBlock, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    try runtime.runUntilComplete(TestFn.test_new_subscriber, .{ runtime, &channel, &consumer }, .{});
}

test "BroadcastChannel: unsubscribe doesn't affect other consumers" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_unsubscribe(rt: *Runtime, ch: *BroadcastChannel(u32), c1: *BroadcastChannel(u32).Consumer, c2: *BroadcastChannel(u32).Consumer) !void {
            try ch.subscribe(rt, c1);
            try ch.subscribe(rt, c2);

            try ch.send(rt, 1);
            try ch.send(rt, 2);

            // Both should receive
            try testing.expectEqual(@as(u32, 1), try ch.receive(rt, c1));
            try testing.expectEqual(@as(u32, 1), try ch.receive(rt, c2));

            // Unsubscribe c1
            ch.unsubscribe(rt, c1);

            try ch.send(rt, 3);

            // c2 should still receive
            try testing.expectEqual(@as(u32, 2), try ch.receive(rt, c2));
            try testing.expectEqual(@as(u32, 3), try ch.receive(rt, c2));
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    try runtime.runUntilComplete(TestFn.test_unsubscribe, .{ runtime, &channel, &consumer1, &consumer2 }, .{});
}

test "BroadcastChannel: close prevents new sends" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_close(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
            // Send before closing
            try ch.send(rt, 1);

            // Close the channel
            try ch.close(rt);

            // Try to send after closing should fail
            const err = ch.send(rt, 2);
            try testing.expectError(error.Closed, err);
        }
    };

    try runtime.runUntilComplete(TestFn.test_close, .{ runtime, &channel }, .{});
}

test "BroadcastChannel: consumers can drain after close" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(rt); // Wait for receiver to subscribe
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
            try ch.close(rt);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[4]?u32, b: *Barrier) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);
            _ = try b.wait(rt); // Signal that we're subscribed

            // Should be able to drain all messages
            results[0] = ch.receive(rt, consumer) catch null;
            results[1] = ch.receive(rt, consumer) catch null;
            results[2] = ch.receive(rt, consumer) catch null;
            // This should return Closed
            results[3] = ch.receive(rt, consumer) catch null;
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var results: [4]?u32 = .{ null, null, null, null };

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel, &barrier }, .{});
    defer sender_task.deinit();
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer, &results, &barrier }, .{});
    defer receiver_task.deinit();

    try runtime.run();

    try testing.expectEqual(@as(?u32, 1), results[0]);
    try testing.expectEqual(@as(?u32, 2), results[1]);
    try testing.expectEqual(@as(?u32, 3), results[2]);
    try testing.expectEqual(@as(?u32, null), results[3]); // Closed
}

test "BroadcastChannel: waiting consumers wake on close" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn waiter(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, got_closed: *bool, b: *Barrier) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);
            _ = try b.wait(rt); // Signal that we're subscribed and about to wait

            // Wait for message (channel is empty, so will block)
            const err = ch.receive(rt, consumer);
            if (err) |_| {
                // Shouldn't get a value
            } else |e| {
                if (e == error.Closed) {
                    got_closed.* = true;
                }
            }
        }

        fn closer(rt: *Runtime, ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(rt); // Wait for waiter to be ready
            try ch.close(rt);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var got_closed = false;

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ runtime, &channel, &consumer, &got_closed, &barrier }, .{});
    defer waiter_task.deinit();
    var closer_task = try runtime.spawn(TestFn.closer, .{ runtime, &channel, &barrier }, .{});
    defer closer_task.deinit();

    try runtime.run();

    try testing.expect(got_closed);
}

test "BroadcastChannel: tryReceive returns Closed when channel closed and empty" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_try_closed(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            try ch.subscribe(rt, consumer);
            defer ch.unsubscribe(rt, consumer);

            // Close the empty channel
            try ch.close(rt);

            // tryReceive should return Closed
            const err = ch.tryReceive(rt, consumer);
            try testing.expectError(error.Closed, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    try runtime.runUntilComplete(TestFn.test_try_closed, .{ runtime, &channel, &consumer }, .{});
}
