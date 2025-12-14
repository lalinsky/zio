// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const WaitNode = @import("../core/WaitNode.zig");
const Barrier = @import("Barrier.zig");
const select = @import("../select.zig").select;

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
///     _ = rt;
///     for (0..10) |i| {
///         try ch.send(@intCast(i));
///     }
/// }
///
/// fn listener(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
///     var consumer = BroadcastChannel(u32).Consumer{};
///     ch.subscribe(&consumer);
///     defer ch.unsubscribe(&consumer);
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
        mutex: std.Thread.Mutex = .{},
        wait_queue: SimpleWaitQueue(WaitNode) = .empty,

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
        pub fn subscribe(self: *Self, consumer: *Consumer) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Guard against double-subscribe (would corrupt the list)
            std.debug.assert(consumer.prev == null and consumer.next == null);

            consumer.read_pos = self.write_pos;
            self.consumers.append(consumer);
        }

        /// Unsubscribes a consumer from the channel.
        pub fn unsubscribe(self: *Self, consumer: *Consumer) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Guard against unsubscribing a consumer that's not in the list
            std.debug.assert(consumer.prev != null or consumer.next != null or
                self.consumers.first == consumer or self.consumers.last == consumer);

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
            const task = runtime.getCurrentTask();
            const executor = task.getExecutor();

            while (true) {
                self.mutex.lock();

                // Check if we've been lapped (more than buffer.len behind)
                // Use wrapping subtraction to handle counter overflow correctly
                const unread = self.write_pos -% consumer.read_pos;
                if (unread > self.buffer.len) {
                    // Skip to the oldest available message
                    consumer.read_pos = self.write_pos -% self.buffer.len;
                    self.mutex.unlock();
                    return error.Lagged;
                }

                // Fast path: message available
                if (unread > 0) {
                    const item = self.buffer[consumer.read_pos % self.buffer.len];
                    consumer.read_pos +%= 1;
                    self.mutex.unlock();
                    return item;
                }

                // Check if closed and caught up
                if (self.closed) {
                    self.mutex.unlock();
                    return error.Closed;
                }

                // Slow path: need to wait
                task.state.store(.preparing_to_wait, .release);
                self.wait_queue.push(&task.awaitable.wait_node);
                self.mutex.unlock();

                // Yield with cancellation support
                executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
                    // Cancelled - try to remove from queue
                    self.mutex.lock();
                    const was_in_queue = self.wait_queue.remove(&task.awaitable.wait_node);
                    if (!was_in_queue) {
                        // We were already removed by a sender who will wake us.
                        // Since we're being cancelled and won't consume the message,
                        // wake another consumer to receive it instead.
                        const next_consumer = self.wait_queue.pop();
                        self.mutex.unlock();
                        if (next_consumer) |node| {
                            node.wake();
                        }
                    } else {
                        self.mutex.unlock();
                    }
                    return err;
                };

                // Woken up, loop to try again
            }
        }

        /// Tries to receive a message without blocking.
        ///
        /// Returns immediately with a message if available, otherwise returns an error.
        ///
        /// Returns `error.WouldBlock` if no new messages are available.
        /// Returns `error.Lagged` if the consumer has fallen too far behind.
        /// Returns `error.Closed` if the channel is closed and no more messages are available.
        pub fn tryReceive(self: *Self, consumer: *Consumer) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Use wrapping subtraction to handle counter overflow correctly
            const unread = self.write_pos -% consumer.read_pos;

            // Check if we've been lapped
            if (unread > self.buffer.len) {
                consumer.read_pos = self.write_pos -% self.buffer.len;
                return error.Lagged;
            }

            // Check if caught up
            if (unread == 0) {
                if (self.closed) {
                    return error.Closed;
                }
                return error.WouldBlock;
            }

            const item = self.buffer[consumer.read_pos % self.buffer.len];
            consumer.read_pos +%= 1;

            return item;
        }

        /// Broadcasts a message to all consumers.
        ///
        /// This operation never blocks. If the buffer is full, the oldest message is
        /// overwritten. Slow consumers that haven't read the overwritten message will
        /// receive `error.Lagged` on their next receive attempt.
        ///
        /// Returns `error.Closed` if the channel has been closed.
        pub fn send(self: *Self, item: T) !void {
            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return error.Closed;
            }

            self.buffer[self.write_pos % self.buffer.len] = item;
            self.write_pos +%= 1;

            // Wake all waiting consumers
            var waiters = self.wait_queue.popAll();
            self.mutex.unlock();

            while (waiters.pop()) |node| {
                node.wake();
            }
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.Closed`.
        /// Consumers can still drain any buffered messages before receiving `error.Closed`.
        pub fn close(self: *Self) void {
            self.mutex.lock();

            self.closed = true;

            // Wake all waiting consumers so they can see the channel is closed
            var waiters = self.wait_queue.popAll();
            self.mutex.unlock();

            while (waiters.pop()) |node| {
                node.wake();
            }
        }

        /// Creates an AsyncReceive operation for use with select().
        ///
        /// Returns a single-shot future that will receive one value from the channel
        /// for the specified consumer. Create a new AsyncReceive for each select() operation.
        ///
        /// Example:
        /// ```zig
        /// var consumer = BroadcastChannel(u32).Consumer{};
        /// channel.subscribe(&consumer);
        /// defer channel.unsubscribe(&consumer);
        ///
        /// var recv = channel.asyncReceive(&consumer);
        /// const result = try select(rt, .{ .recv = &recv });
        /// switch (result) {
        ///     .recv => |val| std.debug.print("Received: {}\n", .{val}),
        /// }
        /// ```
        pub fn asyncReceive(self: *Self, consumer: *Consumer) AsyncReceive(T) {
            return AsyncReceive(T).init(self, consumer);
        }
    };
}

