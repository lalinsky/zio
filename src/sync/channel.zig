// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const yield = @import("../runtime.zig").yield;
const Group = @import("../group.zig").Group;
const SimpleQueue = @import("../utils/simple_queue.zig").SimpleQueue;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const select = @import("../select.zig").select;
const Prepare = @import("../select.zig").Prepare;
const CommitResult = @import("../select.zig").CommitResult;
const Rollback = @import("../select.zig").Rollback;
const claimArm = @import("../select.zig").claimArm;
const peekArm = @import("../select.zig").peekArm;
const common = @import("../common.zig");
const Waiter = common.Waiter;
const Cancelable = common.Cancelable;
const Closeable = common.Closeable;
const Mutex = @import("Mutex.zig");
const ResetEvent = @import("ResetEvent.zig");

/// Specifies how a channel should be closed.
pub const CloseMode = enum {
    /// Close gracefully - allows receivers to drain buffered values before receiving error.Closed
    graceful,
    /// Close immediately - clears all buffered items so receivers get error.Closed right away
    immediate,
};

/// Type-erased channel implementation. Preparation only observes readiness or
/// queues a waiter; all transfers happen under the mutex in commit. Each new
/// buffered item or slot is reserved for at most one queued waiter. A losing
/// notified arm hands that reservation to the next waiter in rollback.
/// Rendezvous readiness remains optimistic: commit claims the parked peer's
/// select before copying its resident value.
const ChannelImpl = struct {
    buffer: [*]u8,
    elem_size: usize,
    capacity: usize, // number of elements
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    reserved_items: usize = 0,
    reserved_slots: usize = 0,

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
        return self.count <= self.reserved_items;
    }

    /// Checks if the channel is full.
    fn isFull(self: *Self) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        return self.capacity - self.count <= self.reserved_slots;
    }

    fn recvCtx(node: *WaitNode) *AsyncReceiveImpl.Context {
        return @ptrFromInt(node.userdata);
    }

    fn sendCtx(node: *WaitNode) *AsyncSendImpl.Context {
        return @ptrFromInt(node.userdata);
    }

    /// Two arms of one select cannot rendezvous with each other: only one arm
    /// may be returned, so matching them would perform a transfer without a
    /// second participant. Leave such peers queued for an outside operation.
    fn sameSelect(a: *Waiter, b: *Waiter) bool {
        return switch (a.mode) {
            .direct => false,
            .select => |a_select| switch (b.mode) {
                .direct => false,
                .select => |b_select| a_select.winner == b_select.winner,
            },
        };
    }

    fn takeItem(self: *Self, dest: [*]u8) void {
        std.debug.assert(self.count > 0);
        @memcpy(dest[0..self.elem_size], self.elemPtr(self.head)[0..self.elem_size]);
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
    }

    fn appendItem(self: *Self, src: [*]const u8) void {
        std.debug.assert(self.count < self.capacity);
        @memcpy(self.elemPtr(self.tail)[0..self.elem_size], src[0..self.elem_size]);
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
    }

    /// Reserve one buffered item for the oldest queued receiver. Must be
    /// called under the channel mutex; the returned waiter is signaled after
    /// unlocking.
    fn reserveReceiver(self: *Self) ?*WaitNode {
        const node = self.receiver_queue.pop() orelse return null;
        const ctx = recvCtx(node);
        std.debug.assert(!ctx.item_reserved);
        ctx.item_reserved = true;
        self.reserved_items += 1;
        std.debug.assert(self.reserved_items <= self.count);
        return node;
    }

    /// Reserve one buffered slot for the oldest queued sender. Must be called
    /// under the channel mutex; the returned waiter is signaled after
    /// unlocking.
    fn reserveSender(self: *Self) ?*WaitNode {
        const node = self.sender_queue.pop() orelse return null;
        const ctx = sendCtx(node);
        std.debug.assert(!ctx.slot_reserved);
        ctx.slot_reserved = true;
        self.reserved_slots += 1;
        std.debug.assert(self.reserved_slots <= self.capacity - self.count);
        return node;
    }

    /// Under the mutex, find a peer whose select can be decided. A peer whose
    /// select is currently committing another arm is dequeued and nudged; an
    /// already-decided peer stays queued for its owner's rollback.
    fn claimPeer(queue: *SimpleQueue(WaitNode), requester: ?*Waiter) ?*WaitNode {
        var node = queue.head;
        while (node) |n| {
            const next = n.next;
            if (requester) |r| {
                if (sameSelect(r, Waiter.fromNode(n))) {
                    node = next;
                    continue;
                }
            }
            switch (claimArm(Waiter.fromNode(n))) {
                .won => {
                    const removed = queue.remove(n);
                    std.debug.assert(removed);
                    return n;
                },
                .busy => {
                    const removed = queue.remove(n);
                    std.debug.assert(removed);
                    Waiter.fromNode(n).signal();
                },
                .lost => {},
            }
            node = next;
        }
        return null;
    }

    /// Non-consuming readiness probe for a rendezvous peer. Busy peers are
    /// nudged so they re-offer after their current select commit settles.
    fn peerAvailable(queue: *SimpleQueue(WaitNode), requester: *Waiter) bool {
        var node = queue.head;
        while (node) |n| {
            const next = n.next;
            if (sameSelect(requester, Waiter.fromNode(n))) {
                node = next;
                continue;
            }
            switch (peekArm(Waiter.fromNode(n))) {
                .won => return true,
                .busy => {
                    const removed = queue.remove(n);
                    std.debug.assert(removed);
                    Waiter.fromNode(n).signal();
                },
                .lost => {},
            }
            node = next;
        }
        return false;
    }

    fn receive(self: *Self, elem_ptr: [*]u8) !void {
        const recv = AsyncReceiveImpl{ .channel = self };
        var ctx: AsyncReceiveImpl.Context = .{ .result_ptr = elem_ptr };
        var waiter = Waiter.init();
        return blockingLoop(AsyncReceiveImpl, &recv, &waiter, &ctx);
    }

    fn send(self: *Self, elem_ptr: [*]const u8) !void {
        const send_op = AsyncSendImpl{ .channel = self };
        var ctx: AsyncSendImpl.Context = .{ .item_ptr = elem_ptr };
        var waiter = Waiter.init();
        return blockingLoop(AsyncSendImpl, &send_op, &waiter, &ctx);
    }

    fn blockingLoop(comptime Impl: type, impl: *const Impl, waiter: *Waiter, ctx: *Impl.Context) (Cancelable || Closeable)!void {
        var registered = false;
        var absorbed: u32 = 0;

        while (true) {
            if (!registered) {
                if (impl.prepare(waiter, ctx) == .pending) {
                    registered = true;
                    continue;
                }
                switch (impl.commit(ctx)) {
                    .done => |result| return result,
                    .retry => continue,
                }
            }

            waiter.wait(absorbed + 1, .allow_cancel) catch |err| {
                var expected = absorbed;
                const rollback_result = impl.rollback(waiter, ctx);
                if (rollback_result == .signal_in_flight) expected += 1;
                waiter.wait(expected, .no_cancel);
                if (rollback_result == .signal_in_flight) {
                    switch (impl.commit(ctx)) {
                        .done => |result| {
                            if (waiter.mode.direct.task) |task| task.recancel();
                            return result;
                        },
                        .retry => {},
                    }
                }
                return err;
            };
            absorbed = waiter.landedSignals();
            registered = false;
            switch (impl.commit(ctx)) {
                .done => |result| return result,
                .retry => {},
            }
        }
    }

    fn tryReceive(self: *Self, elem_ptr: [*]u8) !void {
        var peer: ?*WaitNode = null;
        var to_signal: ?*WaitNode = null;

        self.mutex.lockUncancelable();
        if (self.capacity > 0) {
            if (self.count <= self.reserved_items) {
                const closed = self.closed;
                self.mutex.unlock();
                return if (closed and self.count == 0) error.Closed else error.WouldBlock;
            }
            self.takeItem(elem_ptr);
            if (self.closed) {
                if (self.count == 0) to_signal = self.receiver_queue.pop();
            } else {
                to_signal = self.reserveSender();
            }
            self.mutex.unlock();
            if (to_signal) |node| Waiter.fromNode(node).signal();
            return;
        }

        peer = claimPeer(&self.sender_queue, null);
        if (peer) |node| {
            const ctx = sendCtx(node);
            @memcpy(elem_ptr[0..self.elem_size], ctx.item_ptr[0..self.elem_size]);
            ctx.succeeded = true;
            self.mutex.unlock();
            Waiter.fromNode(node).signal();
            return;
        }
        const closed = self.closed;
        self.mutex.unlock();
        return if (closed) error.Closed else error.WouldBlock;
    }

    fn trySend(self: *Self, elem_ptr: [*]const u8) !void {
        var to_signal: ?*WaitNode = null;

        self.mutex.lockUncancelable();
        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }
        if (self.capacity > 0) {
            if (self.capacity - self.count <= self.reserved_slots) {
                self.mutex.unlock();
                return error.WouldBlock;
            }
            self.appendItem(elem_ptr);
            to_signal = self.reserveReceiver();
            self.mutex.unlock();
            if (to_signal) |node| Waiter.fromNode(node).signal();
            return;
        }

        const peer = claimPeer(&self.receiver_queue, null) orelse {
            self.mutex.unlock();
            return error.WouldBlock;
        };
        const ctx = recvCtx(peer);
        @memcpy(ctx.result_ptr[0..self.elem_size], elem_ptr[0..self.elem_size]);
        ctx.result_set = true;
        self.mutex.unlock();
        Waiter.fromNode(peer).signal();
    }

    fn close(self: *Self, mode: CloseMode) void {
        self.mutex.lockUncancelable();
        const was_closed = self.closed;
        self.closed = true;
        if (mode == .immediate) {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
            // Outstanding receiver reservations become close notifications.
            self.reserved_items = 0;
        }
        // No reserved sender may append after close. Their notifications turn
        // into close notifications when they arrive.
        self.reserved_slots = 0;
        const receiver = if (!was_closed and self.count == 0) self.receiver_queue.pop() else null;
        const sender = if (!was_closed) self.sender_queue.pop() else null;
        self.mutex.unlock();

        if (receiver) |node| Waiter.fromNode(node).signal();
        if (sender) |node| Waiter.fromNode(node).signal();
    }
};

