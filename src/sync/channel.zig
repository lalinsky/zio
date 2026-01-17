// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const select = @import("../select.zig").select;
const Waiter = @import("common.zig").Waiter;

/// Specifies how a channel should be closed.
pub const CloseMode = enum {
    /// Close gracefully - allows receivers to drain buffered values before receiving error.ChannelClosed
    graceful,
    /// Close immediately - clears all buffered items so receivers get error.ChannelClosed right away
    immediate,
};

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
/// var task1 = try runtime.spawn(producer, .{runtime, &channel });
/// var task2 = try runtime.spawn(consumer, .{runtime, &channel });
/// ```
pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        mutex: std.Thread.Mutex = .{},
        receiver_queue: SimpleWaitQueue(WaitNode) = .empty,
        sender_queue: SimpleWaitQueue(WaitNode) = .empty,

        closed: bool = false,

        const Self = @This();

        /// Initializes a channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer };
        }

        /// Checks if the channel is empty.
        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count == 0;
        }

        /// Checks if the channel is full.
        pub fn isFull(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
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
            const task = rt.getCurrentTask();
            const executor = task.getExecutor();

            // Stack-allocated waiter - separates operation wait node from task wait node
            var waiter: Waiter = .init(&task.awaitable);

            while (true) {
                self.mutex.lock();

                // Check if closed and empty
                if (self.closed and self.count == 0) {
                    self.mutex.unlock();
                    return error.ChannelClosed;
                }

                // Fast path: item available
                if (self.count > 0) {
                    const item = self.buffer[self.head];
                    self.head = (self.head + 1) % self.buffer.len;
                    self.count -= 1;

                    // Wake one sender if any
                    const sender_node = self.sender_queue.pop();
                    self.mutex.unlock();
                    if (sender_node) |node| {
                        node.wake();
                    }
                    return item;
                }

                // Slow path: empty, need to wait
                task.state.store(.preparing_to_wait, .release);
                self.receiver_queue.push(&waiter.wait_node);
                self.mutex.unlock();

                // Yield with cancellation support
                executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
                    // Cancelled - try to remove from queue
                    self.mutex.lock();
                    const was_in_queue = self.receiver_queue.remove(&waiter.wait_node);
                    if (!was_in_queue) {
                        // We were already removed by a sender who will wake us.
                        // Since we're being cancelled and won't consume the item,
                        // wake another receiver to consume it instead.
                        const next_receiver = self.receiver_queue.pop();
                        self.mutex.unlock();
                        if (next_receiver) |node| {
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

        /// Tries to receive a value without blocking.
        ///
        /// Returns immediately with a value if available, otherwise returns an error.
        ///
        /// Returns `error.ChannelEmpty` if the channel is empty.
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        pub fn tryReceive(self: *Self) !T {
            self.mutex.lock();

            if (self.count == 0) {
                const is_closed = self.closed;
                self.mutex.unlock();
                return if (is_closed) error.ChannelClosed else error.ChannelEmpty;
            }

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            // Pop sender node while holding lock, wake after unlock
            const sender_node = self.sender_queue.pop();
            self.mutex.unlock();
            if (sender_node) |node| {
                node.wake();
            }

            return item;
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, rt: *Runtime, item: T) !void {
            const task = rt.getCurrentTask();
            const executor = task.getExecutor();

            // Stack-allocated waiter - separates operation wait node from task wait node
            var waiter: Waiter = .init(&task.awaitable);

            while (true) {
                self.mutex.lock();

                if (self.closed) {
                    self.mutex.unlock();
                    return error.ChannelClosed;
                }

                // Fast path: space available
                if (self.count < self.buffer.len) {
                    self.buffer[self.tail] = item;
                    self.tail = (self.tail + 1) % self.buffer.len;
                    self.count += 1;

                    // Wake one receiver if any
                    const receiver_node = self.receiver_queue.pop();
                    self.mutex.unlock();
                    if (receiver_node) |node| {
                        node.wake();
                    }
                    return;
                }

                // Slow path: full, need to wait
                task.state.store(.preparing_to_wait, .release);
                self.sender_queue.push(&waiter.wait_node);
                self.mutex.unlock();

                // Yield with cancellation support
                executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
                    // Cancelled - try to remove from queue
                    self.mutex.lock();
                    const was_in_queue = self.sender_queue.remove(&waiter.wait_node);
                    if (!was_in_queue) {
                        // We were already removed by a receiver who will wake us.
                        // Since we're being cancelled and won't send the item,
                        // wake another sender to use the buffer slot instead.
                        const next_sender = self.sender_queue.pop();
                        self.mutex.unlock();
                        if (next_sender) |node| {
                            node.wake();
                        }
                    } else {
                        self.mutex.unlock();
                    }
                    return err;
                };

                // Woken up, loop to check condition and try again
            }
        }

        /// Tries to send a value without blocking.
        ///
        /// Returns immediately with success if space is available, otherwise returns an error.
        ///
        /// Returns `error.ChannelFull` if the channel is full.
        /// Returns `error.ChannelClosed` if the channel is closed.
        pub fn trySend(self: *Self, item: T) !void {
            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return error.ChannelClosed;
            }

            if (self.count == self.buffer.len) {
                self.mutex.unlock();
                return error.ChannelFull;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            // Pop receiver node while holding lock, wake after unlock
            const receiver_node = self.receiver_queue.pop();
            self.mutex.unlock();
            if (receiver_node) |node| {
                node.wake();
            }
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.ChannelClosed`.
        /// Receive operations can still drain any buffered values before returning
        /// `error.ChannelClosed`.
        ///
        /// Use `CloseMode.graceful` to allow receivers to drain buffered values.
        /// Use `CloseMode.immediate` to clear all buffered items immediately,
        /// causing receivers to get `error.ChannelClosed` right away.
        pub fn close(self: *Self, mode: CloseMode) void {
            self.mutex.lock();

            self.closed = true;

            if (mode == .immediate) {
                // Clear the buffer
                self.head = 0;
                self.tail = 0;
                self.count = 0;
            }

            // Swap out the wait queues while holding the lock
            var receivers = self.receiver_queue.popAll();
            var senders = self.sender_queue.popAll();

            self.mutex.unlock();

            // Wake all receivers so they can see the channel is closed
            while (receivers.pop()) |node| {
                node.wake();
            }

            // Wake all senders so they can see the channel is closed
            while (senders.pop()) |node| {
                node.wake();
            }
        }

        /// Creates an AsyncReceive operation for use with select().
        ///
        /// Returns a single-shot future that will receive one value from the channel.
        /// Create a new AsyncReceive for each select() operation.
        ///
        /// Example:
        /// ```zig
        /// var recv = channel.asyncReceive();
        /// const result = try select(rt, .{ .recv = &recv });
        /// switch (result) {
        ///     .recv => |val| std.debug.print("Received: {}\n", .{val}),
        /// }
        /// ```
        pub fn asyncReceive(self: *Self) AsyncReceive(T) {
            return AsyncReceive(T).init(self);
        }

        /// Creates an AsyncSend operation for use with select().
        ///
        /// Returns a single-shot future that will send the given value to the channel.
        /// Create a new AsyncSend for each select() operation.
        ///
        /// Example:
        /// ```zig
        /// var send = channel.asyncSend(42);
        /// const result = try select(rt, .{ .send = &send });
        /// ```
        pub fn asyncSend(self: *Self, item: T) AsyncSend(T) {
            return AsyncSend(T).init(self, item);
        }
    };
}

/// AsyncReceive represents a pending receive operation on a Channel.
/// This type implements the Future protocol and can be used with select().
///
/// Each AsyncReceive is single-shot - it represents one receive operation.
/// Create a new AsyncReceive for each select() operation.
///
/// Example:
/// ```zig
/// var recv1 = channel1.asyncReceive();
/// var recv2 = channel2.asyncReceive();
/// const result = try select(rt, .{ .ch1 = &recv1, .ch2 = &recv2 });
/// switch (result) {
///     .ch1 => |val| try testing.expectEqual(@as(u32, 42), val),
///     .ch2 => |val| try testing.expectEqual(@as(u32, 99), val),
/// }
/// ```
pub fn AsyncReceive(comptime T: type) type {
    return struct {
        channel_wait_node: WaitNode,
        parent_wait_node: ?*WaitNode = null,
        channel: *Channel(T),
        result: ?Result = null,

        const Self = @This();

        pub const Result = error{ChannelClosed}!T;

        const wait_node_vtable = WaitNode.VTable{
            .wake = waitNodeWake,
        };

        fn init(channel: *Channel(T)) Self {
            return .{
                .channel_wait_node = .{
                    .vtable = &wait_node_vtable,
                },
                .channel = channel,
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

            if (self.channel.count > 0) {
                // Take item from buffer
                const item = self.channel.buffer[self.channel.head];
                self.channel.head = (self.channel.head + 1) % self.channel.buffer.len;
                self.channel.count -= 1;

                // Wake one sender if any
                const sender_node = self.channel.sender_queue.pop();
                self.channel.mutex.unlock();

                self.result = item;
                if (sender_node) |node| {
                    node.wake();
                }
            } else if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
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

            // Fast path: item available
            if (self.channel.count > 0) {
                const item = self.channel.buffer[self.channel.head];
                self.channel.head = (self.channel.head + 1) % self.channel.buffer.len;
                self.channel.count -= 1;

                // Wake one sender if any
                const sender_node = self.channel.sender_queue.pop();
                self.channel.mutex.unlock();

                self.result = item;
                if (sender_node) |node| {
                    node.wake();
                }
                return false; // Already ready
            }

            // Fast path: channel closed
            if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
                return false; // Already ready (with error)
            }

            // Slow path: enqueue and wait
            self.channel.receiver_queue.push(&self.channel_wait_node);
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

            const was_in_queue = self.channel.receiver_queue.remove(&self.channel_wait_node);
            if (!was_in_queue) {
                // We were already removed by a sender who will wake us.
                // Since we're being cancelled and won't consume the item,
                // wake another receiver to consume it instead.
                const next_receiver = self.channel.receiver_queue.pop();
                self.channel.mutex.unlock();
                if (next_receiver) |node| {
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

/// AsyncSend represents a pending send operation on a Channel.
/// This type implements the Future protocol and can be used with select().
///
/// Each AsyncSend is single-shot - it represents one send operation with a specific value.
/// Create a new AsyncSend for each select() operation.
///
/// Example:
/// ```zig
/// var send1 = channel1.asyncSend(42);
/// var send2 = channel2.asyncSend(99);
/// const result = try select(rt, .{ .ch1 = &send1, .ch2 = &send2 });
/// ```
pub fn AsyncSend(comptime T: type) type {
    return struct {
        channel_wait_node: WaitNode,
        parent_wait_node: ?*WaitNode = null,
        channel: *Channel(T),
        item: T,
        result: ?Result = null,

        const Self = @This();

        pub const Result = error{ChannelClosed}!void;

        const wait_node_vtable = WaitNode.VTable{
            .wake = waitNodeWake,
        };

        fn init(channel: *Channel(T), item: T) Self {
            return .{
                .channel_wait_node = .{
                    .vtable = &wait_node_vtable,
                },
                .channel = channel,
                .item = item,
            };
        }

        fn waitNodeWake(wait_node: *WaitNode) void {
            const self: *Self = @fieldParentPtr("channel_wait_node", wait_node);

            // Perform the send operation under lock
            self.channel.mutex.lock();

            // Read and clear parent_wait_node while holding the lock to prevent
            // race with cancellation (which could free/reuse the parent)
            const parent = self.parent_wait_node;
            self.parent_wait_node = null;

            if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
            } else if (self.channel.count < self.channel.buffer.len) {
                // Space available - perform send
                self.channel.buffer[self.channel.tail] = self.item;
                self.channel.tail = (self.channel.tail + 1) % self.channel.buffer.len;
                self.channel.count += 1;

                // Wake one receiver if any
                const receiver_node = self.channel.receiver_queue.pop();
                self.channel.mutex.unlock();

                self.result = {};
                if (receiver_node) |node| {
                    node.wake();
                }
            } else {
                // Should never happen - woken but no space and not closed
                self.channel.mutex.unlock();
                unreachable;
            }

            // Wake the parent (SelectWaiter or task wait node)
            if (parent) |p| {
                p.wake();
            }
        }

        /// Register for notification when send can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.parent_wait_node = wait_node;

            self.channel.mutex.lock();

            // Fast path: channel closed
            if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
                return false; // Already ready (with error)
            }

            // Fast path: space available
            if (self.channel.count < self.channel.buffer.len) {
                self.channel.buffer[self.channel.tail] = self.item;
                self.channel.tail = (self.channel.tail + 1) % self.channel.buffer.len;
                self.channel.count += 1;

                // Wake one receiver if any
                const receiver_node = self.channel.receiver_queue.pop();
                self.channel.mutex.unlock();

                self.result = {};
                if (receiver_node) |node| {
                    node.wake();
                }
                return false; // Already ready
            }

            // Slow path: enqueue and wait
            self.channel.sender_queue.push(&self.channel_wait_node);
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

            const was_in_queue = self.channel.sender_queue.remove(&self.channel_wait_node);
            if (!was_in_queue) {
                // We were already removed by a receiver who will wake us.
                // Since we're being cancelled and won't send the item,
                // wake another sender to use the buffer slot instead.
                const next_sender = self.channel.sender_queue.pop();
                self.channel.mutex.unlock();
                if (next_sender) |node| {
                    node.wake();
                }
            } else {
                self.channel.mutex.unlock();
            }
        }

        /// Get the result of the send operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *Self) Result {
            return self.result.?;
        }
    };
}

test "Channel: basic send and receive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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
    var producer_task = try runtime.spawn(TestFn.producer, .{ runtime, &channel });
    defer producer_task.cancel(runtime);
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &results });
    defer consumer_task.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), results[0]);
    try testing.expectEqual(@as(u32, 2), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "Channel: trySend and tryReceive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testTry(rt: *Runtime, ch: *Channel(u32)) !void {
            _ = rt;
            // tryReceive on empty channel should fail
            const empty_err = ch.tryReceive();
            try testing.expectError(error.ChannelEmpty, empty_err);

            // trySend should succeed
            try ch.trySend(1);
            try ch.trySend(2);

            // trySend on full channel should fail
            const full_err = ch.trySend(3);
            try testing.expectError(error.ChannelFull, full_err);

            // tryReceive should succeed
            const val1 = try ch.tryReceive();
            try testing.expectEqual(@as(u32, 1), val1);

            const val2 = try ch.tryReceive();
            try testing.expectEqual(@as(u32, 2), val2);

            // tryReceive on empty channel should fail again
            const empty_err2 = ch.tryReceive();
            try testing.expectError(error.ChannelEmpty, empty_err2);
        }
    };

    var handle = try runtime.spawn(TestFn.testTry, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: blocking behavior when empty" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &result });
    defer consumer_task.cancel(runtime);
    var producer_task = try runtime.spawn(TestFn.producer, .{ runtime, &channel });
    defer producer_task.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(u32, 42), result);
}

