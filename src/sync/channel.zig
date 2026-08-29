// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const yield = @import("../runtime.zig").yield;
const Group = @import("../group.zig").Group;
const SimpleQueue = @import("../utils/simple_queue.zig").SimpleQueue;
const SimpleStack = @import("../utils/simple_stack.zig").SimpleStack;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const select = @import("../select.zig").select;
const Event = @import("Event.zig");
const common = @import("../common.zig");
const Waiter = common.Waiter;
const Closeable = common.Closeable;
const AsyncWaitState = common.AsyncWaitState;
const NO_WINNER = common.NO_WINNER;
const Mutex = @import("Mutex.zig");

/// Specifies how a channel should be closed.
pub const CloseMode = enum {
    /// Close gracefully - allows receivers to drain buffered values before receiving error.Closed
    graceful,
    /// Close immediately - clears all buffered items so receivers get error.Closed right away
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

    /// Ordering rule for every send path, named so the call sites can point
    /// here: a sender may hand its item straight to a queued receiver only
    /// while the buffer is empty.
    ///
    /// Normally a receiver is only queued when the buffer is empty, so the
    /// rule costs nothing. A busy (fenced) receiver breaks that invariant: it
    /// stays queued while a send skips it and buffers behind it, so a later
    /// send finding it claimable would hand over an item that overtakes the
    /// buffered ones. Buffering instead keeps FIFO; the skipped receiver is
    /// already owed a re-poll (its tryClaim bumped the select's generation),
    /// and that re-poll takes the oldest buffered item.
    const handoffOrder = {};

    /// Scan `queue` (under the channel mutex) for a waiter whose claim wins
    /// and remove it. The caller is committed to delivering that waiter's
    /// side effect and exactly one signal (after unlocking).
    ///
    /// Lost waiters (their select already decided another arm) are removed
    /// and dropped; no signal is owed to them, which their asyncCancelWait
    /// accounts for via didWin(). Busy waiters (their select's sweep holds
    /// its commit fence) stay queued and must not be consumed for: their
    /// tryClaim bumped the select's generation counter, so the owner re-polls
    /// this channel after releasing the fence and drives the pairing then.
    fn claimWaiter(self: *Self, queue: *SimpleQueue(WaitNode)) ?*WaitNode {
        _ = self;
        var node = queue.head;
        while (node) |n| {
            const next = n.next;
            const w = Waiter.fromNode(n);
            switch (w.tryClaim()) {
                .won => {
                    const removed = queue.remove(n);
                    std.debug.assert(removed);
                    return n;
                },
                .busy => {},
                .lost => {
                    const removed = queue.remove(n);
                    std.debug.assert(removed);
                },
            }
            node = next;
        }
        return null;
    }

    /// Take the front item out of the ring buffer.
    fn takeItem(self: *Self, elem_ptr: [*]u8) void {
        std.debug.assert(self.count > 0);
        @memcpy(elem_ptr[0..self.elem_size], self.elemPtr(self.head)[0..self.elem_size]);
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
    }

    /// After freeing a buffer slot, move a parked sender's item into it.
    /// Returns the sender's node for the caller to signal after unlocking.
    ///
    /// Never admits after close: a sender still queued then was skipped by
    /// close() while fenced, and must re-poll into error.Closed rather than
    /// have its send succeed on a closed channel.
    fn admitSender(self: *Self) ?*WaitNode {
        if (self.closed) return null;
        const node = self.claimWaiter(&self.sender_queue) orelse return null;
        const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
        @memcpy(self.elemPtr(self.tail)[0..self.elem_size], send_ctx.item_ptr[0..self.elem_size]);
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        send_ctx.succeeded = true;
        return node;
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
        // Direct (non-select) fast path. A plain receiver has no sibling arms
        // and cannot lose a race to itself, so it needs none of the claim /
        // commit-fence machinery the select sweep drives: it consumes under a
        // single lock exactly as tryReceive does. Only when nothing is
        // available does it park a direct waiter, which the select machinery
        // still drives from the peer (sender) side.
        self.mutex.lockUncancelable();

        if (self.count > 0) {
            self.takeItem(elem_ptr);
            const admitted = self.admitSender();
            self.mutex.unlock();
            if (admitted) |node| Waiter.fromNode(node).signal();
            return;
        }

        // Closed before the sender scan: a sender still queued after close was
        // fence-skipped by close() and must re-poll into error.Closed, never
        // have its send completed here (same rule as admitSender/tryReceive).
        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }

        if (self.claimWaiter(&self.sender_queue)) |node| {
            const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
            @memcpy(elem_ptr[0..self.elem_size], send_ctx.item_ptr[0..self.elem_size]);
            send_ctx.succeeded = true;
            self.mutex.unlock();
            Waiter.fromNode(node).signal();
            return;
        }

        // Nothing available: park a direct waiter and wait.
        const recv = AsyncReceiveImpl{ .channel = self };
        var ctx: AsyncReceiveImpl.WaitContext = .{ .result_ptr = elem_ptr, .result_set = false };
        var waiter = Waiter.init();
        waiter.node.userdata = @intFromPtr(&ctx);
        self.receiver_queue.push(&waiter.node);
        self.mutex.unlock();

        waiter.wait(1, .allow_cancel) catch |err| {
            const was_removed = recv.asyncCancelWait(&waiter, &ctx);
            if (!was_removed) {
                // A sender already claimed us, so the operation reports its
                // result rather than the cancellation. The cancelable wait
                // above consumed the request, so put it back for the next
                // cancelable operation, as waitForIo does. A null task
                // binding means the wait blocked the thread and consumed
                // nothing.
                waiter.wait(1, .no_cancel);
                if (waiter.mode.direct.task) |t| t.recancel();
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
            self.takeItem(elem_ptr);
            const admitted = self.admitSender();
            self.mutex.unlock();
            if (admitted) |node| Waiter.fromNode(node).signal();
            return;
        }

        // Closed comes before the sender scan: a sender still queued after
        // close was fence-skipped by close() and must re-poll into
        // error.Closed, never have its send completed by a late receiver
        // (same rule as admitSender).
        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }

        if (self.claimWaiter(&self.sender_queue)) |node| {
            const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
            @memcpy(elem_ptr[0..self.elem_size], send_ctx.item_ptr[0..self.elem_size]);
            send_ctx.succeeded = true;
            self.mutex.unlock();
            Waiter.fromNode(node).signal();
            return;
        }

        self.mutex.unlock();
        return error.WouldBlock;
    }

    fn send(self: *Self, elem_ptr: [*]const u8) !void {
        // Direct (non-select) fast path; see receive() for the rationale. This
        // is trySend's fused check-and-consume, falling back to parking a
        // direct waiter when the channel is full and no receiver is waiting.
        self.mutex.lockUncancelable();

        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }

        // Hand off to a waiting receiver only when the buffer is empty, or
        // this item would overtake the ones already in it; see handoffOrder.
        if (self.count == 0) {
            if (self.claimWaiter(&self.receiver_queue)) |node| {
                const recv_ctx: *AsyncReceiveImpl.WaitContext = @ptrFromInt(node.userdata);
                @memcpy(recv_ctx.result_ptr[0..self.elem_size], elem_ptr[0..self.elem_size]);
                recv_ctx.result_set = true;
                self.mutex.unlock();
                Waiter.fromNode(node).signal();
                return;
            }
        }

        if (self.count < self.capacity) {
            @memcpy(self.elemPtr(self.tail)[0..self.elem_size], elem_ptr[0..self.elem_size]);
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.mutex.unlock();
            return;
        }

        // Full and no waiting receiver: park a direct sender and wait.
        const send_op = AsyncSendImpl{ .channel = self };
        var ctx: AsyncSendImpl.WaitContext = .{ .item_ptr = elem_ptr };
        var waiter = Waiter.init();
        waiter.node.userdata = @intFromPtr(&ctx);
        self.sender_queue.push(&waiter.node);
        self.mutex.unlock();

        waiter.wait(1, .allow_cancel) catch |err| {
            const was_removed = send_op.asyncCancelWait(&waiter, &ctx);
            if (!was_removed) {
                // See receive(): a receiver already claimed us, so the send
                // reports its result and the consumed cancellation request
                // goes back for the next cancelable operation.
                waiter.wait(1, .no_cancel);
                if (waiter.mode.direct.task) |t| t.recancel();
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
            return error.Closed;
        }

        // Hand off to a waiting receiver only when the buffer is empty, or
        // this item would overtake the ones already in it; see handoffOrder.
        if (self.count == 0) {
            if (self.claimWaiter(&self.receiver_queue)) |node| {
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
            return error.WouldBlock;
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

        // Claim every waiter we can before unlocking; see Waiter.tryClaim().
        // Busy waiters stay queued: their select re-polls after releasing its
        // fence, observes `closed`, and completes itself.
        var to_signal: SimpleStack(WaitNode) = .{};

        while (self.claimWaiter(&self.receiver_queue)) |node| {
            to_signal.push(node);
        }

        while (self.claimWaiter(&self.sender_queue)) |node| {
            to_signal.push(node);
        }

        self.mutex.unlock();

        while (to_signal.pop()) |node| {
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

    pub fn asyncWait(self: *const SendSelf, waiter: *Waiter, ctx: *WaitContext, item_ptr: [*]const u8) AsyncWaitState {
        const ch = self.channel;

        ch.mutex.lockUncancelable();

        // Idempotent re-poll: unhook our previous registration, if any. A
        // channel registration is only ever consumed together with a claim,
        // so an unclaimed select's registration is always still queued and no
        // signal can exist for it. Whether the claim already happened is
        // settled below by tryClaim/beginCommit.
        _ = ch.sender_queue.remove(&waiter.node);

        // Commits that involve no peer (closed, plain buffer append with no
        // parked receiver) only need to win our own winner word; once it is
        // won, nothing can be torn apart. Commits that pair a peer waiter
        // additionally need the commit fence, taken below.
        //
        // A non-empty buffer takes this path even with a receiver queued: the
        // item must go behind the ones already buffered rather than overtake
        // them in a direct handoff; see handoffOrder.
        if (ch.closed or (ch.count < ch.capacity and (ch.count > 0 or ch.receiver_queue.isEmpty()))) {
            switch (waiter.tryClaim()) {
                .won => {},
                .busy => unreachable, // own sweep never claims while fenced
                .lost => {
                    ch.mutex.unlock();
                    return .decided;
                },
            }
            ctx.item_ptr = item_ptr;
            if (!ch.closed) {
                @memcpy(ch.elemPtr(ch.tail)[0..ch.elem_size], ctx.item_ptr[0..ch.elem_size]);
                ch.tail = (ch.tail + 1) % ch.capacity;
                ch.count += 1;
                ctx.succeeded = true;
            }
            ch.mutex.unlock();
            return .ready;
        }

        // The commit fence: while we hold it, no peer can claim this select,
        // so the peer claim below and the decision of our own select cannot
        // be torn apart (the failure mode that made PR #702 panic on
        // rendezvous). Taking it while holding the mutex is safe: fence
        // holders may block on channel mutexes, mutex holders never block on
        // fences.
        //
        // The fence (or the claim above) also guards the ctx writes: on a
        // re-poll whose arm was already claimed, ctx belongs to the claimer
        // and must not be touched.
        if (!waiter.beginCommit()) {
            ch.mutex.unlock();
            return .decided;
        }

        ctx.item_ptr = item_ptr;

        // Only reachable with an empty buffer (a non-empty one was handled
        // above) or a full one, where handing off would also reorder.
        if (if (ch.count == 0) ch.claimWaiter(&ch.receiver_queue) else null) |node| {
            const recv_ctx: *AsyncReceiveImpl.WaitContext = @ptrFromInt(node.userdata);
            @memcpy(recv_ctx.result_ptr[0..ch.elem_size], ctx.item_ptr[0..ch.elem_size]);
            recv_ctx.result_set = true;
            ctx.succeeded = true;
            waiter.finishCommit();
            ch.mutex.unlock();
            Waiter.fromNode(node).signal();
            return .ready;
        }

        // Every claimable receiver was busy or lost; fall back to the buffer.
        if (ch.count < ch.capacity) {
            @memcpy(ch.elemPtr(ch.tail)[0..ch.elem_size], ctx.item_ptr[0..ch.elem_size]);
            ch.tail = (ch.tail + 1) % ch.capacity;
            ch.count += 1;
            ctx.succeeded = true;
            waiter.finishCommit();
            ch.mutex.unlock();
            return .ready;
        }

        waiter.node.userdata = @intFromPtr(ctx);
        ch.sender_queue.push(&waiter.node);
        waiter.abortCommit();
        ch.mutex.unlock();
        return .queued;
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

    pub fn getResult(self: *const SendSelf, ctx: *WaitContext) Closeable!void {
        if (ctx.succeeded) {
            return {};
        }
        std.debug.assert(self.channel.closed);
        return error.Closed;
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

    pub fn asyncWait(self: *const RecvSelf, waiter: *Waiter, ctx: *WaitContext, result_ptr: [*]u8) AsyncWaitState {
        const ch = self.channel;

        ch.mutex.lockUncancelable();

        // See AsyncSendImpl.asyncWait for the claim/fence discipline,
        // including why ctx must not be touched before our claim or fence is
        // secured.
        _ = ch.receiver_queue.remove(&waiter.node);

        // Taking from the buffer or reporting closed involves no peer in our
        // own decision, so winning the winner word is enough. (admitSender
        // claims a parked sender, but only after our decision is final.)
        if (ch.count > 0 or ch.closed) {
            switch (waiter.tryClaim()) {
                .won => {},
                .busy => unreachable, // own sweep never claims while fenced
                .lost => {
                    ch.mutex.unlock();
                    return .decided;
                },
            }
            ctx.result_ptr = result_ptr;
            ctx.result_set = false;
            if (ch.count > 0) {
                ch.takeItem(ctx.result_ptr);
                const admitted = ch.admitSender();
                ctx.result_set = true;
                ch.mutex.unlock();
                if (admitted) |node| Waiter.fromNode(node).signal();
                return .ready;
            }
            ch.mutex.unlock();
            return .ready;
        }

        // Pairing a parked sender: this decides the peer and then us, which
        // needs the commit fence.
        if (!waiter.beginCommit()) {
            ch.mutex.unlock();
            return .decided;
        }

        ctx.result_ptr = result_ptr;
        ctx.result_set = false;

        if (ch.claimWaiter(&ch.sender_queue)) |node| {
            const send_ctx: *AsyncSendImpl.WaitContext = @ptrFromInt(node.userdata);
            @memcpy(ctx.result_ptr[0..ch.elem_size], send_ctx.item_ptr[0..ch.elem_size]);
            send_ctx.succeeded = true;
            ctx.result_set = true;
            waiter.finishCommit();
            ch.mutex.unlock();
            Waiter.fromNode(node).signal();
            return .ready;
        }

        waiter.node.userdata = @intFromPtr(ctx);
        ch.receiver_queue.push(&waiter.node);
        waiter.abortCommit();
        ch.mutex.unlock();
        return .queued;
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

    pub fn getResult(self: *const RecvSelf, ctx: *WaitContext) Closeable!void {
        // Result already set by direct transfer or fast path
        if (ctx.result_set) {
            return;
        }

        // Woken by close, check if there are items left (graceful close)
        self.channel.mutex.lockUncancelable();

        if (self.channel.count > 0) {
            self.channel.takeItem(ctx.result_ptr);
            const admitted = self.channel.admitSender();
            self.channel.mutex.unlock();
            if (admitted) |node| Waiter.fromNode(node).signal();
            return;
        }

        std.debug.assert(self.channel.closed);
        self.channel.mutex.unlock();
        return error.Closed;
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

        pub const Result = Closeable!T;

        pub const WaitContext = struct {
            impl_ctx: AsyncReceiveImpl.WaitContext = .{ .result_ptr = undefined },
            result: T = undefined,
        };

        fn init(channel: *ChannelImpl) Self {
            return .{
                .impl = .{ .channel = channel },
            };
        }

        /// Register for notification when receive can complete, or claim the
        /// select if it can complete now.
        pub fn asyncWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) AsyncWaitState {
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

        pub const Result = Closeable!void;

        pub const WaitContext = struct {
            impl_ctx: AsyncSendImpl.WaitContext = .{ .item_ptr = undefined },
        };

        fn init(channel: *ChannelImpl, item: T) Self {
            return .{
                .impl = .{ .channel = channel },
                .item = item,
            };
        }

        /// Register for notification when send can complete, or claim the
        /// select if it can complete now.
        pub fn asyncWait(self: *const Self, waiter: *Waiter, ctx: *WaitContext) AsyncWaitState {
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

test "Channel: close classifies select waiters before signaling" {
    const Helpers = struct {
        fn notifyState(waiter: *Waiter) u32 {
            return switch (waiter.mode) {
                .direct => |*direct| direct.notify.state.load(.acquire),
                .select => unreachable,
            };
        }
    };

    // Closing a pending receive claims it and commits to exactly one signal.
    var claimed_receive_channel = Channel(u32).init(&.{});
    var claimed_receive = claimed_receive_channel.asyncReceive();
    var claimed_receive_ctx: AsyncReceive(u32).WaitContext = .{};
    var claimed_receive_parent = Waiter.init();
    var claimed_receive_winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var claimed_receive_gen: std.atomic.Value(u32) = .init(0);
    var claimed_receive_pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var claimed_receive_waiter = Waiter.initSelect(&claimed_receive_parent, &claimed_receive_winner, &claimed_receive_gen, &claimed_receive_pending, 0);

    try std.testing.expectEqual(.queued, claimed_receive.asyncWait(&claimed_receive_waiter, &claimed_receive_ctx));
    claimed_receive_channel.close(.graceful);
    try std.testing.expectEqual(0, claimed_receive_winner.load(.acquire));
    try std.testing.expect(!claimed_receive.asyncCancelWait(&claimed_receive_waiter, &claimed_receive_ctx));
    try std.testing.expectEqual(1, Helpers.notifyState(&claimed_receive_parent));
    try std.testing.expectError(error.Closed, claimed_receive.getResult(&claimed_receive_ctx));

    // Exercise the same committed-signal handshake for a pending send.
    var claimed_send_channel = Channel(u32).init(&.{});
    var claimed_send = claimed_send_channel.asyncSend(42);
    var claimed_send_ctx: AsyncSend(u32).WaitContext = .{};
    var claimed_send_parent = Waiter.init();
    var claimed_send_winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var claimed_send_gen: std.atomic.Value(u32) = .init(0);
    var claimed_send_pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var claimed_send_waiter = Waiter.initSelect(&claimed_send_parent, &claimed_send_winner, &claimed_send_gen, &claimed_send_pending, 0);

    try std.testing.expectEqual(.queued, claimed_send.asyncWait(&claimed_send_waiter, &claimed_send_ctx));
    claimed_send_channel.close(.graceful);
    try std.testing.expectEqual(0, claimed_send_winner.load(.acquire));
    try std.testing.expect(!claimed_send.asyncCancelWait(&claimed_send_waiter, &claimed_send_ctx));
    try std.testing.expectEqual(1, Helpers.notifyState(&claimed_send_parent));
    try std.testing.expectError(error.Closed, claimed_send.getResult(&claimed_send_ctx));

    // Simulate another select arm having already won before close removes a
    // pending receive. The losing waiter must be discarded without a signal.
    var receive_channel = Channel(u32).init(&.{});
    var receive = receive_channel.asyncReceive();
    var receive_ctx: AsyncReceive(u32).WaitContext = .{};
    var receive_parent = Waiter.init();
    var receive_winner: std.atomic.Value(usize) = .init(1);
    var receive_gen: std.atomic.Value(u32) = .init(0);
    var receive_pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var receive_waiter = Waiter.initSelect(&receive_parent, &receive_winner, &receive_gen, &receive_pending, 0);

    // Another arm already won: registration is refused outright.
    try std.testing.expectEqual(.decided, receive.asyncWait(&receive_waiter, &receive_ctx));
    receive_channel.close(.graceful);
    try std.testing.expect(receive.asyncCancelWait(&receive_waiter, &receive_ctx));
    try std.testing.expectEqual(0, Helpers.notifyState(&receive_parent));

    // Exercise the same arbitration for a pending send.
    var send_channel = Channel(u32).init(&.{});
    var send = send_channel.asyncSend(42);
    var send_ctx: AsyncSend(u32).WaitContext = .{};
    var send_parent = Waiter.init();
    var send_winner: std.atomic.Value(usize) = .init(1);
    var send_gen: std.atomic.Value(u32) = .init(0);
    var send_pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var send_waiter = Waiter.initSelect(&send_parent, &send_winner, &send_gen, &send_pending, 0);

    // Another arm already won: registration is refused outright.
    try std.testing.expectEqual(.decided, send.asyncWait(&send_waiter, &send_ctx));
    send_channel.close(.graceful);
    try std.testing.expect(send.asyncCancelWait(&send_waiter, &send_ctx));
    try std.testing.expectEqual(0, Helpers.notifyState(&send_parent));
}

test "Channel: canceled select conserves a concurrently sent item" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const State = struct {
        channel: *Channel(u32),
        never: *Event,
        entered: std.atomic.Value(bool) = .init(false),
        go: std.atomic.Value(bool) = .init(false),
        received: std.atomic.Value(u32) = .init(0),

        fn waitForItem(self: *@This()) !void {
            var receive_op = self.channel.asyncReceive();
            self.entered.store(true, .release);
            const result = try select(.{ .item = &receive_op, .never = self.never });
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
        var never = Event.init;
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

    const Tasks = struct {
        fn send(ch: *Channel(u64), other: *Event) !void {
            var operation = ch.asyncSend(42);
            const result = try select(.{ .send = &operation, .never = other });
            switch (result) {
                .send => |sent| try sent,
                .never => unreachable,
            }
        }

        fn receive(ch: *Channel(u64), other: *Event) !u64 {
            var operation = ch.asyncReceive();
            const result = try select(.{ .receive = &operation, .never = other });
            return switch (result) {
                .receive => |item| try item,
                .never => unreachable,
            };
        }
    };

    for (0..200) |_| {
        var channel = Channel(u64).init(&.{});
        var never = Event.init;
        var sender = try runtime.spawn(Tasks.send, .{ &channel, &never });
        var receiver = try runtime.spawn(Tasks.receive, .{ &channel, &never });
        try std.testing.expectEqual(42, try receiver.join());
        try sender.join();
        try std.testing.expect(channel.impl.sender_queue.isEmpty());
        try std.testing.expect(channel.impl.receiver_queue.isEmpty());
    }
}

test "Channel: select over two rendezvous channels racing select senders" {
    // The composition main deadlocked on: a select whose arms are two
    // rendezvous channels, racing senders that are themselves selects. Every
    // pairing must go through the commit fence and re-poll machinery.
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    const count_per_sender = 20;

    const Tasks = struct {
        fn send(ch: *Channel(u64)) !void {
            for (0..count_per_sender) |i| {
                var operation = ch.asyncSend(i);
                const result = try select(.{ .send = &operation });
                switch (result) {
                    .send => |sent| try sent,
                }
            }
        }

        fn receive(a: *Channel(u64), b: *Channel(u64), sum: *u64) !void {
            for (0..2 * count_per_sender) |_| {
                var recv_a = a.asyncReceive();
                var recv_b = b.asyncReceive();
                const result = try select(.{ .a = &recv_a, .b = &recv_b });
                switch (result) {
                    .a => |item| sum.* += try item,
                    .b => |item| sum.* += try item,
                }
            }
        }
    };

    for (0..50) |_| {
        var a = Channel(u64).init(&.{});
        var b = Channel(u64).init(&.{});
        var sum: u64 = 0;

        var group: Group = .init;
        defer group.cancel();
        try group.spawn(Tasks.send, .{&a});
        try group.spawn(Tasks.send, .{&b});
        try group.spawn(Tasks.receive, .{ &a, &b, &sum });
        try group.wait();
        try std.testing.expect(!group.hasFailed());

        // Each sender delivers 0..count-1 exactly once.
        try std.testing.expectEqual(2 * (count_per_sender * (count_per_sender - 1) / 2), sum);
        try std.testing.expect(a.impl.sender_queue.isEmpty());
        try std.testing.expect(a.impl.receiver_queue.isEmpty());
        try std.testing.expect(b.impl.sender_queue.isEmpty());
        try std.testing.expect(b.impl.receiver_queue.isEmpty());
    }
}

test "Channel: cancel removes a parked select send" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const Tasks = struct {
        fn send(ch: *Channel(u64), entered: *std.atomic.Value(bool)) !void {
            var operation = ch.asyncSend(1);
            entered.store(true, .release);
            const result = try select(.{ .send = &operation });
            switch (result) {
                .send => |sent| try sent,
            }
        }
    };

    var channel = Channel(u64).init(&.{});
    var entered = std.atomic.Value(bool).init(false);
    var sender = try runtime.spawn(Tasks.send, .{ &channel, &entered });
    while (!entered.load(.acquire)) try yield();
    try yield();
    sender.cancel();
    try std.testing.expectError(error.Canceled, sender.join());
    try std.testing.expect(channel.impl.sender_queue.isEmpty());
}

test "Channel: rendezvous racing a level source in the same select" {
    // Exercises the fence-window wake: the Event can fire while the
    // select's sweep holds its commit fence on the rendezvous arm, in which
    // case the event's signal claims nothing and the select must recover the
    // standing readiness by re-polling. The item must never be lost.
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    const State = struct {
        channel: *Channel(u32),
        event: *Event,
        received: std.atomic.Value(u32) = .init(0),

        fn choose(self: *@This()) !void {
            var receive_op = self.channel.asyncReceive();
            const result = try select(.{ .item = &receive_op, .event = self.event });
            switch (result) {
                .item => |item| self.received.store(try item, .release),
                .event => {},
            }
        }

        fn send(self: *@This()) !void {
            var operation = self.channel.asyncSend(1);
            const result = try select(.{ .send = &operation });
            switch (result) {
                .send => |sent| try sent,
            }
        }

        fn fire(self: *@This()) !void {
            self.event.set();
        }
    };

    for (0..200) |_| {
        var channel = Channel(u32).init(&.{});
        var event = Event.init;
        var state = State{ .channel = &channel, .event = &event };

        var chooser = try runtime.spawn(State.choose, .{&state});
        var sender = try runtime.spawn(State.send, .{&state});
        var firer = try runtime.spawn(State.fire, .{&state});

        try chooser.join();
        try firer.join();

        // If the event won, the sender is (or will shortly be) parked in the
        // rendezvous queue; take its item directly to release it.
        var observed: u32 = state.received.load(.acquire);
        if (observed == 0) {
            observed = while (true) {
                break channel.tryReceive() catch |err| switch (err) {
                    error.WouldBlock => {
                        try yield();
                        continue;
                    },
                    else => return err,
                };
            };
        }
        try sender.join();
        try std.testing.expectEqual(1, observed);
    }
}

test "Channel: a send behind a fenced receiver does not overtake the buffer" {
    // A select receiver stays queued while its owning select holds the commit
    // fence for another arm, so a send skips it and buffers instead. A second
    // send must not then hand its item straight to that receiver, which would
    // deliver it ahead of the item already buffered.
    var buffer: [4]u32 = undefined;
    var channel = Channel(u32).init(&buffer);

    var recv = channel.asyncReceive();
    var ctx: AsyncReceive(u32).WaitContext = .{};
    var parent = Waiter.init();
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var gen: std.atomic.Value(u32) = .init(0);
    var pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiter = Waiter.initSelect(&parent, &winner, &gen, &pending, 0);

    try std.testing.expectEqual(.queued, recv.asyncWait(&waiter, &ctx));

    // The owning select's sweep takes the fence for a different arm.
    winner.store(common.COMMITTING, .seq_cst);

    // The receiver is busy, so this item is buffered behind it. The skipped
    // claim bumps the generation, which is what owes the receiver a re-poll.
    try channel.trySend(111);
    try std.testing.expectEqual(1, channel.impl.count);
    try std.testing.expect(gen.load(.seq_cst) != 0);

    // Fence released: the receiver is claimable again.
    winner.store(NO_WINNER, .seq_cst);

    // Must be buffered, not handed over: 111 is older.
    try channel.trySend(222);
    try std.testing.expectEqual(2, channel.impl.count);
    try std.testing.expect(!ctx.impl_ctx.result_set);

    // The receiver's re-poll takes the oldest item, and FIFO holds.
    try std.testing.expectEqual(.ready, recv.asyncWait(&waiter, &ctx));
    try std.testing.expectEqual(111, try recv.getResult(&ctx));
    try std.testing.expectEqual(222, try channel.tryReceive());
}

test "Channel: a receive that commits under cancellation keeps the request pending" {
    // A sender claims the parked receiver and only then is the receiver
    // canceled, so its cancelable wait reports the cancellation while the item
    // is already committed to it. The receive must deliver the item rather
    // than drop it, and because that wait consumed the cancellation request,
    // the next cancellation point must still report it.
    //
    // One executor, and the send before the cancel, so the receiver cannot run
    // in between: that pins the race to the committed branch every time.
    const checkCancel = @import("../runtime.zig").checkCancel;

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();

    const Outcome = struct {
        received: ?u32 = null,
        after_receive: ?anyerror = null,
    };

    const Tasks = struct {
        fn receiver(ch: *Channel(u32), entered: *std.atomic.Value(bool), out: *Outcome) !void {
            entered.store(true, .release);
            const item = ch.receive() catch |err| {
                out.after_receive = err;
                return;
            };
            out.received = item;
            out.after_receive = if (checkCancel()) |_| null else |err| err;
        }
    };

    var buffer: [1]u32 = undefined;
    var channel = Channel(u32).init(&buffer);
    var entered = std.atomic.Value(bool).init(false);
    var outcome: Outcome = .{};

    var handle = try runtime.spawn(Tasks.receiver, .{ &channel, &entered, &outcome });
    while (!entered.load(.acquire)) try yield();
    try yield(); // let the receiver park

    try channel.trySend(7);
    handle.cancel();
    try handle.join();

    try std.testing.expectEqual(@as(?u32, 7), outcome.received);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), outcome.after_receive);
}
