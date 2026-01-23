// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const select = @import("../select.zig").select;
const Waiter = @import("../common.zig").Waiter;

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

        /// Number of items available for immediate consumption (not reserved for woken receivers).
        /// Invariant: items_available <= count
        items_available: usize = 0,

        /// Number of slots available for immediate send (not reserved for woken senders).
        /// Invariant: slots_available <= buffer.len - count
        slots_available: usize,

        const Self = @This();

        /// Initializes a channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        pub fn init(buffer: []T) Self {
            std.debug.assert(buffer.len > 0);
            return .{ .buffer = buffer, .slots_available = buffer.len };
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
            var waiter: Waiter = .init(rt);

            self.mutex.lock();

            // Check if closed and empty
            if (self.closed and self.count == 0) {
                self.mutex.unlock();
                return error.ChannelClosed;
            }

            // Fast path: unreserved items available
            if (self.items_available > 0) {
                self.items_available -= 1;
                return self.takeItem();
            }

            // Slow path: need to wait
            waiter.wait_node.userdata = 0; // No reservation yet
            self.receiver_queue.push(&waiter.wait_node);
            self.mutex.unlock();

            waiter.wait(1, .allow_cancel) catch |err| {
                self.mutex.lock();
                const was_in_queue = self.receiver_queue.remove(&waiter.wait_node);
                if (!was_in_queue) {
                    const has_reservation = waiter.wait_node.userdata == 1;
                    self.mutex.unlock();
                    waiter.wait(1, .no_cancel);

                    if (has_reservation) {
                        // Transfer or release reservation
                        self.mutex.lock();
                        if (self.receiver_queue.pop()) |node| {
                            node.userdata = 1;
                            self.mutex.unlock();
                            node.wake();
                        } else {
                            self.items_available += 1; // Release reservation
                            self.mutex.unlock();
                        }
                    }
                } else {
                    self.mutex.unlock();
                }
                return err;
            };

            // Woken up
            self.mutex.lock();
            const has_reservation = waiter.wait_node.userdata == 1;

            if (has_reservation) {
                // Sender reserved an item for us, just take it
                return self.takeItem();
            }

            // Woken by close - try to get an available item
            if (self.items_available > 0) {
                self.items_available -= 1;
                return self.takeItem();
            }

            std.debug.assert(self.closed);
            self.mutex.unlock();
            return error.ChannelClosed;
        }

        /// Takes an item from the buffer. Must be called with mutex held.
        /// Unlocks the mutex before returning.
        fn takeItem(self: *Self) T {
            std.debug.assert(self.count > 0);
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            if (self.sender_queue.pop()) |node| {
                // Slot reserved for this sender (don't increment slots_available)
                node.userdata = 1;
                self.mutex.unlock();
                node.wake();
            } else {
                // No sender waiting, slot is available for fast-path
                self.slots_available += 1;
                self.mutex.unlock();
            }
            return item;
        }

        /// Tries to receive a value without blocking.
        ///
        /// Returns immediately with a value if available, otherwise returns an error.
        ///
        /// Returns `error.ChannelEmpty` if the channel is empty.
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        pub fn tryReceive(self: *Self) !T {
            self.mutex.lock();

            if (self.items_available == 0) {
                const is_closed = self.closed and self.count == 0;
                self.mutex.unlock();
                return if (is_closed) error.ChannelClosed else error.ChannelEmpty;
            }

            self.items_available -= 1;
            return self.takeItem();
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, rt: *Runtime, item: T) !void {
            var waiter: Waiter = .init(rt);

            self.mutex.lock();

            if (self.closed) {
                self.mutex.unlock();
                return error.ChannelClosed;
            }

            // Fast path: unreserved slots available
            if (self.slots_available > 0) {
                self.slots_available -= 1;
                return self.putItem(item);
            }

            // Slow path: need to wait
            waiter.wait_node.userdata = 0; // No reservation yet
            self.sender_queue.push(&waiter.wait_node);
            self.mutex.unlock();

            waiter.wait(1, .allow_cancel) catch |err| {
                self.mutex.lock();
                const was_in_queue = self.sender_queue.remove(&waiter.wait_node);
                if (!was_in_queue) {
                    const has_reservation = waiter.wait_node.userdata == 1;
                    self.mutex.unlock();
                    waiter.wait(1, .no_cancel);

                    if (has_reservation) {
                        // Transfer or release reservation
                        self.mutex.lock();
                        if (self.sender_queue.pop()) |node| {
                            node.userdata = 1;
                            self.mutex.unlock();
                            node.wake();
                        } else {
                            self.slots_available += 1; // Release reservation
                            self.mutex.unlock();
                        }
                    }
                } else {
                    self.mutex.unlock();
                }
                return err;
            };

            // Woken up
            self.mutex.lock();
            const has_reservation = waiter.wait_node.userdata == 1;

            if (has_reservation) {
                // Receiver reserved a slot for us, just put the item
                return self.putItem(item);
            }

            // Woken by close
            std.debug.assert(self.closed);
            self.mutex.unlock();
            return error.ChannelClosed;
        }

        /// Puts an item into the buffer. Must be called with mutex held.
        /// Unlocks the mutex before returning.
        fn putItem(self: *Self, item: T) void {
            std.debug.assert(self.count < self.buffer.len);
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;

            if (self.receiver_queue.pop()) |node| {
                // Item reserved for this receiver (don't increment items_available)
                node.userdata = 1;
                self.mutex.unlock();
                node.wake();
            } else {
                // No receiver waiting, item is available for fast-path
                self.items_available += 1;
                self.mutex.unlock();
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

            if (self.slots_available == 0) {
                self.mutex.unlock();
                return error.ChannelFull;
            }

            self.slots_available -= 1;
            self.putItem(item);
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
                self.head = 0;
                self.tail = 0;
                self.count = 0;
                self.items_available = 0;
                self.slots_available = self.buffer.len;
            }

            var receivers = self.receiver_queue.popAll();
            var senders = self.sender_queue.popAll();

            self.mutex.unlock();

            // Wake all receivers (no reservation - userdata = 0)
            while (receivers.pop()) |node| {
                node.userdata = 0;
                node.wake();
            }

            // Wake all senders (no reservation - userdata = 0)
            while (senders.pop()) |node| {
                node.userdata = 0;
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
///     .ch1 => |val| try std.testing.expectEqual(42, val),
///     .ch2 => |val| try std.testing.expectEqual(99, val),
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

            self.channel.mutex.lock();

            // Read and clear parent_wait_node while holding the lock to prevent
            // race with cancellation (which could free/reuse the parent)
            const parent = self.parent_wait_node;
            self.parent_wait_node = null;

            self.channel.mutex.unlock();

            // Wake the parent (SelectWaiter or task wait node)
            // Item consumption is deferred to getResult() so we don't consume
            // before knowing if we won the select race
            if (parent) |p| {
                p.wake();
            }
        }

        /// Register for notification when receive can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.parent_wait_node = wait_node;

            self.channel.mutex.lock();

            // Fast path: unreserved items available
            if (self.channel.items_available > 0) {
                self.channel.items_available -= 1;
                self.result = self.channel.takeItem();
                return false;
            }

            // Fast path: channel closed and empty
            if (self.channel.closed and self.channel.count == 0) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
                return false;
            }

            // Slow path: enqueue and wait
            self.channel_wait_node.userdata = 0;
            self.channel.receiver_queue.push(&self.channel_wait_node);
            self.channel.mutex.unlock();
            return true;
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.channel.mutex.lock();

            if (self.parent_wait_node) |parent| {
                std.debug.assert(parent == wait_node);
                self.parent_wait_node = null;
            }

            const was_in_queue = self.channel.receiver_queue.remove(&self.channel_wait_node);
            if (!was_in_queue) {
                const has_reservation = self.channel_wait_node.userdata == 1;
                if (has_reservation) {
                    if (self.channel.receiver_queue.pop()) |node| {
                        node.userdata = 1;
                        self.channel.mutex.unlock();
                        node.wake();
                    } else {
                        self.channel.items_available += 1;
                        self.channel.mutex.unlock();
                    }
                } else {
                    self.channel.mutex.unlock();
                }
            } else {
                self.channel.mutex.unlock();
            }
            return was_in_queue;
        }

        /// Get the result of the receive operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *Self) Result {
            if (self.result) |r| {
                return r;
            }

            self.channel.mutex.lock();

            const has_reservation = self.channel_wait_node.userdata == 1;

            if (has_reservation) {
                // Sender reserved for us, just take
                return self.channel.takeItem();
            }

            // Woken by close - try to get available item
            if (self.channel.items_available > 0) {
                self.channel.items_available -= 1;
                return self.channel.takeItem();
            }

            std.debug.assert(self.channel.closed);
            self.channel.mutex.unlock();
            return error.ChannelClosed;
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

            self.channel.mutex.lock();

            // Read and clear parent_wait_node while holding the lock to prevent
            // race with cancellation (which could free/reuse the parent)
            const parent = self.parent_wait_node;
            self.parent_wait_node = null;

            self.channel.mutex.unlock();

            // Wake the parent (SelectWaiter or task wait node)
            // Item sending is deferred to getResult() so we don't send
            // before knowing if we won the select race
            if (parent) |p| {
                p.wake();
            }
        }

        /// Register for notification when send can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.parent_wait_node = wait_node;

            self.channel.mutex.lock();

            if (self.channel.closed) {
                self.channel.mutex.unlock();
                self.result = error.ChannelClosed;
                return false;
            }

            // Fast path: unreserved slots available
            if (self.channel.slots_available > 0) {
                self.channel.slots_available -= 1;
                self.channel.putItem(self.item);
                self.result = {};
                return false;
            }

            // Slow path: enqueue and wait
            self.channel_wait_node.userdata = 0;
            self.channel.sender_queue.push(&self.channel_wait_node);
            self.channel.mutex.unlock();
            return true;
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *Self, _: *Runtime, wait_node: *WaitNode) bool {
            self.channel.mutex.lock();

            if (self.parent_wait_node) |parent| {
                std.debug.assert(parent == wait_node);
                self.parent_wait_node = null;
            }

            const was_in_queue = self.channel.sender_queue.remove(&self.channel_wait_node);
            if (!was_in_queue) {
                const has_reservation = self.channel_wait_node.userdata == 1;
                if (has_reservation) {
                    if (self.channel.sender_queue.pop()) |node| {
                        node.userdata = 1;
                        self.channel.mutex.unlock();
                        node.wake();
                    } else {
                        self.channel.slots_available += 1;
                        self.channel.mutex.unlock();
                    }
                } else {
                    self.channel.mutex.unlock();
                }
            } else {
                self.channel.mutex.unlock();
            }
            return was_in_queue;
        }

        /// Get the result of the send operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *Self) Result {
            if (self.result) |r| {
                return r;
            }

            self.channel.mutex.lock();

            const has_reservation = self.channel_wait_node.userdata == 1;

            if (has_reservation) {
                // Receiver reserved a slot for us, just put the item
                self.channel.putItem(self.item);
                return {};
            }

            // Woken by close
            std.debug.assert(self.channel.closed);
            self.channel.mutex.unlock();
            return error.ChannelClosed;
        }
    };
}

