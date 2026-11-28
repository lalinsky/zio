// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Per-loop readiness registrations of pollable fds (sockets, pipes, ttys,
//! pidfds) for the edge-triggered backends (epoll, kqueue).
//!
//! Each loop registers an fd with its own poller, edge-triggered, the first
//! time one of its own completions waits on it, and only ever services its own
//! completions, on its own thread. An fd used from several loops is registered
//! with each of them, and every readiness edge reaches every poller it is
//! registered with.
//!
//! A registration a socket op created is persistent: it stays while the socket
//! is in use, so a connection doing I/O pays no poller syscall per wait. Every
//! other registration is transient: a direction is removed as soon as no
//! completion waits in it. Pipes are often closed by code that does not go
//! through zio (the spawning of a child process, for one), so a registration
//! left in place could outlive the fd and keep firing for whatever reuses its
//! number. An entry keeps the mode it was created with, whatever else parks on
//! it later.
//!
//! No wakeup can be lost: a completion parks only after its own syscall (or a
//! readiness probe) saw the fd not ready, on its loop's thread, or on an fd new
//! to the loop. Anything that arrives after that raises an edge in this loop's
//! poller, which the loop cannot harvest before it returns to its poll, so not
//! before the completion is parked. Registering an fd, or adding a direction to
//! it, reports readiness that already exists.
//!
//! A persistent registration no local completion uses any more is dropped in
//! two ways.
//! When a loop registers a socket for a direction, it removes that direction
//! from the registrations of other loops with nothing parked in it: a task
//! that moved to this loop took the socket's I/O along, and a registration left
//! behind would make every edge run the kernel's wakeup callback twice and wake
//! the old loop for nothing. Loops using the socket in different directions (a
//! reader and a writer task) keep their registrations.
//! A socket that simply goes quiet is dropped by its own loop: every park sets
//! its direction's `used` bit, an edge that finds no waiter in that direction
//! clears the bit, and a second such edge removes the direction from the
//! poller.
//!
//! The group-shared `Holders` records which loops have a socket registered
//! persistently, so that closing it, from any thread, can remove it from each
//! of their pollers before the fd is gone, and so that a loop registering it
//! can find the other loops' registrations. The fd is the only handle a
//! registration can be removed by, and an epoll registration on a description
//! that outlives the close (dup, fork) would otherwise keep firing for
//! whatever reuses the fd number. Every close zio performs (socket, file and
//! pipe) purges; an fd closed behind zio's back while a loop has it registered
//! leaves a stale entry, and an op on a new fd with the same number may then
//! never wake.

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
const PipePoll = @import("completion.zig").PipePoll;
const FileReadStreaming = @import("completion.zig").FileReadStreaming;
const FileWriteStreaming = @import("completion.zig").FileWriteStreaming;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const Queue = @import("queue.zig").Queue;
const log = @import("../common.zig").log;

/// Error a poller reports for a registration change.
pub const E = os.posix.sys.E;

pub const Dir = enum(u1) { read, write };

/// A set of directions, one bit per `Dir`.
pub const Dirs = u2;

pub fn dirBit(dir: Dir) Dirs {
    return @as(Dirs, 1) << @backingInt(dir);
}

/// Most loops one group can have with fd registrations (see `LoopGroup`).
pub const max_loops = 64;

/// Width of a registration's generation, as carried in the poller's event data
/// (epoll's u64 above the fd and the registration tag, kqueue's udata on 32-bit
/// too). It wraps; an event can only be misattributed after a stale kernel
/// registration survived 2^30 registrations of the same fd number on one loop.
pub const gen_bits = 30;
pub const Gen = @Int(.unsigned, gen_bits);

/// Changes the directions `fd` is registered for in the poller `poller_fd` from
/// `old` to `new` (adding, modifying, or removing it), from any thread. A
/// delete that finds the registration already gone succeeds.
pub const ChangeFn = *const fn (poller_fd: i32, fd: net.fd_t, old: Dirs, new: Dirs, gen: Gen) E;

/// Completions parked on an fd in one direction, oldest first: a list
/// doubly linked through the completions' `prev` and `next`, whose head's
/// `prev` points to its tail. One pointer per direction keeps an `Entry` small,
/// with pushing at the tail and removing any member still O(1).
pub const WaitList = struct {
    head: ?*Completion = null,

    pub fn isEmpty(self: WaitList) bool {
        return self.head == null;
    }

    pub fn push(self: *WaitList, c: *Completion) void {
        std.debug.assert(c.next == null and c.prev == null);
        if (self.head) |head| {
            const tail = head.prev.?;
            tail.next = c;
            c.prev = tail;
            head.prev = c;
        } else {
            c.prev = c;
            self.head = c;
        }
    }

    /// Remove `c`, which must be in this list.
    pub fn remove(self: *WaitList, c: *Completion) void {
        const head = self.head.?;
        if (c == head) {
            self.head = c.next;
            if (c.next) |next| next.prev = c.prev;
        } else {
            c.prev.?.next = c.next;
            if (c.next) |next| next.prev = c.prev else head.prev = c.prev;
        }
        c.prev = null;
        c.next = null;
    }
};