/// Type-erased async send operation for ChannelImpl
const AsyncSendImpl = struct {
    channel: *ChannelImpl,

    const SendSelf = @This();

    pub const Context = struct {
        item_ptr: [*]const u8,
        waiter: ?*Waiter = null,
        slot_reserved: bool = false,
        reservation_rolled_back: bool = false,
        succeeded: bool = false,
    };

    pub fn prepare(self: *const SendSelf, waiter: *Waiter, ctx: *Context) Prepare {
        const ch = self.channel;
        ch.mutex.lockUncancelable();
        defer ch.mutex.unlock();
        ctx.waiter = waiter;
        if (ctx.succeeded or ctx.slot_reserved or ch.closed) return .ready;
        if (ch.capacity > 0) {
            if (ch.capacity - ch.count > ch.reserved_slots) return .ready;
        } else if (ChannelImpl.peerAvailable(&ch.receiver_queue, waiter)) {
            return .ready;
        }
        waiter.node.userdata = @intFromPtr(ctx);
        ch.sender_queue.push(&waiter.node);
        return .pending;
    }

    pub fn commit(self: *const SendSelf, ctx: *Context) CommitResult(Closeable!void) {
        const ch = self.channel;
        var to_signal: ?*WaitNode = null;
        var peer: ?*WaitNode = null;

        ch.mutex.lockUncancelable();
        if (ctx.succeeded) {
            ch.mutex.unlock();
            return .{ .done = {} };
        }
        if (ctx.reservation_rolled_back) {
            ch.mutex.unlock();
            return .retry;
        }
        if (ch.closed) {
            ctx.slot_reserved = false;
            to_signal = ch.sender_queue.pop();
            ch.mutex.unlock();
            if (to_signal) |node| Waiter.fromNode(node).signal();
            return .{ .done = error.Closed };
        }
        if (ch.capacity > 0) {
            if (ctx.slot_reserved) {
                std.debug.assert(ch.reserved_slots > 0);
                ch.reserved_slots -= 1;
                ctx.slot_reserved = false;
            } else {
                if (ch.capacity - ch.count <= ch.reserved_slots) {
                    ch.mutex.unlock();
                    return .retry;
                }
            }
            ch.appendItem(ctx.item_ptr);
            to_signal = ch.reserveReceiver();
            ch.mutex.unlock();
            if (to_signal) |node| Waiter.fromNode(node).signal();
            return .{ .done = {} };
        }

        peer = ChannelImpl.claimPeer(&ch.receiver_queue, ctx.waiter);
        const node = peer orelse {
            ch.mutex.unlock();
            return .retry;
        };
        const rctx = ChannelImpl.recvCtx(node);
        @memcpy(rctx.result_ptr[0..ch.elem_size], ctx.item_ptr[0..ch.elem_size]);
        rctx.result_set = true;
        ch.mutex.unlock();
        Waiter.fromNode(node).signal();
        return .{ .done = {} };
    }

    pub fn rollback(self: *const SendSelf, waiter: *Waiter, ctx: *Context) Rollback {
        const ch = self.channel;
        var to_signal: ?*WaitNode = null;
        ch.mutex.lockUncancelable();
        if (ch.sender_queue.remove(&waiter.node)) {
            ch.mutex.unlock();
            return .removed;
        }

        if (ctx.slot_reserved) {
            ctx.slot_reserved = false;
            ctx.reservation_rolled_back = true;
            if (ch.reserved_slots > 0) {
                if (ch.sender_queue.pop()) |node| {
                    ChannelImpl.sendCtx(node).slot_reserved = true;
                    to_signal = node;
                } else {
                    ch.reserved_slots -= 1;
                }
            } else if (ch.closed) {
                to_signal = ch.sender_queue.pop();
            }
        } else if (ch.closed) {
            to_signal = ch.sender_queue.pop();
        }
        ch.mutex.unlock();
        if (to_signal) |node| Waiter.fromNode(node).signal();
        return .signal_in_flight;
    }
};

