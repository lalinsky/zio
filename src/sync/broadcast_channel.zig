// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const yield = @import("../runtime.zig").yield;
const Group = @import("../runtime/group.zig").Group;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const SimpleQueue = @import("../utils/simple_queue.zig").SimpleQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const Barrier = @import("Barrier.zig");
const select = @import("../select.zig").select;
const Waiter = @import("../common.zig").Waiter;

/// Consumer position tracker.
/// This is separate from the generic BroadcastChannel(T) since it only stores positions.
const BroadcastChannelConsumer = struct {
    read_pos: usize = 0,
    prev: ?*BroadcastChannelConsumer = null,
    next: ?*BroadcastChannelConsumer = null,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
};

/// Type-erased broadcast channel implementation that operates on raw bytes.
/// This is the core implementation shared by all BroadcastChannel(T) instances to reduce code size.
const BroadcastChannelImpl = struct {
    buffer: [*]u8,
    elem_size: usize,
    capacity: usize, // number of elements
    write_pos: usize = 0,

    consumers: SimpleQueue(BroadcastChannelConsumer) = .{},
    mutex: std.Thread.Mutex = .{},
    wait_queue: SimpleWaitQueue(WaitNode) = .empty,

    closed: bool = false,

    const Self = @This();

    fn elemPtr(self: *Self, index: usize) [*]u8 {
        return self.buffer + (index * self.elem_size);
    }

    fn subscribe(self: *Self, consumer: *BroadcastChannelConsumer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        consumer.read_pos = self.write_pos;
        self.consumers.push(consumer);
    }

    fn unsubscribe(self: *Self, consumer: *BroadcastChannelConsumer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.consumers.remove(consumer);
    }

    fn receive(self: *Self, consumer: *BroadcastChannelConsumer, elem_ptr: [*]u8) !void {
        var waiter: Waiter = .init();

        while (true) {
            self.mutex.lock();

            const unread = self.write_pos -% consumer.read_pos;
            if (unread > self.capacity) {
                consumer.read_pos = self.write_pos -% self.capacity;
                self.mutex.unlock();
                return error.Lagged;
            }

            if (unread > 0) {
                const src = self.elemPtr(consumer.read_pos % self.capacity);
                @memcpy(elem_ptr[0..self.elem_size], src[0..self.elem_size]);
                consumer.read_pos +%= 1;
                self.mutex.unlock();
                return;
            }

            if (self.closed) {
                self.mutex.unlock();
                return error.Closed;
            }

            self.wait_queue.push(&waiter.wait_node);
            self.mutex.unlock();

            waiter.wait(1, .allow_cancel) catch |err| {
                self.mutex.lock();
                const was_in_queue = self.wait_queue.remove(&waiter.wait_node);
                if (!was_in_queue) {
                    self.mutex.unlock();
                    waiter.wait(1, .no_cancel);
                    self.mutex.lock();
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
        }
    }

    fn tryReceive(self: *Self, consumer: *BroadcastChannelConsumer, elem_ptr: [*]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const unread = self.write_pos -% consumer.read_pos;

        if (unread > self.capacity) {
            consumer.read_pos = self.write_pos -% self.capacity;
            return error.Lagged;
        }

        if (unread == 0) {
            if (self.closed) {
                return error.Closed;
            }
            return error.WouldBlock;
        }

        const src = self.elemPtr(consumer.read_pos % self.capacity);
        @memcpy(elem_ptr[0..self.elem_size], src[0..self.elem_size]);
        consumer.read_pos +%= 1;
    }

    fn send(self: *Self, elem_ptr: [*]const u8) !void {
        self.mutex.lock();

        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }

        const dest = self.elemPtr(self.write_pos % self.capacity);
        @memcpy(dest[0..self.elem_size], elem_ptr[0..self.elem_size]);
        self.write_pos +%= 1;

        var waiters = self.wait_queue.popAll();
        self.mutex.unlock();

        while (waiters.pop()) |node| {
            node.wake();
        }
    }

    fn close(self: *Self) void {
        self.mutex.lock();

        self.closed = true;

        var waiters = self.wait_queue.popAll();
        self.mutex.unlock();

        while (waiters.pop()) |node| {
            node.wake();
        }
    }
};

/// Type-erased async receive operation for BroadcastChannelImpl
const AsyncReceiveImpl = struct {
    channel: *BroadcastChannelImpl,
    consumer: *BroadcastChannelConsumer,

    const RecvSelf = @This();

    pub const WaitContext = struct {
        result_ptr: [*]u8 = undefined,
        result: ?error{ Closed, Lagged }!void = null,
    };

    pub fn asyncWait(self: *const RecvSelf, wait_node: *WaitNode, ctx: *WaitContext, result_ptr: [*]u8) bool {
        ctx.result_ptr = result_ptr;
        ctx.result = null;

        self.channel.mutex.lock();

        const unread = self.channel.write_pos -% self.consumer.read_pos;

        // Check if lagged
        if (unread > self.channel.capacity) {
            self.consumer.read_pos = self.channel.write_pos -% self.channel.capacity;
            ctx.result = error.Lagged;
            self.channel.mutex.unlock();
            return false; // Complete immediately with error
        }

        // Fast path: message available
        if (unread > 0) {
            const src = self.channel.elemPtr(self.consumer.read_pos % self.channel.capacity);
            @memcpy(ctx.result_ptr[0..self.channel.elem_size], src[0..self.channel.elem_size]);
            self.consumer.read_pos +%= 1;
            ctx.result = {};
            self.channel.mutex.unlock();
            return false; // Complete immediately
        }

        // Fast path: channel closed
        if (self.channel.closed) {
            ctx.result = error.Closed;
            self.channel.mutex.unlock();
            return false; // Complete immediately with error
        }

        // Slow path: enqueue and wait
        self.channel.wait_queue.push(wait_node);
        self.channel.mutex.unlock();
        return true;
    }

    pub fn asyncCancelWait(self: *const RecvSelf, wait_node: *WaitNode, ctx: *WaitContext) bool {
        _ = ctx;
        self.channel.mutex.lock();
        const was_in_queue = self.channel.wait_queue.remove(wait_node);
        self.channel.mutex.unlock();
        return was_in_queue;
    }

    pub fn getResult(self: *const RecvSelf, ctx: *WaitContext) error{ Closed, Lagged }!void {
        // Fast path: result already set by asyncWait
        if (ctx.result) |r| {
            return r;
        }

        // Slow path: woken from wait, read from buffer now
        self.channel.mutex.lock();

        const unread = self.channel.write_pos -% self.consumer.read_pos;

        // Check if lagged
        if (unread > self.channel.capacity) {
            self.consumer.read_pos = self.channel.write_pos -% self.channel.capacity;
            self.channel.mutex.unlock();
            return error.Lagged;
        }

        // Message available
        if (unread > 0) {
            const src = self.channel.elemPtr(self.consumer.read_pos % self.channel.capacity);
            @memcpy(ctx.result_ptr[0..self.channel.elem_size], src[0..self.channel.elem_size]);
            self.consumer.read_pos +%= 1;
            self.channel.mutex.unlock();
            return;
        }

        // Channel closed
        if (self.channel.closed) {
            self.channel.mutex.unlock();
            return error.Closed;
        }

        unreachable;
    }
};

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
/// fn broadcaster(ch: *BroadcastChannel(u32)) !void {
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
///     while (ch.receive(&consumer)) |value| {
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
/// var task1 = try runtime.spawn(broadcaster, .{runtime, &channel });
/// var task2 = try runtime.spawn(listener, .{runtime, &channel });
/// var task3 = try runtime.spawn(listener, .{runtime, &channel });
/// ```
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        impl: BroadcastChannelImpl,

        const Self = @This();

        /// Consumer handle for receiving broadcast messages.
        /// Must remain valid while subscribed to the channel.
        pub const Consumer = BroadcastChannelConsumer;

        /// Initialize a broadcast channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{
                .impl = .{
                    .buffer = std.mem.sliceAsBytes(buffer).ptr,
                    .elem_size = @sizeOf(T),
                    .capacity = buffer.len,
                },
            };
        }

        /// Subscribes a consumer to the channel.
        ///
        /// The consumer begins at the current write position and will only receive
        /// messages sent after subscription. Past messages are not available.
        ///
        /// The consumer must remain valid until `unsubscribe()` is called.
        pub fn subscribe(self: *Self, consumer: *Consumer) void {
            self.impl.subscribe(consumer);
        }

        /// Unsubscribes a consumer from the channel.
        pub fn unsubscribe(self: *Self, consumer: *Consumer) void {
            self.impl.unsubscribe(consumer);
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
        pub fn receive(self: *Self, consumer: *Consumer) !T {
            var result: T = undefined;
            try self.impl.receive(consumer, std.mem.asBytes(&result).ptr);
            return result;
        }

        /// Tries to receive a message without blocking.
        ///
        /// Returns immediately with a message if available, otherwise returns an error.
        ///
        /// Returns `error.WouldBlock` if no new messages are available.
        /// Returns `error.Lagged` if the consumer has fallen too far behind.
        /// Returns `error.Closed` if the channel is closed and no more messages are available.
        pub fn tryReceive(self: *Self, consumer: *Consumer) !T {
            var result: T = undefined;
            try self.impl.tryReceive(consumer, std.mem.asBytes(&result).ptr);
            return result;
        }

        /// Broadcasts a message to all consumers.
        ///
        /// This operation never blocks. If the buffer is full, the oldest message is
        /// overwritten. Slow consumers that haven't read the overwritten message will
        /// receive `error.Lagged` on their next receive attempt.
        ///
        /// Returns `error.Closed` if the channel has been closed.
        pub fn send(self: *Self, item: T) !void {
            return self.impl.send(std.mem.asBytes(&item).ptr);
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.Closed`.
        /// Consumers can still drain any buffered messages before receiving `error.Closed`.
        pub fn close(self: *Self) void {
            self.impl.close();
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
        /// const result = try select(.{ .recv = &recv });
        /// switch (result) {
        ///     .recv => |val| std.debug.print("Received: {}\n", .{val}),
        /// }
        /// ```
        pub fn asyncReceive(self: *Self, consumer: *Consumer) AsyncReceive(T) {
            return AsyncReceive(T).init(&self.impl, consumer);
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
/// const result = try select(.{
///     .ch1 = channel.asyncReceive(&consumer1),
///     .ch2 = other_channel.asyncReceive(&consumer2),
/// });
/// ```
pub fn AsyncReceive(comptime T: type) type {
    return struct {
        impl: AsyncReceiveImpl,

        const Self = @This();

        pub const Result = error{ Closed, Lagged }!T;

        pub const WaitContext = struct {
            impl_ctx: AsyncReceiveImpl.WaitContext = .{},
            result: T = undefined,
        };

        fn init(channel: *BroadcastChannelImpl, consumer: *BroadcastChannelConsumer) Self {
            return .{
                .impl = .{
                    .channel = channel,
                    .consumer = consumer,
                },
            };
        }

        /// Register for notification when receive can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *const Self, wait_node: *WaitNode, ctx: *WaitContext) bool {
            return self.impl.asyncWait(wait_node, &ctx.impl_ctx, std.mem.asBytes(&ctx.result).ptr);
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *const Self, wait_node: *WaitNode, ctx: *WaitContext) bool {
            return self.impl.asyncCancelWait(wait_node, &ctx.impl_ctx);
        }

        /// Get the result of the receive operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *const Self, ctx: *WaitContext) Result {
            try self.impl.getResult(&ctx.impl_ctx);
            return ctx.result;
        }
    };
}

test "BroadcastChannel: basic send and receive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(); // Wait for receiver to subscribe
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
        }

        fn receiver(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[3]u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(); // Signal that we're subscribed

            results[0] = try ch.receive(consumer);
            results[1] = try ch.receive(consumer);
            results[2] = try ch.receive(consumer);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var results: [3]u32 = undefined;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.sender, .{ &channel, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer, &results, &barrier });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, results[0]);
    try std.testing.expectEqual(2, results[1]);
    try std.testing.expectEqual(3, results[2]);
}