/// One loop's registration of one fd.
pub const Entry = struct {
    /// Completions of this loop parked on the fd, per direction.
    waiters: [2]WaitList = .{ .{}, .{} },
    /// Directions registered with this loop's poller.
    registered: Dirs = 0,
    /// Directions a completion parked on since the last edge that found no
    /// waiter in them.
    used: Dirs = 0,
    /// Tags this registration's events, so an event harvested before the fd was
    /// closed and its number reused is not applied to the new one.
    gen: Gen,
    /// Remove each direction as soon as no completion waits in it; such an
    /// entry is not recorded in `Holders`.
    transient: bool = false,

    /// Directions with a completion parked in them.
    fn waiting(self: *const Entry) Dirs {
        var dirs: Dirs = 0;
        if (!self.waiters[0].isEmpty()) dirs |= dirBit(.read);
        if (!self.waiters[1].isEmpty()) dirs |= dirBit(.write);
        return dirs;
    }
};

fn fdKey(fd: net.fd_t) u32 {
    return @bitCast(fd);
}

/// One loop's registrations. Only the loop's own thread touches it, except a
/// close, which may run on any thread, and another loop registering one of its
/// sockets (`Holders.claim`); the mutex is for those.
pub const FdTable = struct {
    mutex: os.Mutex = .init(),
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    next_gen: Gen = 0,
    /// Bit of this loop in the `Holders` per-fd masks.
    index: u6,
    /// The poller (epoll or kqueue fd) the registrations live in.
    poller_fd: i32,
    holders: *Holders,

    /// Change the directions of `entry` registered with this loop's poller to
    /// `new`, logging a failure. The entry follows either way: a registration
    /// the poller kept despite a failed removal only costs spurious edges.
    fn setRegistered(self: *FdTable, fd: net.fd_t, entry: *Entry, new: Dirs) void {
        const err = self.holders.change_fn(self.poller_fd, fd, entry.registered, new, entry.gen);
        if (err != .SUCCESS) log.err("failed to remove an fd registration: {}", .{err});
        entry.registered = new;
        entry.used &= new;
    }

    /// Drop `fd` for a close. The `Holders` mask bit is already gone.
    fn purge(self: *FdTable, fd: net.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const removed = self.entries.fetchRemove(fdKey(fd)) orelse return;
        // Closing an fd with ops still parked on it would orphan those
        // completions (removed here without finishing) and leak their
        // active/inflight accounting. The contract is that callers cancel or
        // await outstanding ops before closing the fd; assert it so a
        // violation surfaces in safe builds rather than silently leaking.
        std.debug.assert(removed.value.waiting() == 0);
        if (removed.value.registered != 0 and !self.holders.close_drops) {
            _ = self.holders.change_fn(self.poller_fd, fd, removed.value.registered, 0, removed.value.gen);
        }
    }
};

const shard_count = 64; // power of two

const Shard = struct {
    mutex: os.Mutex = .init(),
    /// fd -> mask of the loops (`FdTable.index`) that have it registered.
    map: std.AutoHashMapUnmanaged(u32, u64) = .empty,
};