/// Type-erased async receive operation for ChannelImpl
const AsyncReceiveImpl = struct {
    channel: *ChannelImpl,

    const RecvSelf = @This();

    pub const Context = struct {
        result_ptr: [*]u8,
        waiter: ?*Waiter = null,
        item_reserved: bool = false,
        reservation_rolled_back: bool = false,
        result_set: bool = false,
    };

    pub fn prepare(self: *const RecvSelf, waiter: *Waiter, ctx: *Context) Prepare {
        const ch = self.channel;
        ch.mutex.lockUncancelable();
        defer ch.mutex.unlock();
        ctx.waiter = waiter;
        if (ctx.result_set or ctx.item_reserved) return .ready;
        if (ch.capacity > 0) {
            if (ch.count > ch.reserved_items or (ch.closed and ch.count == 0)) return .ready;
        } else {
            if (ChannelImpl.peerAvailable(&ch.sender_queue, waiter) or ch.closed) return .ready;
        }
        waiter.node.userdata = @intFromPtr(ctx);
        ch.receiver_queue.push(&waiter.node);
        return .pending;
    }

    pub fn commit(self: *const RecvSelf, ctx: *Context) CommitResult(Closeable!void) {
        const ch = self.channel;
        var to_signal: ?*WaitNode = null;

        ch.mutex.lockUncancelable();
        if (ctx.result_set) {
            ch.mutex.unlock();
            return .{ .done = {} };
        }
        if (ctx.reservation_rolled_back) {
            ch.mutex.unlock();
            return .retry;
        }
        if (ch.capacity > 0) {
            var can_take = false;
            if (ctx.item_reserved) {
                ctx.item_reserved = false;
                if (ch.reserved_items > 0) {
                    ch.reserved_items -= 1;
                    can_take = true;
                }
            } else if (ch.count > ch.reserved_items) {
                can_take = true;
            }
            if (can_take) {
                std.debug.assert(ch.count > 0);
                ch.takeItem(ctx.result_ptr);
                if (ch.closed) {
                    if (ch.count == 0) to_signal = ch.receiver_queue.pop();
                } else {
                    to_signal = ch.reserveSender();
                }
                ch.mutex.unlock();
                if (to_signal) |node| Waiter.fromNode(node).signal();
                return .{ .done = {} };
            }
        } else if (ChannelImpl.claimPeer(&ch.sender_queue, ctx.waiter)) |node| {
            const sctx = ChannelImpl.sendCtx(node);
            @memcpy(ctx.result_ptr[0..ch.elem_size], sctx.item_ptr[0..ch.elem_size]);
            sctx.succeeded = true;
            ch.mutex.unlock();
            Waiter.fromNode(node).signal();
            return .{ .done = {} };
        }
        if (ch.closed) {
            to_signal = ch.receiver_queue.pop();
            ch.mutex.unlock();
            if (to_signal) |node| Waiter.fromNode(node).signal();
            return .{ .done = error.Closed };
        }
        ch.mutex.unlock();
        return .retry;
    }

    pub fn rollback(self: *const RecvSelf, waiter: *Waiter, ctx: *Context) Rollback {
        const ch = self.channel;
        var to_signal: ?*WaitNode = null;
        ch.mutex.lockUncancelable();
        if (ch.receiver_queue.remove(&waiter.node)) {
            ch.mutex.unlock();
            return .removed;
        }

        if (ctx.item_reserved) {
            ctx.item_reserved = false;
            ctx.reservation_rolled_back = true;
            if (ch.reserved_items > 0) {
                if (ch.receiver_queue.pop()) |node| {
                    ChannelImpl.recvCtx(node).item_reserved = true;
                    to_signal = node;
                } else {
                    ch.reserved_items -= 1;
                }
            } else if (ch.closed) {
                to_signal = ch.receiver_queue.pop();
            }
        } else if (ch.closed and ch.count == 0) {
            to_signal = ch.receiver_queue.pop();
        }
        ch.mutex.unlock();
        if (to_signal) |node| Waiter.fromNode(node).signal();
        return .signal_in_flight;
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
/// receivers can drain any remaining buffered values before receiving `error.Closed`.
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
///         error.Closed => {}, // Normal shutdown
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
        /// Returns `error.Closed` if the channel is closed and empty.
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
        /// Returns `error.WouldBlock` if the channel is empty and no sender waiting.
        /// Returns `error.Closed` if the channel is closed and empty.
        pub fn tryReceive(self: *Self) !T {
            var result: T = undefined;
            try self.impl.tryReceive(std.mem.asBytes(&result).ptr);
            return result;
        }

        /// Sends a value to the channel, blocking if full.
        ///
        /// Suspends the current task if the channel is full until space becomes available.
        ///
        /// Returns `error.Closed` if the channel is closed.
        /// Returns `error.Canceled` if the task is cancelled while waiting.
        pub fn send(self: *Self, item: T) !void {
            return self.impl.send(std.mem.asBytes(&item).ptr);
        }

        /// Tries to send a value without blocking.
        ///
        /// Returns immediately with success if space is available, otherwise returns an error.
        ///
        /// Returns `error.WouldBlock` if the channel is full.
        /// Returns `error.Closed` if the channel is closed.
        pub fn trySend(self: *Self, item: T) !void {
            return self.impl.trySend(std.mem.asBytes(&item).ptr);
        }

        /// Closes the channel.
        ///
        /// After closing, all send operations will fail with `error.Closed`.
        /// Receive operations can still drain any buffered values before returning
        /// `error.Closed`.
        ///
        /// Use `CloseMode.graceful` to allow receivers to drain buffered values.
        /// Use `CloseMode.immediate` to clear all buffered items immediately,
        /// causing receivers to get `error.Closed` right away.
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

        fn init(channel: *ChannelImpl) Self {
            return .{
                .impl = .{ .channel = channel },
            };
        }

        pub const AsyncWait = struct {
            pub const Result = Closeable!T;
            pub const claimable = true;

            pub const Context = struct {
                impl_ctx: AsyncReceiveImpl.Context = .{ .result_ptr = undefined },
                result: T = undefined,
            };

            pub fn prepare(self: *const Self, waiter: *Waiter, ctx: *Context) Prepare {
                ctx.impl_ctx.result_ptr = std.mem.asBytes(&ctx.result).ptr;
                return self.impl.prepare(waiter, &ctx.impl_ctx);
            }

            pub fn commit(self: *const Self, ctx: *Context) CommitResult(Result) {
                ctx.impl_ctx.result_ptr = std.mem.asBytes(&ctx.result).ptr;
                return switch (self.impl.commit(&ctx.impl_ctx)) {
                    .retry => .retry,
                    .done => |result| if (result) |_| .{ .done = ctx.result } else |err| .{ .done = err },
                };
            }

            pub fn rollback(self: *const Self, waiter: *Waiter, ctx: *Context) Rollback {
                return self.impl.rollback(waiter, &ctx.impl_ctx);
            }
        };
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

        fn init(channel: *ChannelImpl, item: T) Self {
            return .{
                .impl = .{ .channel = channel },
                .item = item,
            };
        }

        pub const AsyncWait = struct {
            pub const Result = Closeable!void;
            pub const claimable = true;

            pub const Context = struct {
                impl_ctx: AsyncSendImpl.Context = .{ .item_ptr = undefined },
                item: T = undefined,
            };

            pub fn prepare(self: *const Self, waiter: *Waiter, ctx: *Context) Prepare {
                ctx.item = self.item;
                ctx.impl_ctx.item_ptr = std.mem.asBytes(&ctx.item).ptr;
                return self.impl.prepare(waiter, &ctx.impl_ctx);
            }

            pub fn commit(self: *const Self, ctx: *Context) CommitResult(Result) {
                return self.impl.commit(&ctx.impl_ctx);
            }

            pub fn rollback(self: *const Self, waiter: *Waiter, ctx: *Context) Rollback {
                return self.impl.rollback(waiter, &ctx.impl_ctx);
            }
        };
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
            try std.testing.expectError(error.WouldBlock, empty_err);

            // trySend should succeed
            try ch.trySend(1);
            try ch.trySend(2);

            // trySend on full channel should fail
            const full_err = ch.trySend(3);
            try std.testing.expectError(error.WouldBlock, full_err);

            // tryReceive should succeed
            const val1 = try ch.tryReceive();
            try std.testing.expectEqual(1, val1);

            const val2 = try ch.tryReceive();
            try std.testing.expectEqual(2, val2);

            // tryReceive on empty channel should fail again
            const empty_err2 = ch.tryReceive();
            try std.testing.expectError(error.WouldBlock, empty_err2);
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
            results[2] = ch.receive() catch null; // Should fail with Closed
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
            try std.testing.expectError(error.Closed, put_err);

            const tryput_err = ch.trySend(2);
            try std.testing.expectError(error.Closed, tryput_err);
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
                    try std.testing.expectError(error.Closed, val);
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
                    try std.testing.expectError(error.Closed, res);
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
    try std.testing.expectError(error.WouldBlock, err);
}

test "Channel: unbuffered - tryReceive fails without sender" {
    var channel = Channel(u32).init(&.{});

    // tryReceive should fail immediately - no buffer and no sender
    const err = channel.tryReceive();
    try std.testing.expectError(error.WouldBlock, err);
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
                got_closed.* = (err == error.Closed);
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
                got_error.* = (err == error.Closed);
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

test "Channel: close wakes blocked select receiver" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn receiver(ch: *Channel(u32)) !void {
            var recv = ch.asyncReceive();
            const result = try select(.{ .recv = &recv });
            switch (result) {
                .recv => |value| try std.testing.expectError(error.Closed, value),
            }
        }

        fn closer(ch: *Channel(u32)) !void {
            try yield();
            try yield();
            ch.close(.graceful);
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.receiver, .{&channel});
    try group.spawn(TestFn.closer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "Channel: close wakes blocked select sender" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn sender(ch: *Channel(u32)) !void {
            var send = ch.asyncSend(42);
            const result = try select(.{ .send = &send });
            switch (result) {
                .send => |send_result| try std.testing.expectError(error.Closed, send_result),
            }
        }

        fn closer(ch: *Channel(u32)) !void {
            try yield();
            try yield();
            ch.close(.graceful);
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.sender, .{&channel});
    try group.spawn(TestFn.closer, .{&channel});

    try group.wait();
    try std.testing.expect(!group.hasFailed());
}

test "Channel: close dequeues registrations before signaling" {
    var channel = Channel(u32).init(&.{});
    var receive = channel.asyncReceive();
    var receive_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var receive_waiter = Waiter.init();

    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&receive, &receive_waiter, &receive_ctx));
    channel.close(.graceful);
    receive_waiter.wait(1, .no_cancel);

    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
    try std.testing.expectEqual(Rollback.signal_in_flight, AsyncReceive(u32).AsyncWait.rollback(&receive, &receive_waiter, &receive_ctx));
    switch (AsyncReceive(u32).AsyncWait.commit(&receive, &receive_ctx)) {
        .done => |result| try std.testing.expectError(error.Closed, result),
        .retry => return error.TestUnexpectedResult,
    }
}