test "BroadcastChannel: multiple consumers receive same messages" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(4); // 3 receivers + 1 sender

    const TestFn = struct {
        fn sender(ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(); // Wait for all consumers to subscribe
            try ch.send(10);
            try ch.send(20);
            try ch.send(30);
        }

        fn receiver(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, sum: *u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(); // Signal that we're subscribed

            sum.* += try ch.receive(consumer);
            sum.* += try ch.receive(consumer);
            sum.* += try ch.receive(consumer);
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var consumer3 = BroadcastChannel(u32).Consumer{};
    var sum1: u32 = 0;
    var sum2: u32 = 0;
    var sum3: u32 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.sender, .{ &channel, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer1, &sum1, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer2, &sum2, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer3, &sum3, &barrier });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // All consumers should receive all messages
    try std.testing.expectEqual(60, sum1);
    try std.testing.expectEqual(60, sum2);
    try std.testing.expectEqual(60, sum3);
}

test "BroadcastChannel: lagged consumer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_lag(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send more items than buffer capacity without consuming
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            try ch.send(4); // This overwrites item 1
            try ch.send(5); // This overwrites item 2

            // First receive should return Lagged since we missed items 1 and 2
            const err = ch.receive(consumer);
            try std.testing.expectError(error.Lagged, err);

            // After lag, we should be positioned at the oldest available (3)
            const val1 = try ch.receive(consumer);
            try std.testing.expectEqual(3, val1);

            const val2 = try ch.receive(consumer);
            try std.testing.expectEqual(4, val2);

            const val3 = try ch.receive(consumer);
            try std.testing.expectEqual(5, val3);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_lag, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: tryReceive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_try(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // tryReceive on empty channel should return WouldBlock
            const err1 = ch.tryReceive(consumer);
            try std.testing.expectError(error.WouldBlock, err1);

            // Send some items
            try ch.send(42);
            try ch.send(43);

            // tryReceive should succeed
            const val1 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(42, val1);

            const val2 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(43, val2);

            // tryReceive on caught-up consumer should return WouldBlock
            const err2 = ch.tryReceive(consumer);
            try std.testing.expectError(error.WouldBlock, err2);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_try, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: new subscriber doesn't receive old messages" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_new_subscriber(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
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
            const val = try ch.receive(consumer);
            try std.testing.expectEqual(4, val);

            // tryReceive should return WouldBlock (no more messages)
            const err = ch.tryReceive(consumer);
            try std.testing.expectError(error.WouldBlock, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_new_subscriber, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: unsubscribe doesn't affect other consumers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_unsubscribe(ch: *BroadcastChannel(u32), c1: *BroadcastChannel(u32).Consumer, c2: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(c1);
            ch.subscribe(c2);

            try ch.send(1);
            try ch.send(2);

            // Both should receive
            try std.testing.expectEqual(1, try ch.receive(c1));
            try std.testing.expectEqual(1, try ch.receive(c2));

            // Unsubscribe c1
            ch.unsubscribe(c1);

            try ch.send(3);

            // c2 should still receive
            try std.testing.expectEqual(2, try ch.receive(c2));
            try std.testing.expectEqual(3, try ch.receive(c2));
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_unsubscribe, .{ &channel, &consumer1, &consumer2 });
    try handle.join();
}