test "Channel: basic send and receive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &results });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, results[0]);
    try std.testing.expectEqual(2, results[1]);
    try std.testing.expectEqual(3, results[2]);
}

test "Channel: trySend and tryReceive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testTry(rt: *Runtime, ch: *Channel(u32)) !void {
            _ = rt;
            // tryReceive on empty channel should fail
            const empty_err = ch.tryReceive();
            try std.testing.expectError(error.ChannelEmpty, empty_err);

            // trySend should succeed
            try ch.trySend(1);
            try ch.trySend(2);

            // trySend on full channel should fail
            const full_err = ch.trySend(3);
            try std.testing.expectError(error.ChannelFull, full_err);

            // tryReceive should succeed
            const val1 = try ch.tryReceive();
            try std.testing.expectEqual(1, val1);

            const val2 = try ch.tryReceive();
            try std.testing.expectEqual(2, val2);

            // tryReceive on empty channel should fail again
            const empty_err2 = ch.tryReceive();
            try std.testing.expectError(error.ChannelEmpty, empty_err2);
        }
    };

    var handle = try runtime.spawn(TestFn.testTry, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: blocking behavior when empty" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &result });
    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(42, result);
}

test "Channel: blocking behavior when full" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel, &count });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, count);
}

test "Channel: multiple producers and consumers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel, 0 });
    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel, 100 });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &sum });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &sum });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // Sum should be: (0+1+2+3+4) + (100+101+102+103+104) = 10 + 510 = 520
    try std.testing.expectEqual(520, sum);
}

