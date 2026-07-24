// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Shared cross-loop socket registration table (single-owner model).
//!
//! A socket fd is monitored in the poller (epoll/kqueue) of exactly *one* loop
//! per direction — the loop that first parked on that `(fd, direction)`. That
//! loop is the "owner": it gets the readiness edges and services every waiter,
//! including completions that were submitted on other loops and handed over at
//! submit time. This avoids registering the same fd on every loop's poller
//! (which task migration would otherwise cause) while staying correct when a
//! socket is driven from different loops over its life.
//!
//! The table is backend-agnostic: it tracks ownership, a per-direction edge
//! readiness latch, and the parked-completion queues. The actual poller syscall
//! (epoll_ctl / kevent) is issued by the backend while holding the fd's shard
//! lock. Read and write are tracked independently so a reader on loop A and a
//! writer on loop B can each own their own direction of the same socket.
//!
//! Entries are keyed by fd and live until the socket is closed (`removeFd`),
//! which any loop may call: closing the fd removes it from every poller at the
//! kernel level, so teardown only has to drop the software bookkeeping.

const std = @import("std");
const os = @import("../os/root.zig");
const net = @import("../os/net.zig");
const Loop = @import("loop.zig").Loop;
const Completion = @import("completion.zig").Completion;
const Op = @import("completion.zig").Op;
const NetConnect = @import("completion.zig").NetConnect;
const NetAccept = @import("completion.zig").NetAccept;
const NetRecv = @import("completion.zig").NetRecv;
const NetSend = @import("completion.zig").NetSend;
const NetRecvFrom = @import("completion.zig").NetRecvFrom;
const NetSendTo = @import("completion.zig").NetSendTo;
const NetRecvMsg = @import("completion.zig").NetRecvMsg;
const NetSendMsg = @import("completion.zig").NetSendMsg;
const NetPoll = @import("completion.zig").NetPoll;
const Queue = @import("queue.zig").Queue;
const log = @import("../common.zig").log;

pub const Dir = enum(u1) { read, write };

pub fn other(dir: Dir) Dir {
    return switch (dir) {
        .read => .write,
        .write => .read,
    };
}

/// Per-fd registration record. `owner`/`ready`/`waiters` are split per direction
/// but kept in one entry so a single shard lock covers the whole fd and a close
/// drops both directions at once.
pub const Entry = struct {
    /// The loop (opaque `*Loop`) whose poller has this fd registered for the
    /// direction, or null if no loop is registered for it yet.
    read_owner: ?*anyopaque = null,
    write_owner: ?*anyopaque = null,
    /// Edge-triggered readiness latch: set when an edge fired but no waiter
    /// consumed it, so a parker that raced the edge retries instead of sleeping.
    read_ready: bool = false,
    write_ready: bool = false,
    /// Completions parked on this fd/direction, serviced by the owner.
    read_waiters: Queue(Completion) = .{},
    write_waiters: Queue(Completion) = .{},

    pub fn ownerPtr(self: *Entry, dir: Dir) *?*anyopaque {
        return switch (dir) {
            .read => &self.read_owner,
            .write => &self.write_owner,
        };
    }

    pub fn readyPtr(self: *Entry, dir: Dir) *bool {
        return switch (dir) {
            .read => &self.read_ready,
            .write => &self.write_ready,
        };
    }

    pub fn waiters(self: *Entry, dir: Dir) *Queue(Completion) {
        return switch (dir) {
            .read => &self.read_waiters,
            .write => &self.write_waiters,
        };
    }

    /// Whether the entry has nothing left to track and can be dropped.
    pub fn isEmpty(self: *const Entry) bool {
        return self.read_owner == null and self.write_owner == null and
            self.read_waiters.head == null and self.write_waiters.head == null;
    }
};

const shard_count = 64; // power of two

pub const Shard = struct {
    mutex: os.Mutex = .init(),
    map: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
};

/// Sharded fd -> Entry table shared by every loop in a group. Loops acquire it
/// on init and release it on deinit; the maps are freed when the last loop goes.
pub const Table = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    allocator: std.mem.Allocator = undefined,
    shards: [shard_count]Shard = [_]Shard{.{}} ** shard_count,

    pub fn acquire(self: *Table, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) self.allocator = allocator;
        self.refcount += 1;
    }

    pub fn release(self: *Table) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refcount -= 1;
        if (self.refcount == 0) {
            for (&self.shards) |*shard| {
                shard.map.deinit(self.allocator);
                shard.map = .empty;
            }
        }
    }

    pub fn shardForFd(self: *Table, fd: i32) *Shard {
        const key: u32 = @bitCast(fd);
        return &self.shards[key & (shard_count - 1)];
    }
};

// ---- generic single-owner socket path ---------------------------------------
//
// The control flow below is identical for epoll and kqueue; only the poller
// syscalls differ. Each backend supplies four hooks and these helpers drive the
// shared registration/parking/servicing logic:
//
//   * checkCompletion(c, event) CheckResult  - run the op's syscall (free fn)
//   * probeEvent(fd, dir) Event              - a no-error event for the
//                                              optimistic attempt (free fn)
//   * self.registerSocket(fd, dir, other_owned_here) bool - arm this loop's
//                                              poller for (fd, dir)
//   * self.unregisterCleanup(fd) void        - drop this loop's poller entry
//
// `self` is the backend, `state` is its *LoopState.