test "Channel: blocking behavior when full" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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
    var producer_task = try runtime.spawn(TestFn.producer, .{ runtime, &channel, &count });
    defer producer_task.cancel(runtime);
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ runtime, &channel });
    defer consumer_task.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(u32, 1), count);
}

test "Channel: multiple producers and consumers" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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
    var producer1 = try runtime.spawn(TestFn.producer, .{ runtime, &channel, @as(u32, 0) });
    defer producer1.cancel(runtime);
    var producer2 = try runtime.spawn(TestFn.producer, .{ runtime, &channel, @as(u32, 100) });
    defer producer2.cancel(runtime);
    var consumer1 = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &sum });
    defer consumer1.cancel(runtime);
    var consumer2 = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &sum });
    defer consumer2.cancel(runtime);

    try runtime.run();

    // Sum should be: (0+1+2+3+4) + (100+101+102+103+104) = 10 + 510 = 520
    try testing.expectEqual(@as(u32, 520), sum);
}

test "Channel: close graceful" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            ch.close(.graceful); // Graceful close - items remain
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), results: *[3]?u32) !void {
            try rt.yield(); // Let producer finish
            results[0] = ch.receive(rt) catch null;
            results[1] = ch.receive(rt) catch null;
            results[2] = ch.receive(rt) catch null; // Should fail with ChannelClosed
        }
    };

    var results: [3]?u32 = .{ null, null, null };
    var producer_task = try runtime.spawn(TestFn.producer, .{ runtime, &channel });
    defer producer_task.cancel(runtime);
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &results });
    defer consumer_task.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(?u32, 1), results[0]);
    try testing.expectEqual(@as(?u32, 2), results[1]);
    try testing.expectEqual(@as(?u32, null), results[2]); // Closed, no more items
}