test "Channel: close graceful" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &results });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, results[0]);
    try std.testing.expectEqual(2, results[1]);
    try std.testing.expectEqual(null, results[2]); // Closed, no more items
}

test "Channel: close immediate" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.producer, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.consumer, .{ runtime, &channel, &result });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(null, result);
}

test "Channel: send on closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(rt: *Runtime, ch: *Channel(u32)) !void {
            ch.close(.graceful);

            const put_err = ch.send(rt, 1);
            try std.testing.expectError(error.ChannelClosed, put_err);

            const tryput_err = ch.trySend(2);
            try std.testing.expectError(error.ChannelClosed, tryput_err);
        }
    };

    var handle = try runtime.spawn(TestFn.testClosed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: ring buffer wrapping" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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

            try std.testing.expectEqual(4, v1);
            try std.testing.expectEqual(5, v2);
            try std.testing.expectEqual(6, v3);
        }
    };

    var handle = try runtime.spawn(TestFn.testWrap, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncReceive with select - basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
                    try std.testing.expectEqual(42, try val);
                },
            }
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());
}

test "Channel: asyncReceive with select - already ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
                    try std.testing.expectEqual(99, try val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncReceive with select - closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
                    try std.testing.expectError(error.ChannelClosed, val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncSend with select - basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
            try std.testing.expectEqual(42, val);
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());
}

test "Channel: asyncSend with select - already ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
            try std.testing.expectEqual(123, val);
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: asyncSend with select - closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
                    try std.testing.expectError(error.ChannelClosed, res);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{ runtime, &channel });
    try handle.join(runtime);
}

test "Channel: select on both send and receive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
            try std.testing.expectEqual(1, which);
        }

        fn selectTask(rt: *Runtime, ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv = ch1.asyncReceive();
            var send = ch2.asyncSend(99);

            const result = try select(rt, .{ .recv = &recv, .send = &send });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(42, try val);
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
    const runtime = try Runtime.init(std.testing.allocator, .{});
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
                    try std.testing.expectEqual(42, try val);
                    which.* = 1;
                },
                .ch2 => |val| {
                    try std.testing.expectEqual(99, try val);
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

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.selectTask, .{ runtime, &channel1, &channel2, &which });
    try group.spawn(runtime, TestFn.sender2, .{ runtime, &channel2 });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // ch2 should win
    try std.testing.expectEqual(2, which);
}
