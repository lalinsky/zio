// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const yield = @import("../runtime.zig").yield;
const Group = @import("../runtime/group.zig").Group;
const SimpleQueue = @import("../utils/simple_queue.zig").SimpleQueue;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const select = @import("../select.zig").select;
const Waiter = @import("../common.zig").Waiter;
const Mutex = @import("Mutex.zig");

/// Specifies how a channel should be closed.
pub const CloseMode = enum {
    /// Close gracefully - allows receivers to drain buffered values before receiving error.ChannelClosed
    graceful,
    /// Close immediately - clears all buffered items so receivers get error.ChannelClosed right away
    immediate,
};

/// Type-erased channel implementation that operates on raw bytes.
/// This is the core implementation shared by all Channel(T) instances to reduce code size.
const ChannelImpl = struct {
    buffer: [*]u8,
    elem_size: usize,
    capacity: usize, // number of elements
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    mutex: Mutex = .init,
    receiver_queue: SimpleQueue(WaitNode) = .empty,
    sender_queue: SimpleQueue(WaitNode) = .empty,

    closed: bool = false,

    const Self = @This();

    /// Gets a pointer to the i'th element in the buffer
    fn elemPtr(self: *Self, index: usize) [*]u8 {
        return self.buffer + (index * self.elem_size);
    }

    /// Checks if the channel is empty.
    fn isEmpty(self: *Self) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.count == 0;
    }

    /// Checks if the channel is full.
    fn isFull(self: *Self) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.count == self.capacity;
    }

    /// Receives a value from the channel, blocking if empty.
    fn receive(self: *Self, elem_ptr: [*]u8) !void {
        const recv = AsyncReceiveImpl{ .channel = self };
        var ctx: AsyncReceiveImpl.WaitContext = .{ .result_ptr = undefined };
        var waiter = Waiter.init();

        if (!recv.asyncWait(&waiter, &ctx, elem_ptr)) {
            return recv.getResult(&ctx);
        }

        waiter.wait(1, .allow_cancel) catch |err| {
            const was_removed = recv.asyncCancelWait(&waiter, &ctx);
            if (!was_removed) {
                waiter.wait(1, .no_cancel);
                return recv.getResult(&ctx);
            }
            return err;
        };

        return recv.getResult(&ctx);
    }

    /// Tries to receive a value without blocking.
    fn tryReceive(self: *Self, elem_ptr: [*]u8) !void {
        self.mutex.lockUncancelable();

        if (self.count > 0) {
            return self.takeItemAndWakeSender(elem_ptr);
        }

        while (self.sender_queue.pop()) |node| {
            if (Waiter.fromNode(node).tryClaim()) {
                const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(elem_ptr[0..self.elem_size], send_ctx.item_ptr[0..self.elem_size]);
                send_ctx.succeeded = true;
                self.mutex.unlock();
                Waiter.fromNode(node).signal();
                return;
            }
        }

        const is_closed = self.closed;
        self.mutex.unlock();
        return if (is_closed) error.ChannelClosed else error.ChannelEmpty;
    }

    fn takeItemAndWakeSender(self: *Self, elem_ptr: [*]u8) void {
        std.debug.assert(self.count > 0);

        @memcpy(elem_ptr[0..self.elem_size], self.elemPtr(self.head)[0..self.elem_size]);
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;

        while (self.sender_queue.pop()) |node| {
            if (Waiter.fromNode(node).tryClaim()) {
                const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(self.elemPtr(self.tail)[0..self.elem_size], send_ctx.item_ptr[0..self.elem_size]);
                self.tail = (self.tail + 1) % self.capacity;
                self.count += 1;
                send_ctx.succeeded = true;
                self.mutex.unlock();
                Waiter.fromNode(node).signal();
                return;
            }
        }

        self.mutex.unlock();
    }

    fn send(self: *Self, elem_ptr: [*]const u8) !void {
        const send_op = AsyncSendImpl{ .channel = self };
        var ctx: AsyncSendImpl.WaitContext = .{ .item_ptr = undefined };
        var waiter = Waiter.init();

        if (!send_op.asyncWait(&waiter, &ctx, elem_ptr)) {
            return send_op.getResult(&ctx);
        }

        waiter.wait(1, .allow_cancel) catch |err| {
            const was_removed = send_op.asyncCancelWait(&waiter, &ctx);
            if (!was_removed) {
                waiter.wait(1, .no_cancel);
                return send_op.getResult(&ctx);
            }
            return err;
        };

        return send_op.getResult(&ctx);
    }

    fn trySend(self: *Self, elem_ptr: [*]const u8) !void {
        self.mutex.lockUncancelable();

        if (self.closed) {
            self.mutex.unlock();
            return error.ChannelClosed;
        }

        while (self.receiver_queue.pop()) |node| {
            if (Waiter.fromNode(node).tryClaim()) {
                const recv_ctx: *AsyncReceiveImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(recv_ctx.result_ptr[0..self.elem_size], elem_ptr[0..self.elem_size]);
                recv_ctx.result_set = true;
                self.mutex.unlock();
                Waiter.fromNode(node).signal();
                return;
            }
        }

        if (self.count == self.capacity) {
            self.mutex.unlock();
            return error.ChannelFull;
        }

        @memcpy(self.elemPtr(self.tail)[0..self.elem_size], elem_ptr[0..self.elem_size]);
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        self.mutex.unlock();
    }

    fn close(self: *Self, mode: CloseMode) void {
        self.mutex.lockUncancelable();

        self.closed = true;

        if (mode == .immediate) {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }

        var receivers = self.receiver_queue.popAll();
        var senders = self.sender_queue.popAll();

        self.mutex.unlock();

        while (receivers.pop()) |node| {
            Waiter.fromNode(node).signal();
        }

        while (senders.pop()) |node| {
            Waiter.fromNode(node).signal();
        }
    }
};

