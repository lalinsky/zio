// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Per-loop socket readiness registrations for the edge-triggered backends
//! (epoll, kqueue).
//!
//! Each loop registers a socket with its own poller, edge-triggered and
//! persistent, the first time one of its own completions waits on it, and only
//! ever services its own completions, on its own thread. A socket used from
//! several loops is registered with each of them, and every readiness edge
//! reaches every poller it is registered with.
//!
//! No wakeup can be lost: a completion parks only after its own syscall (or a
//! readiness probe) saw the socket not ready, on its loop's thread. Anything
//! that arrives after that raises an edge in this loop's poller, which the loop
//! cannot harvest before it returns to its poll, so not before the completion is
//! parked. Registering a socket, or adding a direction to it, reports readiness
//! that already exists.
//!
//! A registration no local completion uses any more is dropped lazily. Every
//! park sets its direction's `used` bit; an edge that finds no waiter in that
//! direction clears the bit, and a second such edge removes the direction from
//! the poller. A socket that stays on one loop keeps its registration, and one
//! whose tasks moved to other loops costs this loop at most two spurious edges.
//!
//! The group-shared `Table` only records which loops have a socket registered,
//! so that closing it, from any thread, can remove it from each of their pollers
//! before the fd is gone. The fd is the only handle a registration can be
//! removed by, and an epoll registration on a description that outlives the
//! close (dup, fork) would otherwise keep firing for whatever reuses the fd
//! number.

const std = @import("std");
const os = @import("../os/root.zig");
const net = @import("../os/net.zig");
const Completion = @import("completion.zig").Completion;
const Op = @import("completion.zig").Op;
const NetConnect = @import("completion.zig").NetConnect;
const NetAccept = @import("completion.zig").NetAccept;
const NetRecv = @import("completion.zig").NetRecv;
const NetSend = @import("completion.zig").NetSend;
const NetRecvFrom = @import("completion.zig").NetRecvFrom;
const NetSendTo = @import("completion.zig").NetSendTo;
const NetRecvMsg = @import("completion.zig").NetRecvMsg;
const NetRecvMmsg = @import("completion.zig").NetRecvMmsg;
const NetSendMsg = @import("completion.zig").NetSendMsg;
const NetSendMmsg = @import("completion.zig").NetSendMmsg;
const NetSendFile = @import("completion.zig").NetSendFile;
const NetPoll = @import("completion.zig").NetPoll;
const Queue = @import("queue.zig").Queue;
const log = @import("../common.zig").log;

pub const Dir = enum(u1) { read, write };

/// A set of directions, one bit per `Dir`.
pub const Dirs = u2;

pub fn dirBit(dir: Dir) Dirs {
    return @as(Dirs, 1) << @backingInt(dir);
}

/// Most loops one group can have with a socket registration table.
pub const max_loops = 64;

/// Width of a registration's generation, as carried in the poller's event data
/// (epoll's u64 above the fd and the socket tag, kqueue's udata on 32-bit too).
pub const gen_bits = 30;
pub const Gen = @Int(.unsigned, gen_bits);

/// One loop's registration of one socket.
pub const Entry = struct {
    /// Completions of this loop parked on the socket, per direction.
    waiters: [2]Queue(Completion) = .{ .{}, .{} },
    /// Directions registered with this loop's poller.
    registered: Dirs = 0,
    /// Directions a completion parked on since the last edge that found no
    /// waiter in them.
    used: Dirs = 0,
    /// Tags this registration's events, so an event harvested before the socket
    /// was closed and its fd number reused is not applied to the new socket.
    gen: Gen,
};

/// One loop's registrations. Only the loop's own thread touches it, except a
/// close, which may run on any thread; the mutex is for that.
pub const Local = struct {
    mutex: os.Mutex = .init(),
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    next_gen: Gen = 0,
    /// Bit of this loop in the table's per-fd masks.
    index: u6,
    /// The poller (epoll or kqueue fd) the registrations live in.
    poller_fd: i32,
    table: *Table,

    fn key(fd: net.fd_t) u32 {
        return @bitCast(fd);
    }

    /// Drop `fd` for a close. The table's mask bit is already gone.
    fn purge(self: *Local, fd: net.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const removed = self.entries.fetchRemove(key(fd)) orelse return;
        // Closing an fd with ops still parked on it would orphan those
        // completions (removed here without finishing) and leak their
        // active/inflight accounting. The contract is that callers cancel or
        // await outstanding socket ops before closing the fd; assert it so a
        // violation surfaces in safe builds rather than silently leaking.
        std.debug.assert(removed.value.waiters[0].head == null);
        std.debug.assert(removed.value.waiters[1].head == null);
        if (removed.value.registered != 0) self.table.forget_fn(self.poller_fd, fd);
    }
};