test "Channel: losing buffered receiver hands its item reservation to one waiter" {
    var buffer: [1]u32 = undefined;
    var channel = Channel(u32).init(&buffer);
    var first = channel.asyncReceive();
    var second = channel.asyncReceive();
    var first_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var second_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var first_waiter = Waiter.init();
    var second_waiter = Waiter.init();

    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&first, &first_waiter, &first_ctx));
    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&second, &second_waiter, &second_ctx));

    try channel.trySend(7);
    first_waiter.wait(1, .no_cancel);
    try std.testing.expect(first_ctx.impl_ctx.item_reserved);
    try std.testing.expect(!second_ctx.impl_ctx.item_reserved);
    try std.testing.expectEqual(1, channel.impl.reserved_items);
    try std.testing.expect(channel.isEmpty());
    try std.testing.expectError(error.WouldBlock, channel.tryReceive());

    try std.testing.expectEqual(Rollback.signal_in_flight, AsyncReceive(u32).AsyncWait.rollback(&first, &first_waiter, &first_ctx));
    second_waiter.wait(1, .no_cancel);
    try std.testing.expect(!first_ctx.impl_ctx.item_reserved);
    try std.testing.expect(second_ctx.impl_ctx.item_reserved);
    try std.testing.expectEqual(1, channel.impl.reserved_items);

    switch (AsyncReceive(u32).AsyncWait.commit(&first, &first_ctx)) {
        .retry => {},
        .done => return error.TestUnexpectedResult,
    }
    switch (AsyncReceive(u32).AsyncWait.commit(&second, &second_ctx)) {
        .done => |result| try std.testing.expectEqual(7, try result),
        .retry => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(0, channel.impl.reserved_items);
    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
}