/// Per-group record of which loops have which sockets registered. Loops acquire
/// it on init and release it on deinit. A `Holders` with live loops is linked
/// into `live_holders`, so a socket closed by a thread that runs no loop can
/// still be purged from it (`purgeAll`).
///
/// Lock order: a shard's mutex, then an `FdTable`'s. A loop never holds its own
/// mutex while taking a shard's.
pub const Holders = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    /// The first loop's allocator, used for every loop's table; it must be
    /// thread-safe and outlive the group.
    allocator: std.mem.Allocator = undefined,
    shards: [shard_count]Shard = @splat(.{}),
    tables: [max_loops]?*FdTable = @splat(null),
    /// Link in `live_holders`, guarded by `live_holders_mutex`.
    next_live: ?*Holders = null,
    /// The backend's `changeInterest`. Every loop of a group runs the same
    /// backend, so the first one to acquire sets it.
    change_fn: ChangeFn = undefined,
    /// The backend's `close_drops_registrations`: whether closing an fd removes
    /// it from the pollers by itself.
    close_drops: bool = false,

    /// Register a loop whose poller is `poller_fd`.
    pub fn acquire(self: *Holders, allocator: std.mem.Allocator, comptime Backend: type, poller_fd: i32) error{ OutOfMemory, TooManyLoops }!*FdTable {
        live_holders_mutex.lock();
        defer live_holders_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) {
            self.allocator = allocator;
            self.change_fn = Backend.changeInterest;
            self.close_drops = Backend.close_drops_registrations;
        }
        const index = std.mem.indexOfScalar(?*FdTable, &self.tables, null) orelse return error.TooManyLoops;
        const table = try self.allocator.create(FdTable);
        table.* = .{ .index = @intCast(index), .poller_fd = poller_fd, .holders = self };
        self.tables[index] = table;
        if (self.refcount == 0) {
            self.next_live = live_holders;
            @atomicStore(?*Holders, &live_holders, self, .release);
        }
        self.refcount += 1;
        return table;
    }

    /// Unregister a loop. Its poller is about to be closed, which drops its
    /// registrations in the kernel; this drops them from `Holders`.
    pub fn release(self: *Holders, table: *FdTable) void {
        // Clear the loop's bits from the masks rather than walking its entries:
        // a close on another thread may be removing entries meanwhile. Once a
        // shard has no bit of this loop, no purge reaches `table` through it.
        // A mask left at zero is dropped by the fd's close.
        const bit = @as(u64, 1) << table.index;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            var it = shard.map.valueIterator();
            while (it.next()) |mask| mask.* &= ~bit;
        }

        live_holders_mutex.lock();
        defer live_holders_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.tables[table.index] = null;
        table.entries.deinit(self.allocator);
        self.allocator.destroy(table);
        self.refcount -= 1;
        if (self.refcount == 0) {
            var link: *?*Holders = &live_holders;
            while (link.*) |holders| : (link = &holders.next_live) {
                if (holders == self) {
                    @atomicStore(?*Holders, link, self.next_live, .release);
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

    fn shardFor(self: *Holders, key: u32) *Shard {
        return &self.shards[key & (shard_count - 1)];
    }

    /// Remove `fd` from every loop that has it registered. Must run before the
    /// fd is closed.
    pub fn purge(self: *Holders, fd: net.fd_t) void {
        const shard = self.shardFor(fdKey(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        const removed = shard.map.fetchRemove(fdKey(fd)) orelse return;
        var mask = removed.value;
        // Under the shard mutex, so a loop's `release` (which clears its bits
        // under the same mutex first) cannot free an `FdTable` we reach here.
        while (mask != 0) : (mask &= mask - 1) {
            const index: u6 = @intCast(@ctz(mask));
            self.tables[index].?.purge(fd);
        }
    }

    /// Record that loop `index` has `fd` registered, now including the
    /// directions `dirs`, and remove those directions from the registrations
    /// of the other loops that have nothing parked in them. Returns false,
    /// recording nothing, when out of memory.
    fn claim(self: *Holders, fd: net.fd_t, index: u6, dirs: Dirs) bool {
        const shard = self.shardFor(fdKey(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        const gop = shard.map.getOrPut(self.allocator, fdKey(fd)) catch return false;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const mask = gop.value_ptr;
        mask.* |= @as(u64, 1) << index;
        var others = mask.* & ~(@as(u64, 1) << index);
        while (others != 0) : (others &= others - 1) {
            const other_index: u6 = @intCast(@ctz(others));
            // Under the shard mutex, as in `purge`.
            const other = self.tables[other_index].?;
            other.mutex.lock();
            defer other.mutex.unlock();
            const entry = other.entries.getPtr(fdKey(fd)) orelse continue;
            const idle = entry.registered & dirs & ~entry.waiting();
            if (idle == 0) continue;
            // An edge of this registration already harvested by the other loop
            // finds the direction unregistered, no entry, or one of a later
            // registration with another generation, and is ignored.
            other.setRegistered(fd, entry, entry.registered & ~idle);
            if (entry.registered == 0) {
                _ = other.entries.remove(fdKey(fd));
                mask.* &= ~(@as(u64, 1) << other_index);
            }
        }
        return true;
    }

    fn unsetBit(self: *Holders, fd: net.fd_t, bit: u64) void {
        const shard = self.shardFor(fdKey(fd));
        shard.mutex.lock();
        defer shard.mutex.unlock();
        const mask = shard.map.getPtr(fdKey(fd)) orelse return;
        mask.* &= ~bit;
        if (mask.* == 0) _ = shard.map.remove(fdKey(fd));
    }
};

var live_holders_mutex: os.Mutex = .init();
/// Written under `live_holders_mutex`, read without it by `purgeAll` to skip
/// the mutex when no loop has a table.
var live_holders: ?*Holders = null;

/// Purge `fd` from every live `Holders`, for a close that does not run on a
/// loop and so does not know which group the fd was used in. A group that
/// becomes live during the call cannot have registered an fd being closed.
pub fn purgeAll(fd: net.fd_t) void {
    if (@atomicLoad(?*Holders, &live_holders, .acquire) == null) return;
    live_holders_mutex.lock();
    defer live_holders_mutex.unlock();
    var it = live_holders;
    while (it) |holders| : (it = holders.next_live) holders.purge(fd);
}

// ---- generic fd path --------------------------------------------------------
//
// The control flow below is identical for epoll and kqueue; only the poller
// syscalls differ. Each backend supplies these:
//
//   * checkCompletion(c, event) CheckResult  - run the op's syscall
//   * probeEvent(fd, dir) Event              - a no-error event for the
//                                              optimistic attempt
//   * changeInterest: ChangeFn               - change a registration in any
//                                              loop's poller
//   * failRegistration(c, err) void          - set the result of an op that
//                                              could not be parked because
//                                              registering failed with `err`
//   * close_drops_registrations: bool        - whether closing an fd removes it
//                                              from every poller
//
// `self` is the backend, with its `FdTable` in `self.fds`; `state` is its
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

/// Direction an op on a pollable fd waits on.
pub fn dirForOp(c: *Completion) Dir {
    return switch (c.op) {
        .net_accept, .net_recv, .net_recvfrom, .net_recvmsg, .net_recvmmsg => .read,
        .net_connect, .net_send, .net_sendto, .net_sendmsg, .net_sendmmsg, .net_send_file => .write,
        .net_poll => switch (c.cast(NetPoll).event) {
            .recv => .read,
            .send => .write,
        },
        .pipe_poll => switch (c.cast(PipePoll).event) {
            .read => .read,
            .write => .write,
        },
        .file_read_streaming => .read,
        .file_write_streaming => .write,
        else => unreachable,
    };
}

/// The fd an op on a pollable fd waits on.
pub fn handleOf(c: *Completion) net.fd_t {
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
        .pipe_poll => c.cast(PipePoll).handle,
        .file_read_streaming => c.cast(FileReadStreaming).handle,
        .file_write_streaming => c.cast(FileWriteStreaming).handle,
        else => unreachable,
    };
}

/// Park `completion` in this loop's waiters for `fd` in direction `dir`,
/// registering the fd (or the direction) with this loop's poller if it is not
/// yet. If that fails, finishes the completion through the backend's
/// `failRegistration` instead.
pub fn park(self: anytype, state: anytype, completion: *Completion, fd: net.fd_t, dir: Dir) void {
    const Backend = @TypeOf(self.*);
    const table: *FdTable = self.fds;
    const bit = dirBit(dir);

    table.mutex.lock();
    const gop = table.entries.getOrPut(table.holders.allocator, fdKey(fd)) catch {
        table.mutex.unlock();
        log.err("fd registration table OOM", .{});
        Backend.failRegistration(completion, .NOMEM);
        state.markCompletedFromBackend(completion);
        return;
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .gen = table.next_gen, .transient = !isSocketOp(completion.op) };
        table.next_gen +%= 1;
    }
    const entry = gop.value_ptr;
    const added = bit & ~entry.registered;
    const claims = added != 0 and !entry.transient;
    if (added != 0) {
        const err = Backend.changeInterest(table.poller_fd, fd, entry.registered, entry.registered | bit, entry.gen);
        if (err != .SUCCESS) {
            if (entry.registered == 0) _ = table.entries.remove(fdKey(fd));
            table.mutex.unlock();
            Backend.failRegistration(completion, err);
            state.markCompletedFromBackend(completion);
            return;
        }
        entry.registered |= bit;
    }
    entry.used |= bit;
    completion.prev = null;
    completion.next = null;
    entry.waiters[@backingInt(dir)].push(completion);
    table.mutex.unlock();

    // `Holders` only needs the bit by the time the socket is closed, and a
    // close cannot race an op parked on it; set it outside the loop's mutex to
    // keep the lock order (see `Holders`). Another loop's claim cannot remove
    // this entry meanwhile: the completion just parked in it keeps it.
    if (claims and !table.holders.claim(fd, table.index, bit)) {
        // Without the bit a close would leave the registration behind, so undo
        // the direction just added. Nothing else can have touched the entry:
        // only this thread parks or services on it, and another loop's claim
        // leaves directions with a waiter alone.
        log.err("fd registration holders OOM", .{});
        table.mutex.lock();
        const entry_now = table.entries.getPtr(fdKey(fd)).?;
        entry_now.waiters[@backingInt(dir)].remove(completion);
        table.setRegistered(fd, entry_now, entry_now.registered & ~bit);
        if (entry_now.registered == 0) _ = table.entries.remove(fdKey(fd));
        table.mutex.unlock();
        Backend.failRegistration(completion, .NOMEM);
        state.markCompletedFromBackend(completion);
    }
}

/// Handle a readiness event for `fd` on this loop: service the parked
/// completions in the `ready` directions, or count an idle edge where there are
/// none. Runs each waiter's syscall under the loop's mutex (non-blocking),
/// collects the finished ones, then completes them after unlocking (completing
/// can run callbacks that submit, cancel or close re-entrantly).
pub fn onEvent(self: anytype, state: anytype, fd: net.fd_t, gen: Gen, ready: Dirs, event: anytype) void {
    const Backend = @TypeOf(self.*);
    const table: *FdTable = self.fds;
    var to_finish: Queue(Completion) = .{};
    var dropped = false;

    table.mutex.lock();
    if (table.entries.getPtr(fdKey(fd))) |entry| if (entry.gen == gen) {
        // An event reports every registered direction that is ready, not only
        // the one whose edge raised it (epoll), and a socket is writable most
        // of the time. Only an event of a single direction counts as an idle
        // edge of it, so the reads of a socket do not drop its write
        // registration, nor its writes the read one.
        const ready_registered = ready & entry.registered;
        inline for (.{ Dir.read, Dir.write }) |dir| {
            const bit = dirBit(dir);
            if (ready_registered & bit != 0) {
                const waiters = &entry.waiters[@backingInt(dir)];
                if (waiters.isEmpty()) {
                    // A transient direction is removed with its last waiter.
                    std.debug.assert(!entry.transient);
                    if (ready_registered == bit) {
                        if (entry.used & bit != 0) {
                            entry.used &= ~bit;
                        } else {
                            table.setRegistered(fd, entry, entry.registered & ~bit);
                        }
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
                                waiters.remove(c);
                                to_finish.push(c);
                            },
                            .requeue => {
                                std.debug.assert(!c.has_result);
                                break; // not ready for this direction
                            },
                        }
                    }
                    if (entry.transient) dropIfIdle(table, fd, entry, dir);
                }
            }
        }
        if (entry.registered == 0) {
            std.debug.assert(entry.waiting() == 0);
            dropped = !entry.transient;
            _ = table.entries.remove(fdKey(fd));
        }
    };
    table.mutex.unlock();

    if (dropped) table.holders.unsetBit(fd, @as(u64, 1) << table.index);

    while (to_finish.pop()) |c| {
        state.markCompletedFromBackend(c);
    }
}

/// Remove `dir` of a transient registration from the poller once no completion
/// waits in it. Called with the loop's mutex held; the caller removes the entry
/// when nothing is left registered.
fn dropIfIdle(table: *FdTable, fd: net.fd_t, entry: *Entry, dir: Dir) void {
    const bit = dirBit(dir);
    if (entry.waiting() & bit != 0 or entry.registered & bit == 0) return;
    table.setRegistered(fd, entry, entry.registered & ~bit);
}

/// Detach a completion parked on `fd` in direction `dir` from this loop's
/// waiters (cancel).
///
/// Returns true if `target` was still parked and this call removed it, meaning
/// the caller now owns it and must finish it. Returns false if it was already
/// gone: `onEvent` claimed it and is completing it with its natural result, and
/// a callback it ran is canceling it re-entrantly. The caller must then leave it
/// alone.
///
/// The answer is taken from `has_result`, not from the links: an op `onEvent`
/// claimed sits in its private finish list, whose links it rewrites after
/// unlocking, so they cannot tell whether it is still parked.
pub fn detach(self: anytype, target: *Completion, fd: net.fd_t, dir: Dir) bool {
    const table: *FdTable = self.fds;
    table.mutex.lock();
    defer table.mutex.unlock();
    if (target.has_result) return false;
    // An op without a result is parked here: it was submitted on this loop, and
    // its entry can only go away with its last waiter, or when the fd is
    // closed, which the caller must not do with ops still in flight.
    const entry = table.entries.getPtr(fdKey(fd)) orelse return false;
    entry.waiters[@backingInt(dir)].remove(target);
    if (entry.transient) {
        dropIfIdle(table, fd, entry, dir);
        if (entry.registered == 0) _ = table.entries.remove(fdKey(fd));
    }
    return true;
}

/// Remove an fd that is about to be closed from every loop of this loop's
/// group. Only persistent registrations can outlive their waiters, so this
/// finds only sockets, but any close calls it: a socket can be closed as a file
/// or a pipe.
pub fn purge(self: anytype, fd: net.fd_t) void {
    const table: *FdTable = self.fds;
    table.holders.purge(fd);
}

/// Generic submit for ops with a syscall of their own (socket reads, writes
/// and accepts, streaming reads and writes of other pollable fds): try the
/// syscall optimistically (reusing checkCompletion with a no-error event) and
/// only park on WouldBlock.
pub fn submitIo(self: anytype, state: anytype, c: *Completion) void {
    const Backend = @TypeOf(self.*);
    const fd = handleOf(c);
    const dir = dirForOp(c);
    var probe = Backend.probeEvent(fd, dir);
    switch (Backend.checkCompletion(c, &probe)) {
        // Inline finish (flags permitting) lets a bulk sender batch until
        // WouldBlock instead of paying a poll per chunk (#525).
        .completed => state.markCompletedFromBackend(c),
        .requeue => park(self, state, c, fd, dir),
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
    park(self, state, c, data.handle, .write);
}

/// Generic submit for readiness waits (net_poll, pipe_poll): probe readiness
/// with a 0-timeout poll(), since they have no syscall of their own to see
/// whether the fd is ready, and park only when it is not (or the probe failed,
/// leaving the answer to the poller).
pub fn submitPoll(self: anytype, state: anytype, c: *Completion) void {
    const fd = handleOf(c);
    const dir = dirForOp(c);
    const want: i16 = switch (dir) {
        .read => std.posix.POLL.IN,
        .write => std.posix.POLL.OUT,
    };
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = want, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 0) catch |err| blk: {
        log.debug("readiness probe failed: {}", .{err});
        break :blk 0;
    };
    if (ready > 0 and (pfd[0].revents & (want | std.posix.POLL.ERR | std.posix.POLL.HUP)) != 0) {
        switch (c.op) {
            .net_poll => c.setResult(.net_poll, {}),
            .pipe_poll => c.setResult(.pipe_poll, {}),
            else => unreachable,
        }
        state.markCompletedFromBackend(c);
        return;
    }
    park(self, state, c, fd, dir);
}

const TestBackend = struct {
    fds: *FdTable = undefined,

    const Event = struct { requeue: ?*Completion = null };
    const CheckResult = enum { completed, requeue };

    pub const close_drops_registrations = false;

    /// Directions registered with each test poller, indexed by poller fd.
    var interest: [3]Dirs = @splat(0);
    /// Make every change that adds a direction fail.
    var fail_add: bool = false;

    fn reset() void {
        interest = @splat(0);
        fail_add = false;
    }

    fn init(holders: *Holders, poller_fd: i32) !TestBackend {
        return .{ .fds = try holders.acquire(std.testing.allocator, TestBackend, poller_fd) };
    }

    pub fn checkCompletion(c: *Completion, event: *const Event) CheckResult {
        if (c == event.requeue) return .requeue;
        switch (c.op) {
            .net_recv => c.setResult(.net_recv, 1),
            .net_send => c.setResult(.net_send, 1),
            .file_read_streaming => c.setResult(.file_read_streaming, 1),
            else => unreachable,
        }
        return .completed;
    }

    pub fn changeInterest(poller_fd: i32, _: net.fd_t, old: Dirs, new: Dirs, _: Gen) E {
        const i: usize = @intCast(poller_fd);
        std.debug.assert(old == interest[i]);
        if (fail_add and new & ~old != 0) return .NOSPC;
        interest[i] = new;
        return .SUCCESS;
    }

    pub fn failRegistration(c: *Completion, _: E) void {
        c.setError(error.Unexpected);
    }
};

const TestState = struct {
    backend: *TestBackend,
    cancel_target: ?*Completion = null,
    detached: ?bool = null,
    finished: [4]?*Completion = @splat(null),
    finished_count: usize = 0,

    pub fn markCompletedFromBackend(self: *TestState, c: *Completion) void {
        if (self.cancel_target) |target| {
            if (self.detached == null) self.detached = testDetach(self.backend, target);
        }
        self.finished[self.finished_count] = c;
        self.finished_count += 1;
    }
};

fn testPark(backend: *TestBackend, state: *TestState, c: *Completion) void {
    park(backend, state, c, handleOf(c), dirForOp(c));
}

fn testDetach(backend: *TestBackend, c: *Completion) bool {
    return detach(backend, c, handleOf(c), dirForOp(c));
}

fn testMask(holders: *Holders, fd: net.fd_t) u64 {
    return holders.shardFor(fdKey(fd)).map.get(fdKey(fd)) orelse 0;
}

fn testEntry(backend: *TestBackend, fd: net.fd_t) ?Entry {
    return backend.fds.entries.get(fdKey(fd));
}

test "readiness: cancel of an op that onEvent already finished leaves it alone" {
    // onEvent finishes A, B and C in one pass and leaves D parked. While it
    // completes A, a cancel of B (still linked in onEvent's finish list) must
    // report it as already claimed, and must not touch the waiter queue.
    const fd: net.fd_t = 42;
    TestBackend.reset();

    var holders: Holders = .{};
    var backend: TestBackend = try .init(&holders, 0);
    defer holders.release(backend.fds);

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
    for ([_]*Completion{ a, b, c, d }) |op| testPark(&backend, &state, op);
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);
    try std.testing.expectEqual(@as(u64, 1) << backend.fds.index, testMask(&holders, fd));

    const gen = testEntry(&backend, fd).?.gen;
    onEvent(&backend, &state, fd, gen, dirBit(.read), &TestBackend.Event{ .requeue = d });

    try std.testing.expectEqual(false, state.detached.?);
    try std.testing.expectEqualSlices(?*Completion, &.{ a, b, c, null }, &state.finished);

    const waiters = &backend.fds.entries.getPtr(fdKey(fd)).?.waiters[@backingInt(Dir.read)];
    try std.testing.expectEqual(d, waiters.head.?);
    try std.testing.expectEqual(null, d.next);
    try std.testing.expectEqual(d, d.prev); // the head's prev is the tail

    // D is still parked, so a cancel claims it.
    try std.testing.expect(testDetach(&backend, d));
    try std.testing.expect(waiters.isEmpty());
}

test "readiness: a registration is dropped after two edges with no waiter" {
    const fd: net.fd_t = 7;
    TestBackend.reset();

    var holders: Holders = .{};
    var backend: TestBackend = try .init(&holders, 0);
    defer holders.release(backend.fds);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var op: NetRecv = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
    _ = op.c.enterRunning();

    var state: TestState = .{ .backend = &backend };
    testPark(&backend, &state, &op.c);
    try std.testing.expect(testDetach(&backend, &op.c));
    const gen = testEntry(&backend, fd).?.gen;
    const event: TestBackend.Event = .{};

    // An event of an older registration of the same fd number is ignored.
    onEvent(&backend, &state, fd, gen +% 1, dirBit(.read), &event);
    try std.testing.expectEqual(dirBit(.read), testEntry(&backend, fd).?.used);

    // The first idle edge only takes away the second chance the park gave.
    onEvent(&backend, &state, fd, gen, dirBit(.read), &event);
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);
    try std.testing.expectEqual(0, testEntry(&backend, fd).?.used);

    // The second one drops the registration, and `Holders` forgets the loop.
    onEvent(&backend, &state, fd, gen, dirBit(.read), &event);
    try std.testing.expectEqual(0, TestBackend.interest[0]);
    try std.testing.expectEqual(null, testEntry(&backend, fd));
    try std.testing.expectEqual(0, testMask(&holders, fd));
    try std.testing.expectEqual(0, state.finished_count);
}