/// Type-erased async send operation for ChannelImpl
const AsyncSendImpl = struct {
    channel: *ChannelImpl,

    const SendSelf = @This();

    pub const WaitContext = struct {
        item_ptr: [*]const u8,
        succeeded: bool = false,
    };

    pub fn asyncWait(self: *const SendSelf, waiter: *Waiter, ctx: *WaitContext, item_ptr: [*]const u8) bool {
        ctx.item_ptr = item_ptr;

        self.channel.mutex.lockUncancelable();

        if (self.channel.closed) {
            self.channel.mutex.unlock();
            return false;
        }

        while (self.channel.receiver_queue.pop()) |node| {
            if (Waiter.fromNode(node).tryClaim()) {
                const recv_ctx: *AsyncReceiveImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(recv_ctx.result_ptr[0..self.channel.elem_size], ctx.item_ptr[0..self.channel.elem_size]);
                recv_ctx.result_set = true;
                ctx.succeeded = true;
                self.channel.mutex.unlock();
                Waiter.fromNode(node).signal();
                return false;
            }
        }

        if (self.channel.count < self.channel.capacity) {
            @memcpy(self.channel.elemPtr(self.channel.tail)[0..self.channel.elem_size], ctx.item_ptr[0..self.channel.elem_size]);
            self.channel.tail = (self.channel.tail + 1) % self.channel.capacity;
            self.channel.count += 1;
            ctx.succeeded = true;
            self.channel.mutex.unlock();
            return false;
        }

        waiter.node.userdata = @intFromPtr(ctx);
        self.channel.sender_queue.push(&waiter.node);
        self.channel.mutex.unlock();
        return true;
    }

    pub fn asyncCancelWait(self: *const SendSelf, waiter: *Waiter, ctx: *WaitContext) bool {
        _ = ctx;
        self.channel.mutex.lockUncancelable();
        const was_in_queue = self.channel.sender_queue.remove(&waiter.node);
        self.channel.mutex.unlock();

        if (was_in_queue) {
            return true;
        }

        return !waiter.didWin();
    }

    pub fn getResult(self: *const SendSelf, ctx: *WaitContext) error{ChannelClosed}!void {
        if (ctx.succeeded) {
            return {};
        }
        std.debug.assert(self.channel.closed);
        return error.ChannelClosed;
    }
};