test "Channel: losing buffered sender hands its slot reservation to one waiter" {
    var buffer: [1]u32 = undefined;
    var channel = Channel(u32).init(&buffer);
    try channel.trySend(1);

    var first = channel.asyncSend(2);
    var second = channel.asyncSend(3);
    var first_ctx: AsyncSend(u32).AsyncWait.Context = .{};
    var second_ctx: AsyncSend(u32).AsyncWait.Context = .{};
    var first_waiter = Waiter.init();
    var second_waiter = Waiter.init();

    try std.testing.expectEqual(Prepare.pending, AsyncSend(u32).AsyncWait.prepare(&first, &first_waiter, &first_ctx));
    try std.testing.expectEqual(Prepare.pending, AsyncSend(u32).AsyncWait.prepare(&second, &second_waiter, &second_ctx));

    try std.testing.expectEqual(1, try channel.tryReceive());
    first_waiter.wait(1, .no_cancel);
    try std.testing.expect(first_ctx.impl_ctx.slot_reserved);
    try std.testing.expect(!second_ctx.impl_ctx.slot_reserved);
    try std.testing.expectEqual(1, channel.impl.reserved_slots);
    try std.testing.expect(channel.isFull());
    try std.testing.expectError(error.WouldBlock, channel.trySend(4));

    try std.testing.expectEqual(Rollback.signal_in_flight, AsyncSend(u32).AsyncWait.rollback(&first, &first_waiter, &first_ctx));
    second_waiter.wait(1, .no_cancel);
    try std.testing.expect(!first_ctx.impl_ctx.slot_reserved);
    try std.testing.expect(second_ctx.impl_ctx.slot_reserved);
    try std.testing.expectEqual(1, channel.impl.reserved_slots);

    switch (AsyncSend(u32).AsyncWait.commit(&first, &first_ctx)) {
        .retry => {},
        .done => return error.TestUnexpectedResult,
    }
    switch (AsyncSend(u32).AsyncWait.commit(&second, &second_ctx)) {
        .done => |result| try result,
        .retry => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(0, channel.impl.reserved_slots);
    try std.testing.expectEqual(3, try channel.tryReceive());
    try std.testing.expect(channel.impl.sender_queue.isEmpty());
}

test "Channel: close notification is handed off instead of broadcast" {
    var buffer: [1]u32 = undefined;
    var channel = Channel(u32).init(&buffer);
    var first = channel.asyncReceive();
    var second = channel.asyncReceive();
    var first_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var second_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var first_waiter = Waiter.init();
    var second_waiter = Waiter.init();

    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&first, &first_waiter, &first_ctx));
    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&second, &second_waiter, &second_ctx));

    channel.close(.graceful);
    first_waiter.wait(1, .no_cancel);
    // Close dequeued one waiter only; the other stays parked until commit or
    // rollback hands the sticky close readiness onward.
    try std.testing.expect(!channel.impl.receiver_queue.isEmpty());

    try std.testing.expectEqual(Rollback.signal_in_flight, AsyncReceive(u32).AsyncWait.rollback(&first, &first_waiter, &first_ctx));
    second_waiter.wait(1, .no_cancel);
    switch (AsyncReceive(u32).AsyncWait.commit(&second, &second_ctx)) {
        .done => |result| try std.testing.expectError(error.Closed, result),
        .retry => return error.TestUnexpectedResult,
    }
    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
}