test "readiness: an event of both directions is no idle edge of either" {
    const fd: net.fd_t = 8;
    TestBackend.reset();

    var holders: Holders = .{};
    var backend: TestBackend = try .init(&holders, 0);
    defer holders.release(backend.fds);

    var rbuf: [1]u8 = undefined;
    var riov: [1]os.iovec = undefined;
    var recv: NetRecv = .init(fd, ReadBuf.fromSlice(&rbuf, &riov), .{});
    _ = recv.c.enterRunning();
    var wiov: [1]os.iovec_const = undefined;
    var send: NetSend = .init(fd, WriteBuf.fromSlice("x", &wiov), .{});
    _ = send.c.enterRunning();

    // A send parked once and went away; a receive is parked.
    var state: TestState = .{ .backend = &backend };
    testPark(&backend, &state, &send.c);
    try std.testing.expect(testDetach(&backend, &send.c));
    testPark(&backend, &state, &recv.c);
    const both = dirBit(.read) | dirBit(.write);
    try std.testing.expectEqual(both, TestBackend.interest[0]);
    const gen = testEntry(&backend, fd).?.gen;

    // Readable and writable at once, as epoll reports a read edge of a socket
    // with room in its send buffer: the write registration stays untouched.
    onEvent(&backend, &state, fd, gen, both, &TestBackend.Event{});
    try std.testing.expectEqual(1, state.finished_count);
    try std.testing.expectEqual(both, testEntry(&backend, fd).?.used);
    onEvent(&backend, &state, fd, gen, both, &TestBackend.Event{});
    try std.testing.expectEqual(both, TestBackend.interest[0]);

    // Edges of the write direction alone do count.
    onEvent(&backend, &state, fd, gen, dirBit(.write), &TestBackend.Event{});
    onEvent(&backend, &state, fd, gen, dirBit(.write), &TestBackend.Event{});
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);
}