/// Type-erased async receive operation for ChannelImpl
const AsyncReceiveImpl = struct {
    channel: *ChannelImpl,

    const RecvSelf = @This();

    pub const WaitContext = struct {
        result_ptr: [*]u8,
        result_set: bool = false,
    };

    pub fn asyncWait(self: *const RecvSelf, waiter: *Waiter, ctx: *WaitContext, result_ptr: [*]u8) bool {
        ctx.result_ptr = result_ptr;
        ctx.result_set = false;

        self.channel.mutex.lockUncancelable();

        if (self.channel.count > 0) {
            self.channel.takeItemAndWakeSender(ctx.result_ptr);
            ctx.result_set = true;
            return false;
        }

        while (self.channel.sender_queue.pop()) |node| {
            if (Waiter.fromNode(node).tryClaim()) {
                const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(ctx.result_ptr[0..self.channel.elem_size], send_ctx.item_ptr[0..self.channel.elem_size]);
                send_ctx.succeeded = true;
                ctx.result_set = true;
                self.channel.mutex.unlock();
                Waiter.fromNode(node).signal();
                return false;
            }
        }

        if (self.channel.closed) {
            self.channel.mutex.unlock();
            return false;
        }

        waiter.node.userdata = @intFromPtr(ctx);
        self.channel.receiver_queue.push(&waiter.node);
        self.channel.mutex.unlock();
        return true;
    }

    pub fn asyncCancelWait(self: *const RecvSelf, waiter: *Waiter, ctx: *WaitContext) bool {
        _ = ctx;
        self.channel.mutex.lockUncancelable();
        const was_in_queue = self.channel.receiver_queue.remove(&waiter.node);
        self.channel.mutex.unlock();

        if (was_in_queue) {
            return true;
        }

        return !waiter.didWin();
    }

    pub fn getResult(self: *const RecvSelf, ctx: *WaitContext) error{ChannelClosed}!void {
        // Result already set by direct transfer or fast path
        if (ctx.result_set) {
            return;
        }

        // Woken by close, check if there are items left (graceful close)
        self.channel.mutex.lockUncancelable();

        if (self.channel.count > 0) {
            self.channel.takeItemAndWakeSender(ctx.result_ptr);
            return;
        }

        std.debug.assert(self.channel.closed);
        self.channel.mutex.unlock();
        return error.ChannelClosed;
    }
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
/// fn producer(ch: *Channel(u32)) !void {
///     for (0..10) |i| {
///         try ch.send(@intCast(i));
///     }
/// }
///
/// fn consumer(ch: *Channel(u32)) !void {
///     while (ch.receive()) |value| {
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
        impl: ChannelImpl,

        const Self = @This();

        /// Initializes a channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        /// Use an empty buffer for an unbuffered (synchronous) channel.
        pub fn init(buffer: []T) Self {
            return .{
                .impl = .{
                    .buffer = std.mem.sliceAsBytes(buffer).ptr,
                    .elem_size = @sizeOf(T),
                    .capacity = buffer.len,
                },
            };
        }

        /// Checks if the channel is empty.
        pub fn isEmpty(self: *Self) bool {
            return self.impl.isEmpty();
        }

        /// Checks if the channel is full.
        pub fn isFull(self: *Self) bool {
            return self.impl.isFull();
        }

        /// Receives a value from the channel, blocking if empty.
        ///
        /// Suspends the current task if the channel is empty until a value is sent.
        /// Values are received in FIFO order.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn receive(self: *Self) !T {
            var result: T = undefined;
            try self.impl.receive(std.mem.asBytes(&result).ptr);
            return result;
        }

        /// Tries to receive a value without blocking.
        ///
        /// Returns immediately with a value if available, otherwise returns an error.
        ///
        /// Returns `error.ChannelEmpty` if the channel is empty and no sender waiting.
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        pub fn tryReceive(self: *Self) !T {
            var result: T = undefined;
            try self.impl.tryReceive(std.mem.asBytes(&result).ptr);
            return result;
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, item: T) !void {
            return self.impl.send(std.mem.asBytes(&item).ptr);
        }

        /// Tries to send a value without blocking.
        ///
        /// Returns immediately with success if space is available, otherwise returns an error.
        ///
        /// Returns `error.ChannelFull` if the channel is full.
        /// Returns `error.ChannelClosed` if the channel is closed.
        pub fn trySend(self: *Self, item: T) !void {
            return self.impl.trySend(std.mem.asBytes(&item).ptr);
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
            self.impl.close(mode);
        }

        /// Creates an AsyncReceive operation for use with select().
        ///
        /// Returns a single-shot future that will receive one value from the channel.
        /// Create a new AsyncReceive for each select() operation.
        ///
        /// Example:
        /// ```zig
        /// var recv = channel.asyncReceive();
        /// const result = try select(.{ .recv = &recv });
        /// switch (result) {
        ///     .recv => |val| std.debug.print("Received: {}\n", .{val}),
        /// }
        /// ```
        pub fn asyncReceive(self: *Self) AsyncReceive(T) {
            return AsyncReceive(T).init(&self.impl);
        }

        /// Creates an AsyncSend operation for use with select().
        ///
        /// Returns a single-shot future that will send the given value to the channel.
        /// Create a new AsyncSend for each select() operation.
        ///
        /// Example:
        /// ```zig
        /// var send = channel.asyncSend(42);
        /// const result = try select(.{ .send = &send });
        /// ```
        pub fn asyncSend(self: *Self, item: T) AsyncSend(T) {
            return AsyncSend(T).init(&self.impl, item);
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
/// const result = try select(.{ .ch1 = &recv1, .ch2 = &recv2 });
/// switch (result) {
///     .ch1 => |val| try std.testing.expectEqual(42, val),
///     .ch2 => |val| try std.testing.expectEqual(99, val),
/// }
/// ```
pub fn AsyncReceive(comptime T: type) type {
    return struct {
        impl: AsyncReceiveImpl,

        const Self = @This();

        pub const Result = error{ChannelClosed}!T;

        pub const WaitContext = struct {
            impl_ctx: AsyncReceiveImpl.WaitContext = .{ .result_ptr = undefined },
            result: T = undefined,
        };

        fn init(channel: *ChannelImpl) Self {
            return .{
                .impl = .{ .channel = channel },
            };
        }

        /// Register for notification when receive can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) bool {
            return self.impl.asyncWait(waiter, &ctx.impl_ctx, std.mem.asBytes(&ctx.result).ptr);
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) bool {
            return self.impl.asyncCancelWait(waiter, &ctx.impl_ctx);
        }

        /// Get the result of the receive operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *const Self, ctx: *WaitContext) Result {
            try self.impl.getResult(&ctx.impl_ctx);
            return ctx.result;
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
/// const result = try select(.{ .ch1 = &send1, .ch2 = &send2 });
/// ```
pub fn AsyncSend(comptime T: type) type {
    return struct {
        impl: AsyncSendImpl,
        item: T,

        const Self = @This();

        pub const Result = error{ChannelClosed}!void;

        pub const WaitContext = struct {
            impl_ctx: AsyncSendImpl.WaitContext = .{ .item_ptr = undefined },
        };

        fn init(channel: *ChannelImpl, item: T) Self {
            return .{
                .impl = .{ .channel = channel },
                .item = item,
            };
        }

        /// Register for notification when send can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) bool {
            return self.impl.asyncWait(waiter, &ctx.impl_ctx, std.mem.asBytes(&self.item).ptr);
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) bool {
            return self.impl.asyncCancelWait(waiter, &ctx.impl_ctx);
        }

        /// Get the result of the send operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *const Self, ctx: *WaitContext) Result {
            return self.impl.getResult(&ctx.impl_ctx);
        }
    };
}