test "Channel: graceful close drains a reserved item before handing off close" {
    var buffer: [1]u32 = undefined;
    var channel = Channel(u32).init(&buffer);
    var first = channel.asyncReceive();
    var second = channel.asyncReceive();
    var first_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var second_ctx: AsyncReceive(u32).AsyncWait.Context = .{};
    var first_waiter = Waiter.init();
    var second_waiter = Waiter.init();

    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&first, &first_waiter, &first_ctx));
    try std.testing.expectEqual(Prepare.pending, AsyncReceive(u32).AsyncWait.prepare(&second, &second_waiter, &second_ctx));
    try channel.trySend(7);
    first_waiter.wait(1, .no_cancel);

    channel.close(.graceful);
    try std.testing.expect(!channel.impl.receiver_queue.isEmpty());
    switch (AsyncReceive(u32).AsyncWait.commit(&first, &first_ctx)) {
        .done => |result| try std.testing.expectEqual(7, try result),
        .retry => return error.TestUnexpectedResult,
    }

    second_waiter.wait(1, .no_cancel);
    switch (AsyncReceive(u32).AsyncWait.commit(&second, &second_ctx)) {
        .done => |result| try std.testing.expectError(error.Closed, result),
        .retry => return error.TestUnexpectedResult,
    }
    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
    try std.testing.expectEqual(0, channel.impl.reserved_items);
}