test "readiness: registering a socket drops other loops' idle registrations of it" {
    const fd: net.fd_t = 9;
    TestBackend.reset();

    var holders: Holders = .{};
    var old: TestBackend = try .init(&holders, 0);
    defer holders.release(old.fds);
    var busy: TestBackend = try .init(&holders, 1);
    defer holders.release(busy.fds);
    var new: TestBackend = try .init(&holders, 2);
    defer holders.release(new.fds);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var ops: [3]NetRecv = undefined;
    for (&ops) |*op| {
        op.* = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
        _ = op.c.enterRunning();
    }

    // `busy` has a receive parked; `old` used the socket after it and has
    // nothing parked on it any more.
    var busy_state: TestState = .{ .backend = &busy };
    testPark(&busy, &busy_state, &ops[1].c);
    var old_state: TestState = .{ .backend = &old };
    testPark(&old, &old_state, &ops[0].c);
    try std.testing.expect(testDetach(&old, &ops[0].c));

    var new_state: TestState = .{ .backend = &new };
    testPark(&new, &new_state, &ops[2].c);

    try std.testing.expectEqual(0, TestBackend.interest[0]);
    try std.testing.expectEqual(null, testEntry(&old, fd));
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[1]);
    const busy_bit = @as(u64, 1) << busy.fds.index;
    const new_bit = @as(u64, 1) << new.fds.index;
    try std.testing.expectEqual(busy_bit | new_bit, testMask(&holders, fd));

    try std.testing.expect(testDetach(&busy, &ops[1].c));
    try std.testing.expect(testDetach(&new, &ops[2].c));
}