test "BroadcastChannel: close prevents new sends" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_close(ch: *BroadcastChannel(u32)) !void {
            // Send before closing
            try ch.send(1);

            // Close the channel
            ch.close();

            // Try to send after closing should fail
            const err = ch.send(2);
            try std.testing.expectError(error.Closed, err);
        }
    };

    var handle = try runtime.spawn(TestFn.test_close, .{&channel});
    try handle.join();
}

test "BroadcastChannel: consumers can drain after close" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(); // Wait for receiver to subscribe
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            ch.close();
        }

        fn receiver(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, results: *[4]?u32, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(); // Signal that we're subscribed

            // Should be able to drain all messages
            results[0] = ch.receive(consumer) catch null;
            results[1] = ch.receive(consumer) catch null;
            results[2] = ch.receive(consumer) catch null;
            // This should return Closed
            results[3] = ch.receive(consumer) catch null;
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var results: [4]?u32 = .{ null, null, null, null };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.sender, .{ &channel, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer, &results, &barrier });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, results[0]);
    try std.testing.expectEqual(2, results[1]);
    try std.testing.expectEqual(3, results[2]);
    try std.testing.expectEqual(null, results[3]); // Closed
}

test "BroadcastChannel: waiting consumers wake on close" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn waiter(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, got_closed: *bool, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait(); // Signal that we're subscribed and about to wait

            // Wait for message (channel is empty, so will block)
            const err = ch.receive(consumer);
            if (err) |_| {
                // Shouldn't get a value
            } else |e| {
                if (e == error.Closed) {
                    got_closed.* = true;
                }
            }
        }

        fn closer(ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait(); // Wait for waiter to be ready
            ch.close();
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var got_closed = false;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.waiter, .{ &channel, &consumer, &got_closed, &barrier });
    try group.spawn(runtime, TestFn.closer, .{ &channel, &barrier });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_closed);
}