test "Channel: canceled select conserves a concurrently sent item" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const State = struct {
        channel: *Channel(u32),
        never: *ResetEvent,
        entered: std.atomic.Value(bool) = .init(false),
        go: std.atomic.Value(bool) = .init(false),
        received: std.atomic.Value(u32) = .init(0),

        fn waitForItem(self: *@This()) !void {
            var receive = self.channel.asyncReceive();
            self.entered.store(true, .release);
            const result = try select(.{ .item = &receive, .never = self.never });
            switch (result) {
                .item => |item| self.received.store(try item, .release),
                .never => unreachable,
            }
        }

        fn sendItem(self: *@This()) !void {
            while (!self.go.load(.acquire)) try yield();
            try self.channel.trySend(1);
        }
    };

    // The outcome may be either cancellation or delivery. The item must be
    // observable in exactly one place after the race.
    for (0..200) |_| {
        var buffer: [1]u32 = undefined;
        var channel = Channel(u32).init(&buffer);
        var never = ResetEvent.init;
        var state = State{ .channel = &channel, .never = &never };

        var receiver = try runtime.spawn(State.waitForItem, .{&state});
        while (!state.entered.load(.acquire)) try yield();
        try yield();
        var sender = try runtime.spawn(State.sendItem, .{&state});
        state.go.store(true, .release);
        receiver.cancel();
        _ = receiver.join() catch {};
        try sender.join();

        var observed: u32 = state.received.load(.acquire);
        if (channel.tryReceive()) |item| {
            observed += item;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }
        try std.testing.expectEqual(1, observed);
    }
}