test "readiness: a loop registering one direction leaves the other to other loops" {
    const fd: net.fd_t = 10;
    TestBackend.reset();

    var holders: Holders = .{};
    var reader: TestBackend = try .init(&holders, 0);
    defer holders.release(reader.fds);
    var writer: TestBackend = try .init(&holders, 1);
    defer holders.release(writer.fds);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var recvs: [2]NetRecv = undefined;
    for (&recvs) |*op| {
        op.* = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
        _ = op.c.enterRunning();
    }
    var wiov: [1]os.iovec_const = undefined;
    var send: NetSend = .init(fd, WriteBuf.fromSlice("x", &wiov), .{});
    _ = send.c.enterRunning();

    // The reader task is between two receives when the writer task parks.
    var reader_state: TestState = .{ .backend = &reader };
    testPark(&reader, &reader_state, &recvs[0].c);
    try std.testing.expect(testDetach(&reader, &recvs[0].c));
    var writer_state: TestState = .{ .backend = &writer };
    testPark(&writer, &writer_state, &send.c);

    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);
    try std.testing.expectEqual(dirBit(.write), TestBackend.interest[1]);

    // A receive on the writer's loop takes the read direction over.
    testPark(&writer, &writer_state, &recvs[1].c);
    try std.testing.expectEqual(0, TestBackend.interest[0]);
    try std.testing.expectEqual(null, testEntry(&reader, fd));
    try std.testing.expectEqual(@as(u64, 1) << writer.fds.index, testMask(&holders, fd));

    try std.testing.expect(testDetach(&writer, &send.c));
    try std.testing.expect(testDetach(&writer, &recvs[1].c));
}