test "Channel: basic send and receive" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(ch: *Channel(u32)) !void {
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
        }

        fn consumer(ch: *Channel(u32), results: *[3]u32) !void {
            results[0] = try ch.receive();
            results[1] = try ch.receive();
            results[2] = try ch.receive();
        }
    };

    var results: [3]u32 = undefined;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.producer, .{&channel});
    try group.spawn(TestFn.consumer, .{ &channel, &results });

    try group.wait();
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
        fn testTry(ch: *Channel(u32)) !void {
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

    var handle = try runtime.spawn(TestFn.testTry, .{&channel});
    try handle.join();
}

test "Channel: blocking behavior when empty" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn consumer(ch: *Channel(u32), result: *u32) !void {
            result.* = try ch.receive(); // Blocks until producer adds item
        }

        fn producer(ch: *Channel(u32)) !void {
            try yield(); // Let consumer start waiting
            try ch.send(42);
        }
    };

    var result: u32 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.consumer, .{ &channel, &result });
    try group.spawn(TestFn.producer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(42, result);
}

test "Channel: blocking behavior when full" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(ch: *Channel(u32), count: *u32) !void {
            try ch.send(1);
            try ch.send(2);
            try ch.send(3); // Blocks until consumer takes item
            count.* += 1;
        }

        fn consumer(ch: *Channel(u32)) !void {
            try yield(); // Let producer fill the channel
            try yield();
            _ = try ch.receive(); // Unblock producer
        }
    };

    var count: u32 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.producer, .{ &channel, &count });
    try group.spawn(TestFn.consumer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(1, count);
}