/// AsyncReceive represents a pending receive operation on a BroadcastChannel.
/// This type implements the Future protocol and can be used with select().
///
/// Each AsyncReceive is single-shot - it represents one receive operation for a specific consumer.
/// Create a new AsyncReceive for each select() operation.
///
/// Example:
/// ```zig
/// var consumer1 = BroadcastChannel(u32).Consumer{};
/// var consumer2 = BroadcastChannel(u32).Consumer{};
/// channel.subscribe(&consumer1);
/// channel.subscribe(&consumer2);
///
/// var recv1 = channel.asyncReceive(&consumer1);
/// var recv2 = other_channel.asyncReceive(&consumer2);
/// const result = try select(rt, .{ .ch1 = &recv1, .ch2 = &recv2 });
/// ```
pub fn AsyncReceive(comptime T: type) type {
    return struct {
        channel_wait_node: WaitNode,
        parent_wait_node: ?*WaitNode = null,
        channel: *BroadcastChannel(T),
        consumer: *BroadcastChannel(T).Consumer,
        result: ?Result = null,

        const Self = @This();

        pub const Result = error{ Closed, Lagged }!T;

        const wait_node_vtable = WaitNode.VTable{
            .wake = waitNodeWake,
        };

        fn init(channel: *BroadcastChannel(T), consumer: *BroadcastChannel(T).Consumer) Self {
            return .{
                .channel_wait_node = .{
                    .vtable = &wait_node_vtable,
                },
                .channel = channel,
                .consumer = consumer,
            };
        }

        fn waitNodeWake(wait_node: *WaitNode) void {
            const self: *Self = @fieldParentPtr("channel_wait_node", wait_node);

            // Perform the receive operation under lock
            self.channel.mutex.lock();

            // Read and clear parent_wait_node while holding the lock to prevent
            // race with cancellation (which could free/reuse the parent)
            const parent = self.parent_wait_node;
            self.parent_wait_node = null;

            // Use wrapping subtraction to handle counter overflow correctly
            const unread = self.channel.write_pos -% self.consumer.read_pos;

            // Check if we've been lapped
            if (unread > self.channel.buffer.len) {
                self.consumer.read_pos = self.channel.write_pos -% self.channel.buffer.len;
                self.channel.mutex.unlock();
                self.result = error.Lagged;
            } else if (unread > 0) {
                // Take item from buffer
                const item = self.channel.buffer[self.consumer.read_pos % self.channel.buffer.len];
                self.consumer.read_pos +%= 1;
                self.channel.mutex.unlock();
                self.result = item;
            } else if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.Closed;
            } else {
                // Should never happen - woken but nothing available and not closed
                self.channel.mutex.unlock();
                unreachable;
            }

            // Wake the parent (SelectWaiter or task wait node)
            if (parent) |p| {
                p.wake();
            }
        }

        /// Register for notification when receive can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.parent_wait_node = wait_node;

            self.channel.mutex.lock();

            // Use wrapping subtraction to handle counter overflow correctly
            const unread = self.channel.write_pos -% self.consumer.read_pos;

            // Check if we've been lapped
            if (unread > self.channel.buffer.len) {
                self.consumer.read_pos = self.channel.write_pos -% self.channel.buffer.len;
                self.channel.mutex.unlock();
                self.result = error.Lagged;
                return false; // Already ready (with error)
            }

            // Fast path: message available
            if (unread > 0) {
                const item = self.channel.buffer[self.consumer.read_pos % self.channel.buffer.len];
                self.consumer.read_pos +%= 1;
                self.channel.mutex.unlock();
                self.result = item;
                return false; // Already ready
            }

            // Fast path: channel closed
            if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.Closed;
                return false; // Already ready (with error)
            }

            // Slow path: enqueue and wait
            self.channel.wait_queue.push(&self.channel_wait_node);
            self.channel.mutex.unlock();
            return true; // Need to wait
        }

        /// Cancel a pending wait operation.
        pub fn asyncCancelWait(self: *Self, _: *Runtime, wait_node: *WaitNode) void {
            self.channel.mutex.lock();

            // Defensively clear parent_wait_node under lock to prevent race with waitNodeWake.
            // If waitNodeWake already cleared it, parent_wait_node will be null.
            // If it's something else, that's a bug (wrong wait_node passed).
            if (self.parent_wait_node) |parent| {
                std.debug.assert(parent == wait_node);
                self.parent_wait_node = null;
            }

            const was_in_queue = self.channel.wait_queue.remove(&self.channel_wait_node);
            if (!was_in_queue) {
                // We were already removed by a sender who will wake us.
                // Since we're being cancelled and won't consume the message,
                // wake another consumer to receive it instead.
                const next_consumer = self.channel.wait_queue.pop();
                self.channel.mutex.unlock();
                if (next_consumer) |node| {
                    node.wake();
                }
            } else {
                self.channel.mutex.unlock();
            }
        }

        /// Get the result of the receive operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *Self) Result {
            return self.result.?;
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
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[3]u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(rt); // Signal that we're subscribed

            results[0] = try ch.receive(rt, consumer);
            results[1] = try ch.receive(rt, consumer);
            results[2] = try ch.receive(rt, consumer);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var results: [3]u32 = undefined;

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel, &barrier }, .{});
    defer sender_task.cancel(runtime);
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer, &results, &barrier }, .{});
    defer receiver_task.cancel(runtime);

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
            try ch.send(10);
            try ch.send(20);
            try ch.send(30);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, sum: *u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
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
    defer sender_task.cancel(runtime);
    var receiver1_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer1, &sum1, &barrier }, .{});
    defer receiver1_task.cancel(runtime);
    var receiver2_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer2, &sum2, &barrier }, .{});
    defer receiver2_task.cancel(runtime);
    var receiver3_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer3, &sum3, &barrier }, .{});
    defer receiver3_task.cancel(runtime);

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
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send more items than buffer capacity without consuming
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            try ch.send(4); // This overwrites item 1
            try ch.send(5); // This overwrites item 2

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
    var handle = try runtime.spawn(TestFn.test_lag, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: tryReceive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_try(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            _ = rt;
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // tryReceive on empty channel should return WouldBlock
            const err1 = ch.tryReceive(consumer);
            try testing.expectError(error.WouldBlock, err1);

            // Send some items
            try ch.send(42);
            try ch.send(43);

            // tryReceive should succeed
            const val1 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 42), val1);

            const val2 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 43), val2);

            // tryReceive on caught-up consumer should return WouldBlock
            const err2 = ch.tryReceive(consumer);
            try testing.expectError(error.WouldBlock, err2);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_try, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
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
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);

            // Now subscribe
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send new message
            try ch.send(4);

            // Should only receive message 4, not 1, 2, 3
            const val = try ch.receive(rt, consumer);
            try testing.expectEqual(@as(u32, 4), val);

            // tryReceive should return WouldBlock (no more messages)
            const err = ch.tryReceive(consumer);
            try testing.expectError(error.WouldBlock, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_new_subscriber, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: unsubscribe doesn't affect other consumers" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_unsubscribe(rt: *Runtime, ch: *BroadcastChannel(u32), c1: *BroadcastChannel(u32).Consumer, c2: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(c1);
            ch.subscribe(c2);

            try ch.send(1);
            try ch.send(2);

            // Both should receive
            try testing.expectEqual(@as(u32, 1), try ch.receive(rt, c1));
            try testing.expectEqual(@as(u32, 1), try ch.receive(rt, c2));

            // Unsubscribe c1
            ch.unsubscribe(c1);

            try ch.send(3);

            // c2 should still receive
            try testing.expectEqual(@as(u32, 2), try ch.receive(rt, c2));
            try testing.expectEqual(@as(u32, 3), try ch.receive(rt, c2));
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_unsubscribe, .{ runtime, &channel, &consumer1, &consumer2 }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: close prevents new sends" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_close(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
            _ = rt;
            // Send before closing
            try ch.send(1);

            // Close the channel
            ch.close();

            // Try to send after closing should fail
            const err = ch.send(2);
            try testing.expectError(error.Closed, err);
        }
    };

    var handle = try runtime.spawn(TestFn.test_close, .{ runtime, &channel }, .{});
    try handle.join(runtime);
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
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            ch.close();
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[4]?u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
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
    defer sender_task.cancel(runtime);
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer, &results, &barrier }, .{});
    defer receiver_task.cancel(runtime);

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
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
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
            ch.close();
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var got_closed = false;

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ runtime, &channel, &consumer, &got_closed, &barrier }, .{});
    defer waiter_task.cancel(runtime);
    var closer_task = try runtime.spawn(TestFn.closer, .{ runtime, &channel, &barrier }, .{});
    defer closer_task.cancel(runtime);

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
            _ = rt;
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Close the empty channel
            ch.close();

            // tryReceive should return Closed
            const err = ch.tryReceive(consumer);
            try testing.expectError(error.Closed, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_try_closed, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: asyncReceive with select - basic" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(rt);
            try rt.yield(); // Let receiver start waiting
            try ch.send(42);
        }

        fn receiver(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(rt);

            var recv = ch.asyncReceive(consumer);
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectEqual(@as(u32, 42), try val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel, &barrier }, .{});
    defer sender_task.cancel(runtime);
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel, &consumer, &barrier }, .{});
    defer receiver_task.cancel(runtime);

    try runtime.run();
}