test "readiness: an op that cannot be registered is finished and leaves nothing behind" {
    const fd: net.fd_t = 12;
    TestBackend.reset();

    var holders: Holders = .{};
    var backend: TestBackend = try .init(&holders, 0);
    defer holders.release(backend.fds);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var op: NetRecv = .init(fd, ReadBuf.fromSlice(&buf, &iov), .{});
    _ = op.c.enterRunning();

    TestBackend.fail_add = true;
    var state: TestState = .{ .backend = &backend };
    testPark(&backend, &state, &op.c);

    try std.testing.expectEqual(1, state.finished_count);
    try std.testing.expectError(error.Unexpected, op.getResult());
    try std.testing.expectEqual(null, testEntry(&backend, fd));
    try std.testing.expectEqual(0, testMask(&holders, fd));
}

test "readiness: a wait list keeps its order through removals anywhere" {
    var ops: [4]NetRecv = undefined;
    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    for (&ops) |*op| op.* = .init(0, ReadBuf.fromSlice(&buf, &iov), .{});
    const a = &ops[0].c;
    const b = &ops[1].c;
    const c = &ops[2].c;
    const d = &ops[3].c;

    var list: WaitList = .{};
    for ([_]*Completion{ a, b, c, d }) |op| list.push(op);
    list.remove(b); // middle
    list.remove(d); // tail
    list.push(b);
    list.remove(a); // head

    var seen: [4]?*Completion = @splat(null);
    var n: usize = 0;
    var it = list.head;
    while (it) |op| : (it = op.next) {
        seen[n] = op;
        n += 1;
    }
    try std.testing.expectEqualSlices(?*Completion, &.{ c, b, null, null }, &seen);
    try std.testing.expectEqual(b, list.head.?.prev.?);

    list.remove(b);
    list.remove(c);
    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(null, c.prev);
    try std.testing.expectEqual(null, c.next);
}