test "Channel: multiple producers and consumers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [10]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn producer(ch: *Channel(u32), start: u32) !void {
            for (0..5) |i| {
                try ch.send(start + @as(u32, @intCast(i)));
            }
        }

        fn consumer(ch: *Channel(u32), sum: *u32) !void {
            for (0..5) |_| {
                const val = try ch.receive();
                sum.* += val;
            }
        }
    };

    var sum: u32 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.producer, .{ &channel, 0 });
    try group.spawn(TestFn.producer, .{ &channel, 100 });
    try group.spawn(TestFn.consumer, .{ &channel, &sum });
    try group.spawn(TestFn.consumer, .{ &channel, &sum });

    try group.wait();
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
        fn producer(ch: *Channel(u32)) !void {
            try ch.send(1);
            try ch.send(2);
            ch.close(.graceful); // Graceful close - items remain
        }

        fn consumer(ch: *Channel(u32), results: *[3]?u32) !void {
            try yield(); // Let producer finish
            results[0] = ch.receive() catch null;
            results[1] = ch.receive() catch null;
            results[2] = ch.receive() catch null; // Should fail with ChannelClosed
        }
    };

    var results: [3]?u32 = .{ null, null, null };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.producer, .{&channel});
    try group.spawn(TestFn.consumer, .{ &channel, &results });

    try group.wait();
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
        fn producer(ch: *Channel(u32)) !void {
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);
            ch.close(.immediate); // Immediate close - clears all items
        }

        fn consumer(ch: *Channel(u32), result: *?u32) !void {
            try yield(); // Let producer finish
            result.* = ch.receive() catch null; // Should fail immediately
        }
    };

    var result: ?u32 = null;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.producer, .{&channel});
    try group.spawn(TestFn.consumer, .{ &channel, &result });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(null, result);
}

test "Channel: send on closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testClosed(ch: *Channel(u32)) !void {
            ch.close(.graceful);

            const put_err = ch.send(1);
            try std.testing.expectError(error.ChannelClosed, put_err);

            const tryput_err = ch.trySend(2);
            try std.testing.expectError(error.ChannelClosed, tryput_err);
        }
    };

    var handle = try runtime.spawn(TestFn.testClosed, .{&channel});
    try handle.join();
}

test "Channel: ring buffer wrapping" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [3]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn testWrap(ch: *Channel(u32)) !void {
            // Fill the channel
            try ch.send(1);
            try ch.send(2);
            try ch.send(3);

            // Empty it
            _ = try ch.receive();
            _ = try ch.receive();
            _ = try ch.receive();

            // Fill it again (should wrap around)
            try ch.send(4);
            try ch.send(5);
            try ch.send(6);

            // Verify items
            const v1 = try ch.receive();
            const v2 = try ch.receive();
            const v3 = try ch.receive();

            try std.testing.expectEqual(4, v1);
            try std.testing.expectEqual(5, v2);
            try std.testing.expectEqual(6, v3);
        }
    };

    var handle = try runtime.spawn(TestFn.testWrap, .{&channel});
    try handle.join();
}

test "Channel: asyncReceive with select - basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            try yield(); // Let receiver start waiting
            try ch.send(42);
        }

        fn receiver(ch: *Channel(u32)) !void {
            var recv = ch.asyncReceive();
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(42, try val);
                },
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.receiver, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "Channel: asyncReceive with select - value types" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Unbuffered channel - sender blocks until receiver ready
    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            try ch.send(42);
        }

        fn receiver(ch: *Channel(u32)) !void {
            // Pass asyncReceive() directly by value, no intermediate variable
            const result = try select(.{ .recv = ch.asyncReceive() });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(42, try val);
                },
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.receiver, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "Channel: asyncReceive with select - already ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(ch: *Channel(u32)) !void {
            // Send first, so receiver finds it ready
            try ch.send(99);

            var recv = ch.asyncReceive();
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(99, try val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{&channel});
    try handle.join();
}