test "BroadcastChannel: tryReceive returns Closed when channel closed and empty" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_try_closed(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Close the empty channel
            ch.close();

            // tryReceive should return Closed
            const err = ch.tryReceive(consumer);
            try std.testing.expectError(error.Closed, err);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_try_closed, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: asyncReceive with select - basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);
    var barrier = Barrier.init(2);

    const TestFn = struct {
        fn sender(ch: *BroadcastChannel(u32), b: *Barrier) !void {
            _ = try b.wait();
            try yield(); // Let receiver start waiting
            try ch.send(42);
        }

        fn receiver(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer, b: *Barrier) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);
            _ = try b.wait();

            const result = try select(.{ .recv = ch.asyncReceive(consumer) });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(42, try val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.sender, .{ &channel, &barrier });
    try group.spawn(runtime, TestFn.receiver, .{ &channel, &consumer, &barrier });

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "BroadcastChannel: asyncReceive with select - already ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Send first, so receiver finds it ready
            try ch.send(99);

            var recv = ch.asyncReceive(consumer);
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(99, try val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_ready, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: asyncReceive with select - closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            ch.close();

            var recv = ch.asyncReceive(consumer);
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectError(error.Closed, val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_closed, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: asyncReceive with select - lagged consumer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_lagged(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
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
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectError(error.Lagged, val);
                },
            }
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_lagged, .{ &channel, &consumer });
    try handle.join();
}