test "Channel: close immediate" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 1);
            try ch.send(rt, 2);
            try ch.send(rt, 3);
            ch.close(.immediate); // Immediate close - clears all items
        }

        fn consumer(rt: *Runtime, ch: *Channel(u32), result: *?u32) !void {
            try rt.yield(); // Let producer finish
            result.* = ch.receive(rt) catch null; // Should fail immediately
        }
    };

    var result: ?u32 = null;
    var producer_task = try runtime.spawn(TestFn.producer, .{ runtime, &channel });
    defer producer_task.cancel(runtime);
    var consumer_task = try runtime.spawn(TestFn.consumer, .{ runtime, &channel, &result });
    defer consumer_task.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(?u32, null), result);
}

test "Channel: send on closed channel" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(rt: *Runtime, ch: *Channel(u32)) !void {
            ch.close(.graceful);

            const put_err = ch.send(rt, 1);
            try testing.expectError(error.ChannelClosed, put_err);

            const tryput_err = ch.trySend(2);
            try testing.expectError(error.ChannelClosed, tryput_err);
        }
    };

    var handle = try runtime.spawn(TestFn.testClosed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: ring buffer wrapping" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
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

    var handle = try runtime.spawn(TestFn.testWrap, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncReceive with select - basic" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield(); // Let receiver start waiting
            try ch.send(rt, 42);
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32)) !void {
            var recv = ch.asyncReceive();
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectEqual(@as(u32, 42), try val);
                },
            }
        }
    };

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel });
    defer sender_task.cancel(runtime);
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel });
    defer receiver_task.cancel(runtime);

    try runtime.run();
}