test "readiness: an entry holds one pointer per direction" {
    try std.testing.expect(@sizeOf(Entry) <= 24);
}

test "readiness: a transient registration is dropped with its last waiter" {
    const fd: net.fd_t = 11;
    TestBackend.reset();

    var holders: Holders = .{};
    var backend: TestBackend = try .init(&holders, 0);
    defer holders.release(backend.fds);

    var buf: [1]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var ops: [2]FileReadStreaming = undefined;
    for (&ops) |*op| {
        op.* = .init(fd, ReadBuf.fromSlice(&buf, &iov));
        _ = op.c.enterRunning();
    }

    var state: TestState = .{ .backend = &backend };
    testPark(&backend, &state, &ops[0].c);
    testPark(&backend, &state, &ops[1].c);
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);
    try std.testing.expect(testEntry(&backend, fd).?.transient);
    // Not recorded in `Holders`: nothing to purge on close, nothing for
    // another loop to drop.
    try std.testing.expectEqual(0, testMask(&holders, fd));

    // A cancel of one leaves the registration for the other.
    try std.testing.expect(testDetach(&backend, &ops[0].c));
    try std.testing.expectEqual(dirBit(.read), TestBackend.interest[0]);

    // Completing the last one drops it.
    const gen = testEntry(&backend, fd).?.gen;
    onEvent(&backend, &state, fd, gen, dirBit(.read), &TestBackend.Event{});
    try std.testing.expectEqual(1, state.finished_count);
    try std.testing.expectEqual(0, TestBackend.interest[0]);
    try std.testing.expectEqual(null, testEntry(&backend, fd));
}