test "Channel: asyncReceive with select - closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(ch: *Channel(u32)) !void {
            ch.close(.graceful);

            var recv = ch.asyncReceive();
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectError(error.ChannelClosed, val);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{&channel});
    try handle.join();
}

test "Channel: asyncSend with select - basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [2]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            try yield(); // Let receiver start
            var send_op = ch.asyncSend(42);
            const result = try select(.{ .send = &send_op });
            switch (result) {
                .send => |res| {
                    try res;
                },
            }
        }

        fn receiver(ch: *Channel(u32)) !void {
            try yield();
            try yield();
            const val = try ch.receive();
            try std.testing.expectEqual(42, val);
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.receiver, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "Channel: asyncSend with select - already ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_ready(ch: *Channel(u32)) !void {
            // Channel has space, send should complete immediately
            var send_op = ch.asyncSend(123);
            const result = try select(.{ .send = &send_op });
            switch (result) {
                .send => |res| {
                    try res;
                },
            }

            // Verify item was sent
            const val = try ch.receive();
            try std.testing.expectEqual(123, val);
        }
    };

    var handle = try runtime.spawn(TestFn.test_ready, .{&channel});
    try handle.join();
}

test "Channel: asyncSend with select - closed channel" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer: [5]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    const TestFn = struct {
        fn test_closed(ch: *Channel(u32)) !void {
            ch.close(.graceful);

            var send_op = ch.asyncSend(42);
            const result = try select(.{ .send = &send_op });
            switch (result) {
                .send => |res| {
                    try std.testing.expectError(error.ChannelClosed, res);
                },
            }
        }
    };

    var handle = try runtime.spawn(TestFn.test_closed, .{&channel});
    try handle.join();
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
        fn testMain(ch1: *Channel(u32), ch2: *Channel(u32)) !void {
            // Fill channel2 so send blocks
            try ch2.send(1);
            try ch2.send(2);

            var which: u8 = 0;
            var group: Group = .init;
            defer group.cancel();

            try group.spawn(selectTask, .{ ch1, ch2, &which });
            try group.spawn(sender, .{ch1});

            try group.wait();

            // Receive should win (sender provides value)
            try std.testing.expectEqual(1, which);
        }

        fn selectTask(ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv = ch1.asyncReceive();
            var send_op = ch2.asyncSend(99);

            const result = try select(.{ .recv = &recv, .send = &send_op });
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

        fn sender(ch: *Channel(u32)) !void {
            try yield();
            try ch.send(42);
        }
    };

    var handle = try runtime.spawn(TestFn.testMain, .{ &channel1, &channel2 });
    try handle.join();
}

test "Channel: select with multiple receivers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var buffer1: [5]u32 = undefined;
    var channel1 = Channel(u32).init(&buffer1);

    var buffer2: [5]u32 = undefined;
    var channel2 = Channel(u32).init(&buffer2);

    const TestFn = struct {
        fn selectTask(ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv1 = ch1.asyncReceive();
            var recv2 = ch2.asyncReceive();

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

        fn sender2(ch: *Channel(u32)) !void {
            try yield();
            try ch.send(99);
        }
    };

    var which: u8 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.selectTask, .{ &channel1, &channel2, &which });
    try group.spawn(TestFn.sender2, .{&channel2});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // ch2 should win
    try std.testing.expectEqual(2, which);
}

test "Channel: unbuffered - basic synchronous transfer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Unbuffered channel - sender and receiver must rendezvous
    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            // This will block until receiver is ready
            try ch.send(42);
            try ch.send(99);
        }

        fn receiver(ch: *Channel(u32), results: *[2]u32) !void {
            // Each receive unblocks a waiting sender
            results[0] = try ch.receive();
            results[1] = try ch.receive();
        }
    };

    var results: [2]u32 = undefined;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.receiver, .{ &channel, &results });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(42, results[0]);
    try std.testing.expectEqual(99, results[1]);
}