test "Channel: asyncReceive with select - already ready" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(rt: *Runtime, ch: *Channel(u32)) !void {
            // Send first, so receiver finds it ready
            try ch.send(rt, 99);

            var recv = ch.asyncReceive();
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectEqual(@as(u32, 99), try val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncReceive with select - closed channel" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(rt: *Runtime, ch: *Channel(u32)) !void {
            ch.close(.graceful);

            var recv = ch.asyncReceive();
            const result = try select(rt, .{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try testing.expectError(error.ChannelClosed, val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncSend with select - basic" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield(); // Let receiver start
            var send = ch.asyncSend(42);
            const result = try select(rt, .{ .send = &send });
            switch (result) {
                .send => |res| {
                    try res;
                },
            }
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
            try rt.yield();
            const val = try ch.receive(rt);
            try testing.expectEqual(@as(u32, 42), val);
        }
    };

    var sender_task = try runtime.spawn(TestFn.sender, .{ runtime, &channel });
    defer sender_task.cancel(runtime);
    var receiver_task = try runtime.spawn(TestFn.receiver, .{ runtime, &channel });
    defer receiver_task.cancel(runtime);

    try runtime.run();
}

test "Channel: asyncSend with select - already ready" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(rt: *Runtime, ch: *Channel(u32)) !void {
            // Channel has space, send should complete immediately
            var send = ch.asyncSend(123);
            const result = try select(rt, .{ .send = &send });
            switch (result) {
                .send => |res| {
                    try res;
                },
            }

            // Verify item was sent
            const val = try ch.receive(rt);
            try testing.expectEqual(@as(u32, 123), val);
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncSend with select - closed channel" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(rt: *Runtime, ch: *Channel(u32)) !void {
            ch.close(.graceful);

            var send = ch.asyncSend(42);
            const result = try select(rt, .{ .send = &send });
            switch (result) {
                .send => |res| {
                    try testing.expectError(error.ChannelClosed, res);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: select on both send and receive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer1: [5]u32 = undefined;
    var channel1 = Channel(u32).init(&buffer1);

    // Make channel2 full so send blocks
    var buffer2: [2]u32 = undefined;
    var channel2 = Channel(u32).init(&buffer2);

    const TestFn = struct {
        fn testMain(rt: *Runtime, ch1: *Channel(u32), ch2: *Channel(u32)) !void {
            // Fill channel2 so send blocks
            try ch2.send(rt, 1);
            try ch2.send(rt, 2);

            var which: u8 = 0;
            var select_task = try rt.spawn(selectTask, .{ rt, ch1, ch2, &which });
            defer select_task.cancel(rt);
            var sender_task = try rt.spawn(sender, .{ rt, ch1 });
            defer sender_task.cancel(rt);

            _ = try select_task.join(rt);
            _ = try sender_task.join(rt);

            // Receive should win (sender provides value)
            try testing.expectEqual(@as(u8, 1), which);
        }

        fn selectTask(rt: *Runtime, ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv = ch1.asyncReceive();
            var send = ch2.asyncSend(99);

            const result = try select(rt, .{ .recv = &recv, .send = &send });
            switch (result) {
                .recv => |val| {
                    try testing.expectEqual(@as(u32, 42), try val);
                    which.* = 1;
                },
                .send => |res| {
                    try res;
                    which.* = 2;
                },
            }
        }

        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
            try ch.send(rt, 42);
        }
    };

    var handle = try runtime.spawn(TestFn.testMain, .{ runtime, &channel1, &channel2 });
    try handle.join(runtime);
}

test "Channel: select with multiple receivers" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var buffer1: [5]u32 = undefined;
    var channel1 = Channel(u32).init(&buffer1);

    var buffer2: [5]u32 = undefined;
    var channel2 = Channel(u32).init(&buffer2);

    const TestFn = struct {
        fn selectTask(rt: *Runtime, ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv1 = ch1.asyncReceive();
            var recv2 = ch2.asyncReceive();

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

        fn sender2(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
            try ch.send(rt, 99);
        }
    };

    var which: u8 = 0;
    var select_task = try runtime.spawn(TestFn.selectTask, .{ runtime, &channel1, &channel2, &which });
    defer select_task.cancel(runtime);
    var sender_task = try runtime.spawn(TestFn.sender2, .{ runtime, &channel2 });
    defer sender_task.cancel(runtime);

    try runtime.run();

    // ch2 should win
    try testing.expectEqual(@as(u8, 2), which);
}
