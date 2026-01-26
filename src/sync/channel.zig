// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const WaitNode = @import("../runtime/WaitNode.zig");
const SelectWaiter = @import("../select.zig").SelectWaiter;
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

        const Self = @This();

        /// Initializes a channel with the provided buffer.
        /// The buffer's length determines the channel capacity.
        /// Use an empty buffer for an unbuffered (synchronous) channel.
        pub fn init(buffer: []T) Self {
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
            const recv = self.asyncReceive();
            var ctx: AsyncReceive(T).WaitContext = .{};
            var waiter = Waiter.init(rt);

            if (!recv.asyncWait(rt, &waiter.wait_node, &ctx)) {
                return recv.getResult(&ctx);
            }

            waiter.wait(1, .allow_cancel) catch |err| {
                const was_removed = recv.asyncCancelWait(rt, &waiter.wait_node, &ctx);
                if (!was_removed) {
                    // Sender claimed us, wait for wake to complete
                    waiter.wait(1, .no_cancel);
                    // Return result (operation completed despite cancel)
                    return recv.getResult(&ctx);
                }
                return err;
            };

            return recv.getResult(&ctx);
        }

        /// Tries to receive a value without blocking.
        ///
        /// Returns immediately with a value if available, otherwise returns an error.
        ///
        /// Returns `error.ChannelEmpty` if the channel is empty and no sender waiting.
        /// Returns `error.ChannelClosed` if the channel is closed and empty.
        pub fn tryReceive(self: *Self) !T {
            self.mutex.lock();

            // Fast path: items in buffer
            if (self.count > 0) {
                return self.takeItemAndWakeSender();
            }

            // Try direct transfer from waiting sender (for unbuffered channels)
            while (self.sender_queue.pop()) |node| {
                if (SelectWaiter.tryClaim(node)) {
                    const send_ctx: *AsyncSend(T).WaitContext = @ptrFromInt(node.userdata);
                    const item = send_ctx.self_ptr.item;
                    send_ctx.succeeded = true;
                    self.mutex.unlock();
                    node.wake();
                    return item;
                }
                // CAS failed, sender was cancelled, try next
            }

            const is_closed = self.closed;
            self.mutex.unlock();
            return if (is_closed) error.ChannelClosed else error.ChannelEmpty;
        }

        /// Takes an item from buffer and wakes a waiting sender if any.
        /// Must be called with mutex held. Unlocks mutex before returning.
        fn takeItemAndWakeSender(self: *Self) T {
            std.debug.assert(self.count > 0);

            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;

            // If sender waiting, claim it and have it put its item in buffer
            while (self.sender_queue.pop()) |node| {
                if (SelectWaiter.tryClaim(node)) {
                    const send_ctx: *AsyncSend(T).WaitContext = @ptrFromInt(node.userdata);
                    // Put sender's item in buffer (direct transfer to buffer)
                    self.buffer[self.tail] = send_ctx.self_ptr.item;
                    self.tail = (self.tail + 1) % self.buffer.len;
                    self.count += 1;
                    send_ctx.succeeded = true;
                    self.mutex.unlock();
                    node.wake();
                    return item;
                }
                // CAS failed, sender was cancelled, try next
            }

            self.mutex.unlock();
            return item;
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.ChannelClosed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, rt: *Runtime, item: T) !void {
            const send_op = self.asyncSend(item);
            var ctx: AsyncSend(T).WaitContext = .{};
            var waiter = Waiter.init(rt);

            if (!send_op.asyncWait(rt, &waiter.wait_node, &ctx)) {
                return send_op.getResult(&ctx);
            }

            waiter.wait(1, .allow_cancel) catch |err| {
                const was_removed = send_op.asyncCancelWait(rt, &waiter.wait_node, &ctx);
                if (!was_removed) {
                    // Receiver claimed us, wait for wake to complete
                    waiter.wait(1, .no_cancel);
                    // Return result (operation completed despite cancel)
                    return send_op.getResult(&ctx);
                }
                return err;
            };

            return send_op.getResult(&ctx);
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

            // Try direct transfer to waiting receiver first
            while (self.receiver_queue.pop()) |node| {
                if (SelectWaiter.tryClaim(node)) {
                    const recv_ctx: *AsyncReceive(T).WaitContext = @ptrFromInt(node.userdata);
                    recv_ctx.result = item;
                    self.mutex.unlock();
                    node.wake();
                    return;
                }
                // CAS failed, receiver was cancelled, try next
            }

            // No receiver, try to put in buffer
            if (self.count == self.buffer.len) {
                self.mutex.unlock();
                return error.ChannelFull;
            }

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;
            self.mutex.unlock();
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
            }

            var receivers = self.receiver_queue.popAll();
            var senders = self.sender_queue.popAll();

            self.mutex.unlock();

            // Wake all waiters - they will check closed flag
            while (receivers.pop()) |node| {
                node.wake();
            }

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
///     .ch1 => |val| try std.testing.expectEqual(42, val),
///     .ch2 => |val| try std.testing.expectEqual(99, val),
/// }
/// ```
pub fn AsyncReceive(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        const Self = @This();

        pub const Result = error{ChannelClosed}!T;

        pub const WaitContext = struct {
            result: ?Result = null,
        };

        fn init(channel: *Channel(T)) Self {
            return .{ .channel = channel };
        }

        /// Register for notification when receive can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *const Self, _: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) bool {
            self.channel.mutex.lock();

            // Fast path: items in buffer
            if (self.channel.count > 0) {
                ctx.result = self.channel.takeItemAndWakeSender();
                return false;
            }

            // Fast path: try direct transfer from waiting sender (for unbuffered channels)
            while (self.channel.sender_queue.pop()) |node| {
                if (SelectWaiter.tryClaim(node)) {
                    const send_ctx: *AsyncSend(T).WaitContext = @ptrFromInt(node.userdata);
                    // Direct transfer from sender
                    ctx.result = send_ctx.self_ptr.item;
                    send_ctx.succeeded = true;
                    self.channel.mutex.unlock();
                    node.wake();
                    return false;
                }
                // CAS failed, sender was cancelled, try next
            }

            // Fast path: channel closed and empty
            if (self.channel.closed) {
                self.channel.mutex.unlock();
                ctx.result = error.ChannelClosed;
                return false;
            }

            // Slow path: enqueue and wait
            wait_node.userdata = @intFromPtr(ctx);
            self.channel.receiver_queue.push(wait_node);
            self.channel.mutex.unlock();
            return true;
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *const Self, _: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) bool {
            _ = ctx;
            self.channel.mutex.lock();
            const was_in_queue = self.channel.receiver_queue.remove(wait_node);
            self.channel.mutex.unlock();

            if (was_in_queue) {
                return true; // Removed, no wake coming
            }

            // Not in queue - sender claimed us. Check if we won (for select)
            // or if wake is in-flight.
            return !SelectWaiter.didWin(wait_node);
        }

        /// Get the result of the receive operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *const Self, ctx: *WaitContext) Result {
            // Result should already be set by direct transfer or fast path
            if (ctx.result) |r| {
                return r;
            }

            // Woken by close without result set
            self.channel.mutex.lock();

            // Try to get from buffer (graceful close may have items)
            if (self.channel.count > 0) {
                return self.channel.takeItemAndWakeSender();
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
        channel: *Channel(T),
        item: T,

        const Self = @This();

        pub const Result = error{ChannelClosed}!void;

        pub const WaitContext = struct {
            self_ptr: *const Self = undefined,
            succeeded: bool = false,
        };

        fn init(channel: *Channel(T), item: T) Self {
            return .{
                .channel = channel,
                .item = item,
            };
        }

        /// Register for notification when send can complete.
        /// Returns false if operation completed immediately (fast path).
        pub fn asyncWait(self: *const Self, _: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) bool {
            ctx.self_ptr = self;

            self.channel.mutex.lock();

            if (self.channel.closed) {
                self.channel.mutex.unlock();
                return false;
            }

            // Fast path: try direct transfer to waiting receiver
            while (self.channel.receiver_queue.pop()) |node| {
                if (SelectWaiter.tryClaim(node)) {
                    const recv_ctx: *AsyncReceive(T).WaitContext = @ptrFromInt(node.userdata);
                    // Direct transfer to receiver
                    recv_ctx.result = self.item;
                    ctx.succeeded = true;
                    self.channel.mutex.unlock();
                    node.wake();
                    return false;
                }
                // CAS failed, receiver was cancelled, try next
            }

            // Fast path: space in buffer
            if (self.channel.count < self.channel.buffer.len) {
                self.channel.buffer[self.channel.tail] = self.item;
                self.channel.tail = (self.channel.tail + 1) % self.channel.buffer.len;
                self.channel.count += 1;
                ctx.succeeded = true;
                self.channel.mutex.unlock();
                return false;
            }

            // Slow path: buffer full, enqueue and wait
            wait_node.userdata = @intFromPtr(ctx);
            self.channel.sender_queue.push(wait_node);
            self.channel.mutex.unlock();
            return true;
        }

        /// Cancel a pending wait operation.
        /// Returns true if removed, false if already removed by completion (wake in-flight).
        pub fn asyncCancelWait(self: *const Self, _: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) bool {
            _ = ctx;
            self.channel.mutex.lock();
            const was_in_queue = self.channel.sender_queue.remove(wait_node);
            self.channel.mutex.unlock();

            if (was_in_queue) {
                return true; // Removed, no wake coming
            }

            // Not in queue - receiver claimed us. Check if we won (for select)
            // or if wake is in-flight.
            return !SelectWaiter.didWin(wait_node);
        }

        /// Get the result of the send operation.
        /// Must only be called after asyncWait() returns false or the wait_node is woken.
        pub fn getResult(self: *const Self, ctx: *WaitContext) Result {
            if (ctx.succeeded) {
                return {};
            }
            std.debug.assert(self.channel.closed);
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

test "Channel: asyncReceive with select - value types" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Unbuffered channel - sender blocks until receiver ready
    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            try ch.send(rt, 42);
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32)) !void {
            // Pass asyncReceive() directly by value, no intermediate variable
            const result = try select(rt, .{ .recv = ch.asyncReceive() });
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
            var send_op = ch.asyncSend(42);
            const result = try select(rt, .{ .send = &send_op });
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
            var send_op = ch.asyncSend(123);
            const result = try select(rt, .{ .send = &send_op });
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

            var send_op = ch.asyncSend(42);
            const result = try select(rt, .{ .send = &send_op });
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
            var group: Group = .init;
            defer group.cancel(rt);

            try group.spawn(rt, selectTask, .{ rt, ch1, ch2, &which });
            try group.spawn(rt, sender, .{ rt, ch1 });

            try group.wait(rt);

            // Receive should win (sender provides value)
            try std.testing.expectEqual(1, which);
        }

        fn selectTask(rt: *Runtime, ch1: *Channel(u32), ch2: *Channel(u32), which: *u8) !void {
            var recv = ch1.asyncReceive();
            var send_op = ch2.asyncSend(99);

            const result = try select(rt, .{ .recv = &recv, .send = &send_op });
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

test "Channel: unbuffered - basic synchronous transfer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    // Unbuffered channel - sender and receiver must rendezvous
    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            // This will block until receiver is ready
            try ch.send(rt, 42);
            try ch.send(rt, 99);
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32), results: *[2]u32) !void {
            // Each receive unblocks a waiting sender
            results[0] = try ch.receive(rt);
            results[1] = try ch.receive(rt);
        }
    };

    var results: [2]u32 = undefined;

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &results });

    try group.wait(runtime);
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
        fn sender(rt: *Runtime, ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Record that sender started
            order[idx.*] = 'S';
            idx.* += 1;
            // This blocks until receiver calls receive
            try ch.send(rt, 42);
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Give sender time to block
            try rt.yield();
            try rt.yield();
            // Record that receiver started receiving
            order[idx.*] = 'R';
            idx.* += 1;
            _ = try ch.receive(rt);
        }
    };

    var order: [2]u8 = undefined;
    var idx: u8 = 0;

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, &order, &idx });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &order, &idx });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // Sender should start first, then receiver
    try std.testing.expectEqualStrings("SR", &order);
}