test "Channel: unbuffered - trySend fails without receiver" {
    var channel = Channel(u32).init(&.{});

    // trySend should fail immediately - no buffer space and no receiver
    const err = channel.trySend(42);
    try std.testing.expectError(error.ChannelFull, err);
}

test "Channel: unbuffered - tryReceive fails without sender" {
    var channel = Channel(u32).init(&.{});

    // tryReceive should fail immediately - no buffer and no sender
    const err = channel.tryReceive();
    try std.testing.expectError(error.ChannelEmpty, err);
}

test "Channel: unbuffered - sender blocks until receiver ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Record that sender started
            order[idx.*] = 'S';
            idx.* += 1;
            // This blocks until receiver calls receive
            try ch.send(42);
        }

        fn receiver(ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Give sender time to block
            try yield();
            try yield();
            // Record that receiver started receiving
            order[idx.*] = 'R';
            idx.* += 1;
            _ = try ch.receive();
        }
    };

    var order: [2]u8 = undefined;
    var idx: u8 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{ &channel, &order, &idx });
    try group.spawn(TestFn.receiver, .{ &channel, &order, &idx });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // Sender should start first, then receiver
    try std.testing.expectEqualStrings("SR", &order);
}

test "Channel: unbuffered - receiver blocks until sender ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn receiver(ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Record that receiver started
            order[idx.*] = 'R';
            idx.* += 1;
            // This blocks until sender calls send
            _ = try ch.receive();
        }

        fn sender(ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Give receiver time to block
            try yield();
            try yield();
            // Record that sender started sending
            order[idx.*] = 'S';
            idx.* += 1;
            try ch.send(42);
        }
    };

    var order: [2]u8 = undefined;
    var idx: u8 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.receiver, .{ &channel, &order, &idx });
    try group.spawn(TestFn.sender, .{ &channel, &order, &idx });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // Receiver should start first, then sender
    try std.testing.expectEqualStrings("RS", &order);
}

test "Channel: unbuffered - multiple senders and receivers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32), value: u32) !void {
            try ch.send(value);
        }

        fn receiver(ch: *Channel(u32), sum: *u32) !void {
            const val = try ch.receive();
            sum.* += val;
        }
    };

    var sum: u32 = 0;

    var group: Group = .init;
    defer group.cancel();

    // Spawn senders and receivers - they will pair up
    try group.spawn(TestFn.sender, .{ &channel, 10 });
    try group.spawn(TestFn.sender, .{ &channel, 20 });
    try group.spawn(TestFn.sender, .{ &channel, 30 });
    try group.spawn(TestFn.receiver, .{ &channel, &sum });
    try group.spawn(TestFn.receiver, .{ &channel, &sum });
    try group.spawn(TestFn.receiver, .{ &channel, &sum });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    // All values should be received
    try std.testing.expectEqual(60, sum);
}

test "Channel: unbuffered - close wakes blocked sender" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32), got_closed: *bool) !void {
            ch.send(42) catch |err| {
                got_closed.* = (err == error.ChannelClosed);
                return;
            };
        }

        fn closer(ch: *Channel(u32)) !void {
            try yield();
            try yield();
            ch.close(.graceful);
        }
    };

    var got_closed: bool = false;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{ &channel, &got_closed });
    try group.spawn(TestFn.closer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_closed);
}

test "Channel: unbuffered - close wakes blocked receiver" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn receiver(ch: *Channel(u32), got_error: *bool) !void {
            _ = ch.receive() catch |err| {
                got_error.* = (err == error.ChannelClosed);
                return;
            };
        }

        fn closer(ch: *Channel(u32)) !void {
            try yield();
            try yield();
            ch.close(.graceful);
        }
    };

    var got_error: bool = false;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.receiver, .{ &channel, &got_error });
    try group.spawn(TestFn.closer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_error);
}

test "Channel: unbuffered - select with direct transfer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            try yield();
            try ch.send(42);
        }

        fn receiver(ch: *Channel(u32)) !void {
            var recv = ch.asyncReceive();
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |val| {
                    try std.testing.expectEqual(42, try val);
                },
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.receiver, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}