pub const ParkResult = enum {
    /// Completion parked in the owner loop's waiter queue.
    parked,
    /// A readiness edge raced us; the caller should retry the syscall.
    retry,
    /// Registration/allocation failed; completion already finished with an error.
    failed,
};

pub fn isSocketOp(op: Op) bool {
    return switch (op) {
        .net_connect,
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_sendmsg,
        .net_poll,
        => true,
        else => false,
    };
}

/// Direction a socket op waits on.
pub fn dirForOp(c: *Completion) Dir {
    return switch (c.op) {
        .net_accept, .net_recv, .net_recvfrom, .net_recvmsg => .read,
        .net_connect, .net_send, .net_sendto, .net_sendmsg => .write,
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
        .net_sendmsg => c.cast(NetSendMsg).handle,
        .net_poll => c.cast(NetPoll).handle,
        else => unreachable,
    };
}

/// Park `completion` on the loop that owns `(fd, dir)`, registering this loop as
/// the owner if nobody is yet. If the owner is a different loop, the completion
/// (and its accounting) is migrated to it. Returns `.retry` if a readiness edge
/// raced the optimistic syscall.
pub fn park(self: anytype, state: anytype, fd: net.fd_t, completion: *Completion) ParkResult {
    const dir = dirForOp(completion);
    const self_loop: *Loop = state.loop;
    const self_opaque: *anyopaque = @ptrCast(self_loop);
    const table = &self.shared.sock_table;
    const shard = table.shardForFd(fd);

    shard.mutex.lock();
    const gop = shard.map.getOrPut(table.allocator, @as(u32, @bitCast(fd))) catch {
        shard.mutex.unlock();
        log.err("sock registration table OOM", .{});
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return .failed;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const entry = gop.value_ptr;
    const created = !gop.found_existing;

    // A readiness edge fired since our optimistic syscall: retry instead of
    // sleeping (the data the edge announced is still in the socket buffer).
    const ready = entry.readyPtr(dir);
    if (ready.*) {
        ready.* = false;
        if (created and entry.isEmpty()) _ = shard.map.remove(@as(u32, @bitCast(fd)));
        shard.mutex.unlock();
        return .retry;
    }

    const owner = entry.ownerPtr(dir);
    if (owner.* == null) {
        const other_owned_here = entry.ownerPtr(other(dir)).* == self_opaque;
        if (!self.registerSocket(fd, dir, other_owned_here)) {
            if (created and entry.isEmpty()) _ = shard.map.remove(@as(u32, @bitCast(fd)));
            shard.mutex.unlock();
            completion.setError(error.Unexpected);
            state.markCompletedFromBackend(completion);
            return .failed;
        }
        owner.* = self_opaque;
    }

    // The completion stays owned by its submitting loop: its `loop` field, timeout
    // timer, and cancel routing are unchanged. The owner loop only holds the
    // poller registration and services the op in place when its edge fires,
    // completing it cross-thread through the synchronized completion machinery.
    // Accounting balances regardless of which loop finishes the op (the owner on
    // a readiness edge, or the submitter on cancel/timeout): the active decrement
    // is routed to `completion.loop` and the inflight storage is group-shared.
    completion.prev = null;
    completion.next = null;
    entry.waiters(dir).push(completion);
    shard.mutex.unlock();
    return .parked;
}

/// Service ready waiters for one (fd, dir) on the owner loop. Runs each waiter's
/// syscall under the shard lock (non-blocking), collects the finished ones, then
/// completes them after unlocking (completing can resume a fiber re-entrantly).
pub fn service(self: anytype, state: anytype, fd: net.fd_t, dir: Dir, event: anytype) void {
    const Backend = @TypeOf(self.*);
    const shard = self.shared.sock_table.shardForFd(fd);
    shard.mutex.lock();
    const entry = shard.map.getPtr(@as(u32, @bitCast(fd))) orelse {
        shard.mutex.unlock();
        return;
    };

    var serviced_waiter = false;
    var to_finish: Queue(Completion) = .{};
    var iter: ?*Completion = entry.waiters(dir).head;
    while (iter) |c| {
        iter = c.next;
        if (c.loadState().phase != .running) {
            _ = entry.waiters(dir).remove(c);
            continue;
        }
        serviced_waiter = true;
        switch (Backend.checkCompletion(c, event)) {
            .completed => {
                _ = entry.waiters(dir).remove(c);
                to_finish.push(c);
            },
            .requeue => break, // drained to EAGAIN for this direction
        }
    }
    // Latch a readiness edge that no live waiter consumed so a racing parker
    // retries instead of sleeping for an edge that already passed. Stale
    // (completed/dead) waiters that were skipped above don't count — they
    // consume no edge, so a queue holding only stale waiters must still latch.
    entry.readyPtr(dir).* = !serviced_waiter;
    shard.mutex.unlock();

    while (to_finish.pop()) |c| {
        state.markCompletedFromBackend(c);
    }
}

/// Detach a parked socket completion from its owner's waiter queue (cancel).
///
/// Returns true if `target` was still parked and this call removed it, meaning
/// the caller now owns it and must finish it. Returns false if it was already
/// gone, i.e. `service` claimed it and is completing it with its natural result;
/// the caller must then leave it alone.
///
/// The shard lock makes that answer exact rather than advisory: `service` runs
/// the syscall and sets the result while holding the same lock it removes the
/// waiter under, so "still in the queue" and "no result set yet" are the same
/// condition. The reverse - inferring it from the `.completed` phase - would
/// race, because `service` deliberately marks the op completed only after
/// dropping the lock.
pub fn detach(self: anytype, target: *Completion) bool {
    const fd = netHandle(target);
    const dir = dirForOp(target);
    const shard = self.shared.sock_table.shardForFd(fd);
    shard.mutex.lock();
    defer shard.mutex.unlock();
    // A live parked op always has an entry: detach only runs while the op is not
    // yet completed (loop.cancel and cancelLocal both bail on the `.completed`
    // phase), and an entry is only dropped by `unregister` on close, which
    // cannot happen until the op completes and wakes its owner. So this branch is
    // unreachable in practice. Return false anyway (not true): a missing entry
    // could only mean the waiter was already removed - i.e. `service` is finishing
    // the op - so claiming it here would double-complete an op that is already on
    // its way out. Leaving it alone is the safe default.
    const entry = shard.map.getPtr(@as(u32, @bitCast(fd))) orelse return false;
    return entry.waiters(dir).remove(target);
}

/// Tear down the shared registration for a socket fd about to be closed. Closing
/// the fd removes it from every poller at the kernel level, so this only drops
/// the software bookkeeping (for all loops at once) plus this loop's poller entry.
pub fn unregister(self: anytype, fd: net.fd_t) void {
    const shard = self.shared.sock_table.shardForFd(fd);
    shard.mutex.lock();
    if (shard.map.getPtr(@as(u32, @bitCast(fd)))) |entry| {
        // Closing an fd with ops still parked on it would orphan those
        // completions (removed here without finishing) and leak their
        // active/inflight accounting. The contract is that callers cancel or
        // await outstanding socket ops before closing the fd; assert it so a
        // violation surfaces in safe builds rather than silently leaking.
        std.debug.assert(entry.waiters(.read).head == null);
        std.debug.assert(entry.waiters(.write).head == null);
    }
    _ = shard.map.remove(@as(u32, @bitCast(fd)));
    shard.mutex.unlock();
    self.unregisterCleanup(fd);
}

/// Generic submit for socket read/write/accept-family ops: try the syscall
/// optimistically (reusing checkCompletion with a no-error event) and only park
/// on WouldBlock. Draining to EAGAIN first is what makes edge-triggered safe.
pub fn submitIo(self: anytype, state: anytype, c: *Completion) void {
    const Backend = @TypeOf(self.*);
    const fd = netHandle(c);
    const dir = dirForOp(c);
    var probe = Backend.probeEvent(fd, dir);
    while (true) {
        switch (Backend.checkCompletion(c, &probe)) {
            .completed => {
                // Inline finish (flags permitting) lets a bulk sender batch
                // until WouldBlock instead of paying a poll per chunk (#525).
                state.markCompletedFromBackend(c);
                return;
            },
            .requeue => switch (park(self, state, fd, c)) {
                .parked, .failed => return,
                .retry => {}, // loop and retry the syscall
            },
        }
    }
}

/// Generic connect submit: try connect() first, register on WouldBlock.
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
    switch (park(self, state, data.handle, c)) {
        .parked, .failed => {},
        .retry => {
            // The socket became writable while we raced: the connect finished.
            if (net.getSockError(data.handle)) |se| {
                if (se == 0) c.setResult(.net_connect, {}) else c.setError(net.errnoToConnectError(@enumFromInt(se)));
            } else |_| c.setError(error.Unexpected);
            state.markCompletedFromBackend(c);
        },
    }
}

/// Generic net_poll submit: probe readiness with a 0-timeout poll() (it has no
/// I/O to drain, so it cannot rely on a fresh edge for an already-ready socket),
/// and register for an edge only when not ready.
pub fn submitPoll(self: anytype, state: anytype, c: *Completion) void {
    const data = c.cast(NetPoll);
    const want: i16 = switch (data.event) {
        .recv => std.posix.POLL.IN,
        .send => std.posix.POLL.OUT,
    };
    while (true) {
        var pfd = [_]std.posix.pollfd{.{ .fd = data.handle, .events = want, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 0) catch 0;
        if (ready > 0 and (pfd[0].revents & (want | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
            c.setResult(.net_poll, {});
            state.markCompletedFromBackend(c);
            return;
        }
        switch (park(self, state, data.handle, c)) {
            .parked, .failed => return,
            .retry => {}, // re-probe
        }
    }
}