test "Channel: unbuffered - receiver blocks until sender ready" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn receiver(rt: *Runtime, ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Record that receiver started
            order[idx.*] = 'R';
            idx.* += 1;
            // This blocks until sender calls send
            _ = try ch.receive(rt);
        }

        fn sender(rt: *Runtime, ch: *Channel(u32), order: *[2]u8, idx: *u8) !void {
            // Give receiver time to block
            try rt.yield();
            try rt.yield();
            // Record that sender started sending
            order[idx.*] = 'S';
            idx.* += 1;
            try ch.send(rt, 42);
        }
    };

    var order: [2]u8 = undefined;
    var idx: u8 = 0;

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &order, &idx });
    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, &order, &idx });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // Receiver should start first, then sender
    try std.testing.expectEqualStrings("RS", &order);
}

test "Channel: unbuffered - multiple senders and receivers" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32), value: u32) !void {
            try ch.send(rt, value);
        }

        fn receiver(rt: *Runtime, ch: *Channel(u32), sum: *u32) !void {
            const val = try ch.receive(rt);
            sum.* += val;
        }
    };

    var sum: u32 = 0;

    var group: Group = .init;
    defer group.cancel(runtime);

    // Spawn senders and receivers - they will pair up
    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, 10 });
    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, 20 });
    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, 30 });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &sum });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &sum });
    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &sum });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // All values should be received
    try std.testing.expectEqual(60, sum);
}

test "Channel: unbuffered - close wakes blocked sender" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32), got_closed: *bool) !void {
            ch.send(rt, 42) catch |err| {
                got_closed.* = (err == error.ChannelClosed);
                return;
            };
        }

        fn closer(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
            try rt.yield();
            ch.close(.graceful);
        }
    };

    var got_closed: bool = false;

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.sender, .{ runtime, &channel, &got_closed });
    try group.spawn(runtime, TestFn.closer, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_closed);
}

test "Channel: unbuffered - close wakes blocked receiver" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn receiver(rt: *Runtime, ch: *Channel(u32), got_error: *bool) !void {
            _ = ch.receive(rt) catch |err| {
                got_error.* = (err == error.ChannelClosed);
                return;
            };
        }

        fn closer(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
            try rt.yield();
            ch.close(.graceful);
        }
    };

    var got_error: bool = false;

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.receiver, .{ runtime, &channel, &got_error });
    try group.spawn(runtime, TestFn.closer, .{ runtime, &channel });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_error);
}

test "Channel: unbuffered - select with direct transfer" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(rt: *Runtime, ch: *Channel(u32)) !void {
            try rt.yield();
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