test "BroadcastChannel: asyncReceive with select - already ready" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send first, so receiver finds it ready
            try ch.send(99);

            var recv = ch.asyncReceive(consumer);
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectEqual(@as(u32, 99), try val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_ready, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: asyncReceive with select - closed channel" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            ch.close();

            var recv = ch.asyncReceive(consumer);
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectError(error.Closed, val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_closed, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: asyncReceive with select - lagged consumer" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_lagged(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send more items than buffer capacity without consuming
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            try ch.send(4); // This overwrites item 1
            try ch.send(5); // This overwrites item 2

            // asyncReceive should return Lagged immediately
            var recv = ch.asyncReceive(consumer);
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectError(error.Lagged, val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_lagged, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}

test "BroadcastChannel: select with multiple broadcast channels" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer1: [5]u32 = undefined;
    var channel1 = BroadcastChannel(u32).init(&buffer1);

    var buffer2: [5]u32 = undefined;
    var channel2 = BroadcastChannel(u32).init(&buffer2);

    const TestFn = struct {
        fn selectTask(rt: *Runtime, ch1: *BroadcastChannel(u32), ch2: *BroadcastChannel(u32), c1: *BroadcastChannel(u32).Consumer, c2: *BroadcastChannel(u32).Consumer, which: *u8) !void {
            ch1.subscribe(c1);
            defer ch1.unsubscribe(c1);
            ch2.subscribe(c2);
            defer ch2.unsubscribe(c2);

            var recv1 = ch1.asyncReceive(c1);
            var recv2 = ch2.asyncReceive(c2);

            const result = try select(rt, .{ .ch1 = &recv1, .ch2 = &recv2 });
            switch (result) {
                .ch1 => |val| {
                    try testing.expectEqual(@as(u32, 42), try val);
                    which.* = 1;
                },
                .ch2 => |val| {
                    try testing.expectEqual(@as(u32, 99), try val);
                    which.* = 2;
                },
            }
        }

        fn sender2(rt: *Runtime, ch: *BroadcastChannel(u32)) !void {
            try rt.yield();
            try ch.send(99);
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var which: u8 = 0;
    var select_task = try runtime.spawn(TestFn.selectTask, .{ runtime, &channel1, &channel2, &consumer1, &consumer2, &which }, .{});
    defer select_task.cancel(runtime);
    var sender_task = try runtime.spawn(TestFn.sender2, .{ runtime, &channel2 }, .{});
    defer sender_task.cancel(runtime);

    try runtime.run();

    // ch2 should win
    try testing.expectEqual(@as(u8, 2), which);
}

test "BroadcastChannel: position counter overflow handling" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_overflow(rt: *Runtime, ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            _ = rt;
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Simulate near-overflow condition by setting positions close to usize max
            // This tests that wrapping arithmetic works correctly
            const near_max = std.math.maxInt(usize) - 5;

            ch.mutex.lock();
            ch.write_pos = near_max;
            consumer.read_pos = near_max;
            ch.mutex.unlock();

            // Send items that will cause write_pos to wrap around
            try ch.send(100);
            try ch.send(101);
            try ch.send(102);

            // Verify we can receive correctly even after overflow
            const val1 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 100), val1);

            const val2 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 101), val2);

            const val3 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 102), val3);

            // At this point: write_pos has wrapped to (maxInt - 2),
            // consumer.read_pos has wrapped to (maxInt - 2)
            // Send more items - write_pos will continue wrapping
            try ch.send(103);
            try ch.send(104);
            try ch.send(105);

            // Receive them to verify wrapping arithmetic works
            const val4 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 103), val4);

            const val5 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 104), val5);

            const val6 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 105), val6);

            // Now test lag detection with wrapped counters
            // Send more than buffer capacity without consuming
            try ch.send(200);
            try ch.send(201);
            try ch.send(202);
            try ch.send(203); // This overwrites oldest (200)

            // Next receive should detect lag correctly even with wrapped positions
            const err = ch.tryReceive(consumer);
            try testing.expectError(error.Lagged, err);

            // After lag, we should be at the oldest available message (201)
            const val7 = try ch.tryReceive(consumer);
            try testing.expectEqual(@as(u32, 201), val7);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_overflow, .{ runtime, &channel, &consumer }, .{});
    try handle.join(runtime);
}