test "BroadcastChannel: select with multiple broadcast channels" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer1: [5]u32 = undefined;
    var channel1 = BroadcastChannel(u32).init(&buffer1);

    var buffer2: [5]u32 = undefined;
    var channel2 = BroadcastChannel(u32).init(&buffer2);

    const TestFn = struct {
        fn selectTask(ch1: *BroadcastChannel(u32), ch2: *BroadcastChannel(u32), c1: *BroadcastChannel(u32).Consumer, c2: *BroadcastChannel(u32).Consumer, which: *u8) !void {
            ch1.subscribe(c1);
            defer ch1.unsubscribe(c1);
            ch2.subscribe(c2);
            defer ch2.unsubscribe(c2);

            var recv1 = ch1.asyncReceive(c1);
            var recv2 = ch2.asyncReceive(c2);

            const result = try select(.{ .ch1 = &recv1, .ch2 = &recv2 });
            switch (result) {
                .ch1 => |val| {
                    try std.testing.expectEqual(42, try val);
                    which.* = 1;
                },
                .ch2 => |val| {
                    try std.testing.expectEqual(99, try val);
                    which.* = 2;
                },
            }
        }

        fn sender2(ch: *BroadcastChannel(u32)) !void {
            try yield();
            try ch.send(99);
        }
    };

    var consumer1 = BroadcastChannel(u32).Consumer{};
    var consumer2 = BroadcastChannel(u32).Consumer{};
    var which: u8 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(runtime, TestFn.selectTask, .{ &channel1, &channel2, &consumer1, &consumer2, &which });
    try group.spawn(runtime, TestFn.sender2, .{&channel2});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // ch2 should win
    try std.testing.expectEqual(2, which);
}

test "BroadcastChannel: position counter overflow handling" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = BroadcastChannel(u32).init(&buffer);

    const TestFn = struct {
        fn test_overflow(ch: *BroadcastChannel(u32), consumer: *BroadcastChannel(u32).Consumer) !void {
            ch.subscribe(consumer);
            defer ch.unsubscribe(consumer);

            // Simulate near-overflow condition by setting positions close to usize max
            // This tests that wrapping arithmetic works correctly
            const near_max = std.math.maxInt(usize) - 5;

            ch.impl.mutex.lock();
            ch.impl.write_pos = near_max;
            consumer.read_pos = near_max;
            ch.impl.mutex.unlock();

            // Send items that will cause write_pos to wrap around
            try ch.send(100);
            try ch.send(101);
            try ch.send(102);

            // Verify we can receive correctly even after overflow
            const val1 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(100, val1);

            const val2 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(101, val2);

            const val3 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(102, val3);

            // At this point: write_pos has wrapped to (maxInt - 2),
            // consumer.read_pos has wrapped to (maxInt - 2)
            // Send more items - write_pos will continue wrapping
            try ch.send(103);
            try ch.send(104);
            try ch.send(105);

            // Receive them to verify wrapping arithmetic works
            const val4 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(103, val4);

            const val5 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(104, val5);

            const val6 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(105, val6);

            // Now test lag detection with wrapped counters
            // Send more than buffer capacity without consuming
            try ch.send(200);
            try ch.send(201);
            try ch.send(202);
            try ch.send(203); // This overwrites oldest (200)

            // Next receive should detect lag correctly even with wrapped positions
            const err = ch.tryReceive(consumer);
            try std.testing.expectError(error.Lagged, err);

            // After lag, we should be at the oldest available message (201)
            const val7 = try ch.tryReceive(consumer);
            try std.testing.expectEqual(201, val7);
        }
    };

    var consumer = BroadcastChannel(u32).Consumer{};
    var handle = try runtime.spawn(TestFn.test_overflow, .{ &channel, &consumer });
    try handle.join();
}