const shard_count = 64; // power of two

pub const Shard = struct {
    mutex: os.Mutex = .init(),
    /// fd -> mask of the loops (`Local.index`) that have it registered.
    map: std.AutoHashMapUnmanaged(u32, u64) = .empty,
};

/// Per-group record of which loops have which sockets registered. Loops acquire
/// it on init and release it on deinit. A table with live loops is linked into
/// `live_tables`, so a socket closed by a thread that runs no loop can still be
/// purged from it (`purgeAll`).
///
/// Lock order: a shard's mutex, then a `Local`'s. A loop never holds its own
/// mutex while taking a shard's.
pub const Table = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    allocator: std.mem.Allocator = undefined,
    shards: [shard_count]Shard = @splat(.{}),
    locals: [max_loops]?*Local = @splat(null),
    /// Link in `live_tables`, guarded by `live_tables_mutex`.
    next_live: ?*Table = null,
    /// Removes an fd from a poller, for a close; set by the backend.
    forget_fn: *const fn (poller_fd: i32, fd: net.fd_t) void = undefined,

    /// Register a loop whose poller is `poller_fd`. `Backend.forgetSocket`
    /// removes an fd from such a poller before it is closed.
    pub fn acquire(self: *Table, allocator: std.mem.Allocator, comptime Backend: type, poller_fd: i32) error{ OutOfMemory, TooManyLoops }!*Local {
        live_tables_mutex.lock();
        defer live_tables_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) {
            self.allocator = allocator;
            self.forget_fn = Backend.forgetSocket;
        }
        const index = std.mem.indexOfScalar(?*Local, &self.locals, null) orelse return error.TooManyLoops;
        const local = try self.allocator.create(Local);
        local.* = .{ .index = @intCast(index), .poller_fd = poller_fd, .table = self };
        self.locals[index] = local;
        if (self.refcount == 0) {
            self.next_live = live_tables;
            live_tables = self;
        }
        self.refcount += 1;
        return local;
    }

    /// Unregister a loop. Its poller is about to be closed, which drops its
    /// registrations in the kernel; this drops them from the table.
    pub fn release(self: *Table, local: *Local) void {
        // Clear the loop's bits from the masks rather than walking its entries:
        // a close on another thread may be removing entries meanwhile. Once a
        // shard has no bit of this loop, no purge reaches `local` through it.
        // A mask left at zero is dropped by the fd's close.
        const bit = @as(u64, 1) << local.index;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            var it = shard.map.valueIterator();
            while (it.next()) |mask| mask.* &= ~bit;
        }

        live_tables_mutex.lock();
        defer live_tables_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.locals[local.index] = null;
        local.entries.deinit(self.allocator);
        self.allocator.destroy(local);
        self.refcount -= 1;
        if (self.refcount == 0) {
            var link: *?*Table = &live_tables;
            while (link.*) |table| : (link = &table.next_live) {
                if (table == self) {
                    link.* = self.next_live;
                    break;
                }
            }
            self.next_live = null;
            for (&self.shards) |*shard| {
                shard.map.deinit(self.allocator);
                shard.map = .empty;
            }
        }
    }

    fn shardFor(self: *Table, key: u32) *Shard {
        return &self.shards[key & (shard_count - 1)];
    }

    /// Remove `fd` from every loop that has it registered. Must run before the
    /// fd is closed.
    pub fn purge(self: *Table, fd: net.fd_t) void {
        const shard = self.shardFor(Local.key(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        const removed = shard.map.fetchRemove(Local.key(fd)) orelse return;
        var mask = removed.value;
        // Under the shard mutex, so a loop's `release` (which clears its bits
        // under the same mutex first) cannot free a `Local` we reach here.
        while (mask != 0) : (mask &= mask - 1) {
            const index: u6 = @intCast(@ctz(mask));
            self.locals[index].?.purge(fd);
        }
    }

    fn setBit(self: *Table, fd: net.fd_t, bit: u64) bool {
        const shard = self.shardFor(Local.key(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        const gop = shard.map.getOrPut(self.allocator, Local.key(fd)) catch return false;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* |= bit;
        return true;
    }

    fn unsetBit(self: *Table, fd: net.fd_t, bit: u64) void {
        const shard = self.shardFor(Local.key(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        clearBit(shard, Local.key(fd), bit);
    }
};

fn clearBit(shard: *Shard, key: u32, bit: u64) void {
    const mask = shard.map.getPtr(key) orelse return;
    mask.* &= ~bit;
    if (mask.* == 0) _ = shard.map.remove(key);
}

var live_tables_mutex: os.Mutex = .init();
var live_tables: ?*Table = null;

/// Purge `fd` from every live table, for a close that does not run on a loop
/// and so does not know which group the socket was used in.
pub fn purgeAll(fd: net.fd_t) void {
    live_tables_mutex.lock();
    defer live_tables_mutex.unlock();
    var it = live_tables;
    while (it) |table| : (it = table.next_live) table.purge(fd);
}

// ---- generic socket path ----------------------------------------------------
//
// The control flow below is identical for epoll and kqueue; only the poller
// syscalls differ. Each backend supplies these hooks:
//
//   * checkCompletion(c, event) CheckResult  - run the op's syscall (free fn)
//   * probeEvent(fd, dir) Event              - a no-error event for the
//                                              optimistic attempt (free fn)
//   * self.setInterest(fd, old, new, gen) bool - change the directions `fd` is
//                                              registered for in this loop's
//                                              poller (adding, modifying, or
//                                              removing it)
//   * forgetSocket(poller_fd, fd) void       - remove `fd` from a poller before
//                                              it is closed, from any thread
//                                              (free fn)
//
// `self` is the backend, with its `Local` in `self.socks`; `state` is its
// *LoopState.

pub fn isSocketOp(op: Op) bool {
    return switch (op) {
        .net_connect,
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_recvmmsg,
        .net_sendmsg,
        .net_sendmmsg,
        .net_send_file,
        .net_poll,
        => true,
        else => false,
    };
}

/// Direction a socket op waits on.
pub fn dirForOp(c: *Completion) Dir {
    return switch (c.op) {
        .net_accept, .net_recv, .net_recvfrom, .net_recvmsg, .net_recvmmsg => .read,
        .net_connect, .net_send, .net_sendto, .net_sendmsg, .net_sendmmsg, .net_send_file => .write,
        .net_poll => switch (c.cast(NetPoll).event) {
            .recv => .read,
            .send => .write,
        },
        else => unreachable,
    };
}

/// The socket fd a net op operates on.
pub fn netHandle(c: *Completion) net.fd_t {
    return switch (c.op) {
        .net_accept => c.cast(NetAccept).handle,
        .net_connect => c.cast(NetConnect).handle,
        .net_recv => c.cast(NetRecv).handle,
        .net_send => c.cast(NetSend).handle,
        .net_recvfrom => c.cast(NetRecvFrom).handle,
        .net_sendto => c.cast(NetSendTo).handle,
        .net_recvmsg => c.cast(NetRecvMsg).handle,
        .net_recvmmsg => c.cast(NetRecvMmsg).handle,
        .net_sendmsg => c.cast(NetSendMsg).handle,
        .net_sendmmsg => c.cast(NetSendMmsg).handle,
        .net_send_file => c.cast(NetSendFile).handle,
        .net_poll => c.cast(NetPoll).handle,
        else => unreachable,
    };
}

/// Finish a completion that could not be parked. A native sendfile that already
/// sent part of the request reports what it sent, as on cancel (see NetSendFile).
fn failPark(state: anytype, completion: *Completion) void {
    const SendFileData = @FieldType(NetSendFile, "internal");
    if (comptime @hasField(SendFileData, "sent")) {
        if (completion.op == .net_send_file) {
            const sent = completion.cast(NetSendFile).internal.sent;
            if (sent > 0) {
                completion.setResult(.net_send_file, sent);
                state.markCompletedFromBackend(completion);
                return;
            }
        }
    }
    completion.setError(error.Unexpected);
    state.markCompletedFromBackend(completion);
}

/// Park `completion` in this loop's waiters for its socket, registering the
/// socket (or the direction) with this loop's poller if it is not yet. If that
/// fails, finishes the completion with an error instead.
fn park(self: anytype, state: anytype, fd: net.fd_t, completion: *Completion) void {
    const local: *Local = self.socks;
    const dir = dirForOp(completion);
    const bit = dirBit(dir);

    local.mutex.lock();
    const gop = local.entries.getOrPut(local.table.allocator, Local.key(fd)) catch {
        local.mutex.unlock();
        log.err("socket registration table OOM", .{});
        failPark(state, completion);
        return;
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .gen = local.next_gen };
        local.next_gen +%= 1;
    }
    const entry = gop.value_ptr;
    const newly_registered = entry.registered == 0;
    if (entry.registered & bit == 0) {
        if (!self.setInterest(fd, entry.registered, entry.registered | bit, entry.gen)) {
            if (newly_registered) _ = local.entries.remove(Local.key(fd));
            local.mutex.unlock();
            failPark(state, completion);
            return;
        }
        entry.registered |= bit;
    }
    entry.used |= bit;
    completion.prev = null;
    completion.next = null;
    entry.waiters[@backingInt(dir)].push(completion);
    local.mutex.unlock();

    // The table only needs the bit by the time the socket is closed, and a
    // close cannot race an op parked on it; set it outside the loop's mutex to
    // keep the lock order (see `Table`).
    if (newly_registered and !local.table.setBit(fd, @as(u64, 1) << local.index)) {
        // Without the bit a close would leave the registration behind, so undo
        // it. Nothing else can have touched the entry: only this thread parks
        // or services on it.
        log.err("socket registration table OOM", .{});
        local.mutex.lock();
        const entry_now = local.entries.getPtr(Local.key(fd)).?;
        const removed = entry_now.waiters[@backingInt(dir)].remove(completion);
        std.debug.assert(removed);
        _ = self.setInterest(fd, entry_now.registered, 0, entry_now.gen);
        _ = local.entries.remove(Local.key(fd));
        local.mutex.unlock();
        failPark(state, completion);
    }
}

/// Handle a readiness event for `fd` on this loop: service the parked
/// completions in the `ready` directions, or count an idle edge where there are
/// none. Runs each waiter's syscall under the loop's mutex (non-blocking),
/// collects the finished ones, then completes them after unlocking (completing
/// can run callbacks that submit, cancel or close re-entrantly).
pub fn onEvent(self: anytype, state: anytype, fd: net.fd_t, gen: Gen, ready: Dirs, event: anytype) void {
    const Backend = @TypeOf(self.*);
    const local: *Local = self.socks;
    var to_finish: Queue(Completion) = .{};
    var dropped = false;

    local.mutex.lock();
    if (local.entries.getPtr(Local.key(fd))) |entry| if (entry.gen == gen) {
        inline for (.{ Dir.read, Dir.write }) |dir| {
            const bit = dirBit(dir);
            if (ready & entry.registered & bit != 0) {
                const waiters = &entry.waiters[@backingInt(dir)];
                if (waiters.head == null) {
                    if (entry.used & bit != 0) {
                        entry.used &= ~bit;
                    } else {
                        const remaining = entry.registered & ~bit;
                        if (!self.setInterest(fd, entry.registered, remaining, entry.gen)) {
                            log.err("failed to drop an idle socket registration", .{});
                        }
                        entry.registered = remaining;
                    }
                } else {
                    var iter: ?*Completion = waiters.head;
                    while (iter) |c| {
                        iter = c.next;
                        // Both ways out of the queue (this loop and `detach`)
                        // unlink the op before it is marked completed, so a
                        // parked op is always running.
                        std.debug.assert(c.loadState().phase == .running);
                        switch (Backend.checkCompletion(c, event)) {
                            .completed => {
                                // `detach` relies on this: the result is set in
                                // the same critical section that unlinks the op.
                                std.debug.assert(c.has_result);
                                _ = waiters.remove(c);
                                to_finish.push(c);
                            },
                            .requeue => {
                                std.debug.assert(!c.has_result);
                                break; // not ready for this direction
                            },
                        }
                    }
                }
            }
        }
        if (entry.registered == 0) {
            std.debug.assert(entry.waiters[0].head == null and entry.waiters[1].head == null);
            _ = local.entries.remove(Local.key(fd));
            dropped = true;
        }
    };
    local.mutex.unlock();

    if (dropped) local.table.unsetBit(fd, @as(u64, 1) << local.index);

    while (to_finish.pop()) |c| {
        state.markCompletedFromBackend(c);
    }
}

/// Detach a parked socket completion from this loop's waiters (cancel).
///
/// Returns true if `target` was still parked and this call removed it, meaning
/// the caller now owns it and must finish it. Returns false if it was already
/// gone: `onEvent` claimed it and is completing it with its natural result, and
/// a callback it ran is canceling it re-entrantly. The caller must then leave it
/// alone.
///
/// The answer is taken from `has_result`, not from the queue: an op `onEvent`
/// claimed sits in its private finish list, whose links it rewrites after
/// unlocking, and `Queue.remove` would mistake a linked op there for a member
/// of the waiter queue.
pub fn detach(self: anytype, target: *Completion) bool {
    const local: *Local = self.socks;
    local.mutex.lock();
    defer local.mutex.unlock();
    if (target.has_result) return false;
    // An op without a result is parked here: it was submitted on this loop, and
    // its entry can only go away with its last waiter, or when the fd is
    // closed, which the caller must not do with ops still in flight.
    const entry = local.entries.getPtr(Local.key(netHandle(target))) orelse return false;
    const removed = entry.waiters[@backingInt(dirForOp(target))].remove(target);
    std.debug.assert(removed);
    return removed;
}

/// Remove a socket that is about to be closed from every loop of this group.
pub fn unregister(self: anytype, fd: net.fd_t) void {
    const local: *Local = self.socks;
    local.table.purge(fd);
}

/// Generic submit for socket read/write/accept-family ops: try the syscall
/// optimistically (reusing checkCompletion with a no-error event) and only park
/// on WouldBlock.
pub fn submitIo(self: anytype, state: anytype, c: *Completion) void {
    const Backend = @TypeOf(self.*);
    const fd = netHandle(c);
    var probe = Backend.probeEvent(fd, dirForOp(c));
    switch (Backend.checkCompletion(c, &probe)) {
        // Inline finish (flags permitting) lets a bulk sender batch until
        // WouldBlock instead of paying a poll per chunk (#525).
        .completed => state.markCompletedFromBackend(c),
        .requeue => park(self, state, fd, c),
    }
}

/// Generic connect submit: try connect() first, park on WouldBlock.
pub fn submitConnect(self: anytype, state: anytype, c: *Completion) void {
    const data = c.cast(NetConnect);
    if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
        c.setResult(.net_connect, {});
        state.markCompletedFromBackend(c);
        return;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => {
            c.setError(err);
            state.markCompletedFromBackend(c);
            return;
        },
    }
    park(self, state, data.handle, c);
}

/// Generic net_poll submit: probe readiness with a 0-timeout poll(), since it
/// has no syscall of its own to see whether the socket is ready, and park only
/// when it is not.
pub fn submitPoll(self: anytype, state: anytype, c: *Completion) void {
    const data = c.cast(NetPoll);
    const want: i16 = switch (data.event) {
        .recv => std.posix.POLL.IN,
        .send => std.posix.POLL.OUT,
    };
    var pfd = [_]std.posix.pollfd{.{ .fd = data.handle, .events = want, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 0) catch 0;
    if (ready > 0 and (pfd[0].revents & (want | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
        c.setResult(.net_poll, {});
        state.markCompletedFromBackend(c);
        return;
    }
    park(self, state, data.handle, c);
}

const TestBackend = struct {
    socks: *Local = undefined,
    interest: Dirs = 0,
    interest_changes: usize = 0,

    const Event = struct { requeue: ?*Completion = null };
    const CheckResult = enum { completed, requeue };

    pub fn checkCompletion(c: *Completion, event: *const Event) CheckResult {
        if (c == event.requeue) return .requeue;
        c.setResult(.net_recv, 1);
        return .completed;
    }

    pub fn setInterest(self: *TestBackend, _: net.fd_t, old: Dirs, new: Dirs, _: Gen) bool {
        std.debug.assert(old == self.interest);
        self.interest = new;
        self.interest_changes += 1;
        return true;
    }

    pub fn forgetSocket(_: i32, _: net.fd_t) void {}
};

const TestState = struct {
    backend: *TestBackend,
    cancel_target: ?*Completion = null,
    detached: ?bool = null,
    finished: [4]?*Completion = @splat(null),
    finished_count: usize = 0,

    pub fn markCompletedFromBackend(self: *TestState, c: *Completion) void {
        if (self.cancel_target) |target| {
            if (self.detached == null) self.detached = detach(self.backend, target);
        }
        self.finished[self.finished_count] = c;
        self.finished_count += 1;
    }
};

fn testMask(table: *Table, fd: net.fd_t) u64 {
    return table.shardFor(Local.key(fd)).map.get(Local.key(fd)) orelse 0;
}

test "sockreg: cancel of an op that onEvent already finished leaves it alone" {
    // onEvent finishes A, B and C in one pass and leaves D parked. While it
    // completes A, a cancel of B (still linked in onEvent's finish list) must
    // report it as already claimed, and must not touch the waiter queue.
    const ReadBuf = @import("buf.zig").ReadBuf;
    const fd: net.fd_t = 42;

    var table: Table = .{};
    var backend: TestBackend = .{};
    backend.socks = try table.acquire(std.testing.allocator, TestBackend, -1);
    defer table.release(backend.socks);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var ops: [4]NetRecv = undefined;
    for (&ops) |*op| {
        op.* = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
        _ = op.c.enterRunning();
    }
    const a = &ops[0].c;
    const b = &ops[1].c;
    const c = &ops[2].c;
    const d = &ops[3].c;

    var state: TestState = .{ .backend = &backend, .cancel_target = b };
    for ([_]*Completion{ a, b, c, d }) |op| park(&backend, &state, fd, op);
    try std.testing.expectEqual(dirBit(.read), backend.interest);
    try std.testing.expectEqual(@as(u64, 1) << backend.socks.index, testMask(&table, fd));

    const gen = backend.socks.entries.get(Local.key(fd)).?.gen;
    onEvent(&backend, &state, fd, gen, dirBit(.read), &TestBackend.Event{ .requeue = d });

    try std.testing.expectEqual(false, state.detached.?);
    try std.testing.expectEqualSlices(?*Completion, &.{ a, b, c, null }, &state.finished);

    const waiters = &backend.socks.entries.getPtr(Local.key(fd)).?.waiters[@backingInt(Dir.read)];
    try std.testing.expectEqual(d, waiters.head.?);
    try std.testing.expectEqual(d, waiters.tail.?);
    try std.testing.expectEqual(null, d.next);
    try std.testing.expectEqual(null, d.prev);

    // D is still parked, so a cancel claims it.
    try std.testing.expect(detach(&backend, d));
    try std.testing.expectEqual(null, waiters.head);
}

test "sockreg: a registration is dropped after two edges with no waiter" {
    const ReadBuf = @import("buf.zig").ReadBuf;
    const fd: net.fd_t = 7;

    var table: Table = .{};
    var backend: TestBackend = .{};
    backend.socks = try table.acquire(std.testing.allocator, TestBackend, -1);
    defer table.release(backend.socks);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var op: NetRecv = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
    _ = op.c.enterRunning();

    var state: TestState = .{ .backend = &backend };
    park(&backend, &state, fd, &op.c);
    try std.testing.expect(detach(&backend, &op.c));
    const gen = backend.socks.entries.get(Local.key(fd)).?.gen;
    const event: TestBackend.Event = .{};

    // An event of an older registration of the same fd number is ignored.
    onEvent(&backend, &state, fd, gen +% 1, dirBit(.read), &event);
    try std.testing.expectEqual(dirBit(.read), backend.socks.entries.get(Local.key(fd)).?.used);

    // The first idle edge only takes away the second chance the park gave.
    onEvent(&backend, &state, fd, gen, dirBit(.read), &event);
    try std.testing.expectEqual(dirBit(.read), backend.interest);
    try std.testing.expectEqual(0, backend.socks.entries.get(Local.key(fd)).?.used);

    // The second one drops the registration, and the table forgets the loop.
    onEvent(&backend, &state, fd, gen, dirBit(.read), &event);
    try std.testing.expectEqual(0, backend.interest);
    try std.testing.expectEqual(null, backend.socks.entries.get(Local.key(fd)));
    try std.testing.expectEqual(0, testMask(&table, fd));
    try std.testing.expectEqual(0, state.finished_count);
}