test "Channel: ready arm does not clobber an earlier channel notification" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const State = struct {
        first: *Channel(u64),
        second: *Channel(u64),
        go: std.atomic.Value(bool) = .init(false),

        fn choose(self: *@This()) !u64 {
            var first = self.first.asyncReceive();
            var second = self.second.asyncReceive();
            self.go.store(true, .release);
            const result = try select(.{ .first = &first, .second = &second });
            return switch (result) {
                .first => |item| try item,
                .second => |item| try item,
            };
        }

        fn sendFirst(self: *@This()) !void {
            while (!self.go.load(.acquire)) try yield();
            try self.first.trySend(1);
        }
    };

    // Channel two is ready before registration starts while channel one is
    // notified concurrently. Whichever arm wins, both values are conserved.
    for (0..200) |_| {
        var first_buffer: [1]u64 = undefined;
        var second_buffer: [1]u64 = undefined;
        var first = Channel(u64).init(&first_buffer);
        var second = Channel(u64).init(&second_buffer);
        try second.trySend(2);
        var state = State{ .first = &first, .second = &second };

        var chooser = try runtime.spawn(State.choose, .{&state});
        var sender = try runtime.spawn(State.sendFirst, .{&state});
        var sum = try chooser.join();
        try sender.join();

        if (first.tryReceive()) |item| {
            sum += item;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }
        if (second.tryReceive()) |item| {
            sum += item;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        }
        try std.testing.expectEqual(3, sum);
    }
}

test "Channel: unbuffered select send rendezvous with select receive" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var channel = Channel(u64).init(&.{});
    var never = ResetEvent.init;

    const Tasks = struct {
        fn send(ch: *Channel(u64), other: *ResetEvent) !void {
            var operation = ch.asyncSend(42);
            const result = try select(.{ .send = &operation, .never = other });
            switch (result) {
                .send => |sent| try sent,
                .never => unreachable,
            }
        }

        fn receive(ch: *Channel(u64), other: *ResetEvent) !u64 {
            var operation = ch.asyncReceive();
            const result = try select(.{ .receive = &operation, .never = other });
            return switch (result) {
                .receive => |item| try item,
                .never => unreachable,
            };
        }
    };

    var sender = try runtime.spawn(Tasks.send, .{ &channel, &never });
    var receiver = try runtime.spawn(Tasks.receive, .{ &channel, &never });
    try std.testing.expectEqual(42, try receiver.join());
    try sender.join();
    try std.testing.expect(channel.impl.sender_queue.isEmpty());
    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
}

test "Channel: cancel removes a parked select send" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var channel = Channel(u64).init(&.{});
    var never = ResetEvent.init;
    var entered: std.atomic.Value(bool) = .init(false);

    const Task = struct {
        fn run(ch: *Channel(u64), other: *ResetEvent, started: *std.atomic.Value(bool)) !void {
            var operation = ch.asyncSend(42);
            started.store(true, .release);
            const result = try select(.{ .send = &operation, .never = other });
            switch (result) {
                .send => |sent| try sent,
                .never => unreachable,
            }
        }
    };

    var sender = try runtime.spawn(Task.run, .{ &channel, &never, &entered });
    while (!entered.load(.acquire)) try yield();
    try yield();
    sender.cancel();
    try std.testing.expectError(error.Canceled, sender.join());
    try std.testing.expect(channel.impl.sender_queue.isEmpty());
    try std.testing.expectError(error.WouldBlock, channel.tryReceive());
}

test "Channel: one select cannot rendezvous its own send and receive arms" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u64).init(&.{});
    var entered: std.atomic.Value(bool) = .init(false);

    const Task = struct {
        fn run(ch: *Channel(u64), started: *std.atomic.Value(bool)) !void {
            var send = ch.asyncSend(42);
            var receive = ch.asyncReceive();
            started.store(true, .release);
            _ = try select(.{ .send = &send, .receive = &receive });
        }
    };

    var waiter = try runtime.spawn(Task.run, .{ &channel, &entered });
    while (!entered.load(.acquire)) try yield();
    try yield();
    try yield();
    waiter.cancel();
    try std.testing.expectError(error.Canceled, waiter.join());
    try std.testing.expect(channel.impl.sender_queue.isEmpty());
    try std.testing.expect(channel.impl.receiver_queue.isEmpty());
}
