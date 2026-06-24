const std = @import("std");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const common = @import("common.zig");
const os = @import("../../os/root.zig");

const unexpectedError = @import("../../os/base.zig").unexpectedError;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
const Queue = @import("../queue.zig").Queue;
const NetConnect = @import("../completion.zig").NetConnect;
const NetAccept = @import("../completion.zig").NetAccept;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetRecvFrom = @import("../completion.zig").NetRecvFrom;
const NetSendTo = @import("../completion.zig").NetSendTo;
const NetRecvMsg = @import("../completion.zig").NetRecvMsg;
const NetSendMsg = @import("../completion.zig").NetSendMsg;
const NetPoll = @import("../completion.zig").NetPoll;
const NetClose = @import("../completion.zig").NetClose;
const PipePoll = @import("../completion.zig").PipePoll;
const PipeClose = @import("../completion.zig").PipeClose;
const ProcessWait = @import("../completion.zig").ProcessWait;
const fs = @import("../../os/fs.zig");
const linux = std.os.linux;
const os_linux = @import("../../os/linux.zig");

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .process_wait = true,
    // A socket fd is registered in exactly one loop's epoll (per direction), but
    // the fiber that owns the operation can be on a different executor (task
    // migration / cross-loop full-duplex). The registering loop completes the
    // operation when its epoll fires, even though the completion was submitted on
    // another loop, so the group's active/inflight accounting must be shared.
    .is_multi_threaded = true,
};

// --- Shared socket poll registry -------------------------------------------
//
// epoll interest is per-loop: an fd registered in loop A's epoll only produces
// events on A's thread. zio runs one loop per executor and migrates fibers
// between them, so a socket fd can be driven from different loops over its life,
// and a reader and a writer can sit on different loops at once.
//
// The loops in a group share one table, keyed by fd, recording per direction
// which loop owns the epoll registration plus the queue of completions waiting
// on that (fd, direction). Lazy, single registration:
//
//   * submit does the optimistic syscall on whatever loop it lands on; on success
//     it never touches the table (lock-free fast path).
//   * on WouldBlock it looks up (fd, dir): if a loop already owns it, the
//     completion is just parked as a waiter (no epoll_ctl); otherwise the current
//     loop becomes the owner and registers fd in its own epoll.
//   * when the owner's epoll fires it drains the waiters - completing each, even
//     those submitted on other loops, via the shared accounting above.
//
// This registers the fd on the few loops that actually poll it (one per
// direction) rather than on every loop a migrating fd visits, and delegating the
// completion to the loop that already has it registered avoids an extra
// registration syscall on the parking loop.
//
// Only true sockets (the net_* operations) use this table. Other pollable fds
// (pidfd for process_wait, pipes, streaming files) are closed through paths that
// do not run net_close, so they stay on the original one-shot level-triggered
// per-loop path.

const reg_shard_count = 64; // power of two

const Dir = enum(u1) { in = 0, out = 1 };

/// Per-fd registration state, shared across the loops in a group.
const FdReg = struct {
    /// Loop whose epoll has fd registered for read / write (null = not yet).
    owner_in: ?*Self = null,
    owner_out: ?*Self = null,
    /// Completions parked waiting for readability / writability.
    waiters_in: Queue(Completion) = .{},
    waiters_out: Queue(Completion) = .{},
    /// Readiness latch. Set when an edge fires with no waiter parked yet (a
    /// "wasted" edge), so the next op to park sees it and re-checks instead of
    /// waiting for an edge that edge-triggered epoll will not repeat. This closes
    /// the race where data arrives between an op's optimistic syscall returning
    /// EAGAIN and that op enqueuing as a waiter.
    ready_in: bool = false,
    ready_out: bool = false,

    fn empty(self: *const FdReg) bool {
        return self.owner_in == null and self.owner_out == null and
            self.waiters_in.empty() and self.waiters_out.empty();
    }
};

const RegShard = struct {
    mutex: os.Mutex = .init(),
    map: std.AutoHashMapUnmanaged(NetHandle, FdReg) = .empty,
};

pub const SharedState = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    allocator: std.mem.Allocator = undefined,

    /// Multi-threaded counters: a completion submitted on one loop may be
    /// finished by the loop that owns the fd registration, so active/inflight_io
    /// are shared atomics rather than per-LoopState fields.
    active: std.atomic.Value(u64) = .init(0),
    inflight_io: std.atomic.Value(u64) = .init(0),

    shards: [reg_shard_count]RegShard = [_]RegShard{.{}} ** reg_shard_count,

    pub fn acquire(self: *SharedState, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) {
            self.allocator = allocator;
            self.active.store(0, .release);
            self.inflight_io.store(0, .release);
        }
        self.refcount += 1;
    }

    pub fn release(self: *SharedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;
        if (self.refcount == 0) {
            for (&self.shards) |*shard| {
                shard.map.deinit(self.allocator);
                shard.map = .empty;
            }
        }
    }

    fn shardFor(self: *SharedState, fd: NetHandle) *RegShard {
        const key: u32 = @bitCast(fd);
        return &self.shards[key & (reg_shard_count - 1)];
    }
};

pub const ProcessWaitData = struct {
    pidfd: posix.fd_t = -1,
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const PollEntryType = enum {
    connect,
    accept,
    send_or_recv,
};

const PollEntry = struct {
    completions: Queue(Completion),
    type: PollEntryType,
    events: u32,
};

const Self = @This();

const log = @import("../../common.zig").log;

allocator: std.mem.Allocator,
/// Per-loop one-shot table for NON-socket pollable fds (pidfd, pipes, streaming
/// files). Sockets do not use this; they go through the shared registry.
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
epoll_fd: i32 = -1,
waker_eventfd: i32 = -1,
events: []std.os.linux.epoll_event,
queue_size: u16,
pending_changes: usize = 0,
/// Shared per-group socket registry (see SharedState above).
shared: *SharedState = undefined,
/// Whether epoll_pwait2 (nanosecond timeout, Linux 5.11+) is available.
epoll_pwait2_supported: bool = true,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    shared_state.acquire(allocator);
    errdefer shared_state.release();

    const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    const epoll_fd: i32 = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = std.os.linux.close(epoll_fd);

    const waker_eventfd = try posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
    errdefer _ = std.os.linux.close(waker_eventfd);

    var event: std.os.linux.epoll_event = .{
        .events = std.os.linux.EPOLL.IN,
        .data = .{ .fd = waker_eventfd },
    };
    const ctl_rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, waker_eventfd, &event);
    if (posix.errno(ctl_rc) != .SUCCESS) {
        return unexpectedError(posix.errno(ctl_rc));
    }

    self.* = .{
        .allocator = allocator,
        .epoll_fd = epoll_fd,
        .waker_eventfd = waker_eventfd,
        .events = undefined,
        .queue_size = queue_size,
        .shared = shared_state,
    };

    self.events = try allocator.alloc(std.os.linux.epoll_event, queue_size);
    errdefer allocator.free(self.events);

    try self.poll_queue.ensureTotalCapacity(self.allocator, queue_size);
}

pub fn deinit(self: *Self) void {
    if (self.waker_eventfd != -1) {
        _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, self.waker_eventfd, null);
        _ = std.os.linux.close(self.waker_eventfd);
    }
    self.poll_queue.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.epoll_fd != -1) {
        _ = std.os.linux.close(self.epoll_fd);
    }
    self.shared.release();
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    posix.eventfd_write(self.waker_eventfd, 1) catch {};
}

fn getEvents(completion: *Completion) u32 {
    return switch (completion.op) {
        .net_connect => std.os.linux.EPOLL.OUT,
        .net_accept => std.os.linux.EPOLL.IN,
        .net_recv => std.os.linux.EPOLL.IN,
        .net_send => std.os.linux.EPOLL.OUT,
        .net_recvfrom => std.os.linux.EPOLL.IN,
        .net_sendto => std.os.linux.EPOLL.OUT,
        .net_recvmsg => std.os.linux.EPOLL.IN,
        .net_sendmsg => std.os.linux.EPOLL.OUT,
        .net_poll => blk: {
            const poll_data = completion.cast(NetPoll);
            break :blk switch (poll_data.event) {
                .recv => std.os.linux.EPOLL.IN,
                .send => std.os.linux.EPOLL.OUT,
            };
        },
        .file_read_streaming => std.os.linux.EPOLL.IN,
        .file_write_streaming => std.os.linux.EPOLL.OUT,
        .pipe_poll => blk: {
            const poll_data = completion.cast(PipePoll);
            break :blk switch (poll_data.event) {
                .read => std.os.linux.EPOLL.IN,
                .write => std.os.linux.EPOLL.OUT,
            };
        },
        .process_wait => std.os.linux.EPOLL.IN,
        else => unreachable,
    };
}

fn getPollType(op: Op) PollEntryType {
    return switch (op) {
        .file_read_streaming, .file_write_streaming => .send_or_recv,
        .pipe_poll => .send_or_recv,
        .process_wait => .send_or_recv,
        else => unreachable,
    };
}

/// Whether an operation runs against a real socket fd (closed only via
/// net_close). These use the shared registry; everything else uses the per-loop
/// one-shot path.
fn isSocketOp(op: Op) bool {
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

/// Direction (read/write interest) a socket op waits on.
fn dirOf(c: *Completion) Dir {
    return switch (c.op) {
        .net_accept, .net_recv, .net_recvfrom, .net_recvmsg => .in,
        .net_connect, .net_send, .net_sendto, .net_sendmsg => .out,
        .net_poll => switch (c.cast(NetPoll).event) {
            .recv => .in,
            .send => .out,
        },
        else => unreachable,
    };
}

// --- Shared registry helpers (caller must hold the fd's shard mutex) --------

fn ownerPtr(reg: *FdReg, dir: Dir) *?*Self {
    return switch (dir) {
        .in => &reg.owner_in,
        .out => &reg.owner_out,
    };
}

fn waitersPtr(reg: *FdReg, dir: Dir) *Queue(Completion) {
    return switch (dir) {
        .in => &reg.waiters_in,
        .out => &reg.waiters_out,
    };
}

fn readyPtr(reg: *FdReg, dir: Dir) *bool {
    return switch (dir) {
        .in => &reg.ready_in,
        .out => &reg.ready_out,
    };
}

/// (Re)arm this loop's epoll interest for fd to cover every direction it owns.
/// Held under the shard mutex. The mask is edge-triggered; combined with the
/// optimistic syscall in submit (which drains to EAGAIN), no edge is missed.
fn armRegistration(self: *Self, reg: *FdReg, fd: NetHandle) !void {
    var mask: u32 = std.os.linux.EPOLL.ET;
    var count: u8 = 0;
    if (reg.owner_in == self) {
        mask |= std.os.linux.EPOLL.IN;
        count += 1;
    }
    if (reg.owner_out == self) {
        mask |= std.os.linux.EPOLL.OUT;
        count += 1;
    }
    std.debug.assert(count >= 1);

    var event = std.os.linux.epoll_event{ .data = .{ .fd = fd }, .events = mask };
    // More than one direction owned by us => fd was already in our epoll => MOD.
    const first_op: u32 = if (count > 1) std.os.linux.EPOLL.CTL_MOD else std.os.linux.EPOLL.CTL_ADD;
    switch (posix.errno(std.os.linux.epoll_ctl(self.epoll_fd, first_op, fd, &event))) {
        .SUCCESS => {},
        .EXIST => {
            // Already present; switch to MOD.
            switch (posix.errno(std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event))) {
                .SUCCESS => {},
                else => |err| return unexpectedError(err),
            }
        },
        .NOENT => {
            // Not present; switch to ADD.
            switch (posix.errno(std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event))) {
                .SUCCESS => {},
                else => |err| return unexpectedError(err),
            }
        },
        else => |err| return unexpectedError(err),
    }
}

/// Park a socket completion that returned WouldBlock: become the owner of
/// (fd, dir) and register if nobody else does, otherwise just enqueue as a waiter.
fn parkSocket(self: *Self, state: *LoopState, fd: NetHandle, c: *Completion) void {
    if (self.pending_changes >= self.queue_size) {
        _ = self.poll(state, .zero) catch {
            log.err("Failed to do no-wait poll during parkSocket", .{});
        };
    }

    c.prev = null;
    c.next = null;
    const dir = dirOf(c);

    const shard = self.shared.shardFor(fd);
    shard.mutex.lock();

    const gop = shard.map.getOrPut(self.shared.allocator, fd) catch {
        shard.mutex.unlock();
        log.err("Failed to add to poll registry: OutOfMemory", .{});
        c.setError(error.Unexpected);
        state.markCompletedFromBackend(c);
        return;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const reg = gop.value_ptr;

    const owner = ownerPtr(reg, dir);
    if (owner.* == null) {
        // First to poll this (fd, dir): become the owner and register locally.
        // The edge-triggered ADD reports current readiness, so a freshly-arrived
        // byte between the optimistic syscall and here is not lost - no latch
        // check needed on this path.
        owner.* = self;
        self.armRegistration(reg, fd) catch {
            owner.* = null;
            if (reg.empty()) _ = shard.map.remove(fd);
            shard.mutex.unlock();
            log.err("Failed to register socket with epoll", .{});
            c.setError(error.Unexpected);
            state.markCompletedFromBackend(c);
            return;
        };
        self.pending_changes += 1;
        waitersPtr(reg, dir).push(c);
        shard.mutex.unlock();
        return;
    }

    // Already registered (possibly by another loop). If an edge fired since the
    // last drain with nobody waiting, the readiness was latched: re-check the
    // syscall now rather than park for an edge edge-triggered epoll won't repeat.
    // net_connect always takes the fresh-ADD path above in practice, so its
    // re-check (which can't distinguish success from failure without the real
    // event) is skipped here.
    const ready = readyPtr(reg, dir);
    if (ready.* and c.op != .net_connect) {
        ready.* = false;
        shard.mutex.unlock();
        var ev = std.os.linux.epoll_event{
            .data = .{ .fd = fd },
            .events = switch (dir) {
                .in => std.os.linux.EPOLL.IN,
                .out => std.os.linux.EPOLL.OUT,
            },
        };
        switch (checkCompletion(c, &ev)) {
            .completed => self.completeDeferred(state, c),
            .requeue => {
                // Latch was stale: park for the next real edge.
                c.prev = null;
                c.next = null;
                shard.mutex.lock();
                if (shard.map.getPtr(fd)) |r| {
                    waitersPtr(r, dir).push(c);
                    shard.mutex.unlock();
                } else {
                    shard.mutex.unlock();
                    c.setError(error.Canceled);
                    self.completeDeferred(state, c);
                }
            },
        }
        return;
    }

    waitersPtr(reg, dir).push(c);
    shard.mutex.unlock();
}

/// Drain waiters for one direction of an owned socket. Pops one waiter at a time
/// under the lock and runs its syscall outside the lock (completing a waiter can
/// resume a fiber that submits another op on this fd, which re-locks the shard).
fn drainDir(self: *Self, state: *LoopState, fd: NetHandle, dir: Dir, event: *const std.os.linux.epoll_event) void {
    const shard = self.shared.shardFor(fd);
    var drained_any = false;
    while (true) {
        shard.mutex.lock();
        const reg = shard.map.getPtr(fd) orelse {
            shard.mutex.unlock();
            return;
        };
        if (ownerPtr(reg, dir).* != self) {
            shard.mutex.unlock();
            return;
        }
        const c = waitersPtr(reg, dir).pop() orelse {
            // Edge fired with no waiter to consume it. If this is a genuinely
            // wasted edge (we hadn't already drained one), latch the readiness so
            // the next op to park re-checks instead of waiting for an edge that
            // won't repeat. If we did drain at least one, any leftover data is
            // taken by the next op's optimistic syscall, so no latch is needed.
            if (!drained_any) readyPtr(reg, dir).* = true;
            shard.mutex.unlock();
            return;
        };
        shard.mutex.unlock();

        // A concurrent cancel may have already finished this completion.
        if (c.state == .completed or c.state == .dead) continue;

        switch (checkCompletion(c, event)) {
            .completed => {
                state.markCompletedFromBackend(c);
                drained_any = true;
            },
            .requeue => {
                // Confirmed not ready (EAGAIN): clear the latch and re-park. The
                // edge-triggered registration delivers the next readiness edge.
                c.prev = null;
                c.next = null;
                shard.mutex.lock();
                if (shard.map.getPtr(fd)) |r| {
                    readyPtr(r, dir).* = false;
                    waitersPtr(r, dir).push(c);
                    shard.mutex.unlock();
                } else {
                    shard.mutex.unlock();
                    c.setError(error.Canceled);
                    state.markCompletedFromBackend(c);
                }
                return;
            },
        }
    }
}

/// Tear down the shared registration for a socket fd that is about to be closed.
/// Closing removes the fd from every epoll instance at the kernel level; this
/// clears the software bookkeeping (so a reused fd number starts clean) and
/// best-effort DELs it from the owner loops' epolls.
fn unregisterSocket(self: *Self, fd: NetHandle) void {
    const shard = self.shared.shardFor(fd);
    shard.mutex.lock();
    const kv = shard.map.fetchRemove(fd);
    shard.mutex.unlock();

    if (kv) |entry| {
        const reg = entry.value;
        if (reg.owner_in) |o| _ = std.os.linux.epoll_ctl(o.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        if (reg.owner_out) |o| {
            if (o != reg.owner_in) _ = std.os.linux.epoll_ctl(o.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        }
    }
}

// --- Non-socket one-shot path (pidfd / pipe / streaming file) ---------------

fn addOneShotToPollQueue(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
    if (self.pending_changes >= self.queue_size) {
        _ = self.poll(state, .zero) catch {
            log.err("Failed to do no-wait poll during addToPollQueue", .{});
        };
    }
    self.pending_changes += 1;

    completion.prev = null;
    completion.next = null;

    const gop = self.poll_queue.getOrPut(self.allocator, fd) catch {
        log.err("Failed to add to poll queue: OutOfMemory", .{});
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return;
    };

    var entry = gop.value_ptr;
    const op_events = getEvents(completion);

    if (!gop.found_existing) {
        var event = std.os.linux.epoll_event{
            .data = .{ .fd = fd },
            .events = op_events,
        };
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to epoll_ctl(CTL_ADD): {}", .{err});
                _ = self.poll_queue.remove(fd);
                completion.setError(error.Unexpected);
                state.markCompletedFromBackend(completion);
                return;
            },
        }
        entry.* = .{
            .completions = .{},
            .type = getPollType(completion.op),
            .events = op_events,
        };
        entry.completions.push(completion);
        return;
    }

    std.debug.assert(entry.type == getPollType(completion.op));

    const new_events = entry.events | op_events;
    if (new_events != entry.events) {
        var event = std.os.linux.epoll_event{
            .events = new_events,
            .data = .{ .fd = fd },
        };
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to epoll_ctl(CTL_MOD): {}", .{err});
                completion.setError(error.Unexpected);
                state.markCompletedFromBackend(completion);
                return;
            },
        }
        entry.events = new_events;
    }
    entry.completions.push(completion);
}

fn removeOneShotFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const entry = self.poll_queue.getPtr(fd) orelse return;

    _ = entry.completions.remove(completion);

    if (entry.completions.head == null) {
        const del_rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        const err = posix.errno(del_rc);
        const was_removed = self.poll_queue.remove(fd);
        std.debug.assert(was_removed);
        switch (err) {
            .SUCCESS, .NOENT, .BADF => {},
            else => return unexpectedError(err),
        }
        return;
    }

    var new_events: u32 = 0;
    var iter: ?*Completion = entry.completions.head;
    while (iter) |c| : (iter = c.next) {
        new_events |= getEvents(c);
    }

    if (new_events != entry.events) {
        var event = std.os.linux.epoll_event{
            .events = new_events,
            .data = .{ .fd = fd },
        };
        const mod_rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &event);
        switch (posix.errno(mod_rc)) {
            .SUCCESS => {
                entry.events = new_events;
            },
            else => |err| return unexpectedError(err),
        }
    }
}

fn getHandle(completion: *Completion) NetHandle {
    return switch (completion.op) {
        .net_accept => completion.cast(NetAccept).handle,
        .net_connect => completion.cast(NetConnect).handle,
        .net_recv => completion.cast(NetRecv).handle,
        .net_send => completion.cast(NetSend).handle,
        .net_recvfrom => completion.cast(NetRecvFrom).handle,
        .net_sendto => completion.cast(NetSendTo).handle,
        .net_recvmsg => completion.cast(NetRecvMsg).handle,
        .net_sendmsg => completion.cast(NetSendMsg).handle,
        .net_poll => completion.cast(NetPoll).handle,
        .pipe_poll => completion.cast(PipePoll).handle,
        inline .file_read_streaming, .file_write_streaming => |op| completion.cast(op.toType()).handle,
        .pipe_close => completion.cast(PipeClose).handle,
        .process_wait => completion.cast(ProcessWait).internal.pidfd,
        else => unreachable,
    };
}

/// Finish an optimistically-satisfied op via the loop's deferred completion
/// queue rather than inline, so submit never re-enters the submitter. The
/// generic NetSendFile fallback (loop.zig) re-submits a NetSend from inside its
/// own send callback; completing inline there would re-enter and finish the
/// transfer twice. The syscall already happened; only the notification is parked.
fn completeDeferred(self: *Self, state: *LoopState, c: *Completion) void {
    _ = self;
    state.decrInflight();
    state.work_completions.push(c);
}

/// Submit a completion to the backend - infallible.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.incrActive();

    switch (c.op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        .net_open => {
            common.handleNetOpen(c);
            state.markCompletedFromBackend(c);
        },
        .net_bind => {
            common.handleNetBind(c);
            state.markCompletedFromBackend(c);
        },
        .net_listen => {
            common.handleNetListen(c);
            state.markCompletedFromBackend(c);
        },
        .net_close => {
            const data = c.cast(NetClose);
            self.unregisterSocket(data.handle);
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Connect - try connect() first, park only on WouldBlock.
        .net_connect => {
            const data = c.cast(NetConnect);
            if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
                c.setResult(.net_connect, {});
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },

        // Optimistic syscall first; park on WouldBlock. The optimistic syscall
        // also drains the socket to EAGAIN, which is what makes the persistent
        // edge-triggered registration safe.
        .net_accept => {
            const data = c.cast(NetAccept);
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                c.setResult(.net_accept, handle);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |n| {
                c.setResult(.net_recv, n);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (net.send(data.handle, data.buffer.iovecs, data.flags)) |n| {
                c.setResult(.net_send, n);
                // Defer, never inline: the NetSendFile fallback re-submits a send
                // from inside its send callback; inline completion would re-enter.
                self.completeDeferred(state, c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    self.completeDeferred(state, c);
                },
            }
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                c.setResult(.net_recvfrom, n);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                c.setResult(.net_sendto, n);
                self.completeDeferred(state, c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    self.completeDeferred(state, c);
                },
            }
        },
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                c.setResult(.net_recvmsg, result);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |n| {
                c.setResult(.net_sendmsg, n);
                self.completeDeferred(state, c);
            } else |err| switch (err) {
                error.WouldBlock => self.parkSocket(state, data.handle, c),
                else => {
                    c.setError(err);
                    self.completeDeferred(state, c);
                },
            }
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            // net_poll has no I/O to drain, so it cannot rely on the edge-triggered
            // registration re-arming on an already-ready socket. Probe readiness
            // with a 0-timeout poll() and park only when not ready.
            const want: i16 = switch (data.event) {
                .recv => linux.POLL.IN,
                .send => linux.POLL.OUT,
            };
            var pfd = [_]linux.pollfd{.{ .fd = data.handle, .events = want, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 0);
            if (posix.errno(prc) == .SUCCESS and
                (pfd[0].revents & (want | linux.POLL.ERR | linux.POLL.HUP)) != 0)
            {
                c.setResult(.net_poll, {});
                state.markCompletedFromBackend(c);
            } else {
                self.parkSocket(state, data.handle, c);
            }
        },
        .pipe_poll => {
            const data = c.cast(PipePoll);
            self.addOneShotToPollQueue(state, data.handle, c);
        },
        .pipe_create => {
            const fds = fs.pipe() catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
                return;
            };
            c.setResult(.pipe_create, fds);
            state.markCompletedFromBackend(c);
        },
        inline .file_read_streaming, .file_write_streaming => |op| {
            self.addOneShotToPollQueue(state, c.cast(op.toType()).handle, c);
        },
        .pipe_close => {
            const data = c.cast(PipeClose);
            if (fs.close(data.handle)) |_| {
                c.setResult(.pipe_close, {});
            } else |err| {
                c.setError(err);
            }
            state.markCompletedFromBackend(c);
        },
        .process_wait => {
            const data = c.cast(ProcessWait);
            const rc = linux.pidfd_open(data.handle, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    data.internal.pidfd = @intCast(rc);
                    self.addOneShotToPollQueue(state, data.internal.pidfd, c);
                },
                .SRCH => {
                    c.setError(error.ProcessNotFound);
                    state.markCompletedFromBackend(c);
                },
                .NFILE, .MFILE => {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                },
                else => {
                    c.setError(error.Unexpected);
                    state.markCompletedFromBackend(c);
                },
            }
        },

        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_size, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .file_stat, .dir_open, .dir_close, .dir_read, .dir_create_dir, .dir_rename, .dir_rename_preserve, .dir_delete_file, .dir_delete_dir, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link, .device_io_control => unreachable,
        .net_send_file => unreachable,
        .mach_port => unreachable,
    }
}

/// Cancel a completion - infallible.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    const fd = getHandle(target);

    if (isSocketOp(target.op)) {
        // Try to pull the completion out of its shared waiter queue. If it is
        // still there we own the cancel; if not, the owner loop already popped it
        // to complete it, so we leave it to complete naturally (cancel is
        // best-effort, and the loop's cancel_state coordinates the outcome).
        const dir = dirOf(target);
        const shard = self.shared.shardFor(fd);
        shard.mutex.lock();
        var removed = false;
        if (shard.map.getPtr(fd)) |reg| {
            removed = waitersPtr(reg, dir).remove(target);
        }
        shard.mutex.unlock();
        if (removed) {
            target.setError(error.Canceled);
            state.markCompletedFromBackend(target);
        }
        return;
    }

    self.removeOneShotFromPollQueue(fd, target) catch |err| {
        log.err("Failed to remove completion from poll queue during cancel: {}", .{err});
    };

    if (target.op == .process_wait) {
        const data = target.cast(ProcessWait);
        _ = linux.close(@intCast(data.internal.pidfd));
    }

    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

fn waitEvents(self: *Self, timeout: Duration) !usize {
    if (self.epoll_pwait2_supported) {
        var ts: linux.kernel_timespec = undefined;
        const ts_ptr: ?*const linux.kernel_timespec = if (timeout.value == Duration.max.value) null else blk: {
            const ns = timeout.toNanoseconds();
            ts = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
            break :blk &ts;
        };
        const rc = os_linux.epoll_pwait2(self.epoll_fd, self.events.ptr, @intCast(self.events.len), ts_ptr);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => return 0,
            .NOSYS => self.epoll_pwait2_supported = false,
            else => |err| return unexpectedError(err),
        }
    }

    const timeout_ms: i32 = std.math.cast(i32, timeout.toMilliseconds()) orelse std.math.maxInt(i32);
    const rc = std.os.linux.epoll_wait(self.epoll_fd, self.events.ptr, @intCast(self.events.len), timeout_ms);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return 0,
        else => |err| return unexpectedError(err),
    }
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    self.pending_changes = 0;

    const n = try self.waitEvents(timeout);
    if (n == 0) return true; // Timed out

    for (self.events[0..n]) |event| {
        const fd = event.data.fd;

        if (fd == self.waker_eventfd) {
            _ = posix.eventfd_read(self.waker_eventfd) catch {};
            continue;
        }

        // Non-socket pollable fds live in the per-loop one-shot table.
        if (self.poll_queue.get(fd)) |entry| {
            var iter: ?*Completion = entry.completions.head;
            while (iter) |completion| {
                iter = completion.next;
                if (completion.state == .completed or completion.state == .dead) continue;
                switch (checkCompletion(completion, &event)) {
                    .completed => {
                        try self.removeOneShotFromPollQueue(fd, completion);
                        state.markCompletedFromBackend(completion);
                    },
                    .requeue => {},
                }
            }
            continue;
        }

        // Otherwise it is a socket: drain the directions we own. An edge with no
        // owned waiter (e.g. the fd's reader migrated, or it already drained) is
        // ignored - edge-triggered means the data stays buffered and the next
        // op's optimistic syscall picks it up.
        const e = event.events;
        if (e & (std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP) != 0)
            self.drainDir(state, fd, .in, &event);
        if (e & (std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP) != 0)
            self.drainDir(state, fd, .out, &event);
    }

    return false;
}

const CheckResult = enum { completed, requeue };

fn handleEpollError(event: *const std.os.linux.epoll_event, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = net.getSockError(event.data.fd) catch return error.Unexpected;
    if (sock_err == 0) return null;
    return errnoToError(@enumFromInt(sock_err));
}

pub fn checkCompletion(c: *Completion, event: *const std.os.linux.epoll_event) CheckResult {
    switch (c.op) {
        .net_connect => {
            if (handleEpollError(event, net.errnoToConnectError)) |err| {
                c.setError(err);
            } else {
                c.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (handleEpollError(event, net.errnoToAcceptError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                c.setResult(.net_accept, handle);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (handleEpollError(event, net.errnoToRecvError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |n| {
                c.setResult(.net_recv, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (handleEpollError(event, net.errnoToSendError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.send(data.handle, data.buffer.iovecs, data.flags)) |n| {
                c.setResult(.net_send, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            if (handleEpollError(event, net.errnoToRecvError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                c.setResult(.net_recvfrom, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            if (handleEpollError(event, net.errnoToSendError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                c.setResult(.net_sendto, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            if (handleEpollError(event, net.errnoToRecvError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                c.setResult(.net_recvmsg, result);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            if (handleEpollError(event, net.errnoToSendError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |n| {
                c.setResult(.net_sendmsg, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .net_poll => {
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
            if (has_error or has_hup) {
                c.setResult(.net_poll, {});
                return .completed;
            }
            const requested_events = getEvents(c);
            const ready_events = event.events & requested_events;
            if (ready_events != 0) {
                c.setResult(.net_poll, {});
                return .completed;
            }
            return .requeue;
        },
        inline .file_read_streaming => |op| {
            const data = c.cast(op.toType());
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
                    if (has_hup) {
                        c.setResult(op, 0);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        inline .file_write_streaming => |op| {
            const data = c.cast(op.toType());
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
            if (has_error or has_hup) {
                c.setError(error.BrokenPipe);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .pipe_close => unreachable,
        .pipe_create => unreachable,
        .pipe_poll => {
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
            if (has_error or has_hup) {
                c.setResult(.pipe_poll, {});
                return .completed;
            }
            const requested_events = getEvents(c);
            const ready_events = event.events & requested_events;
            if (ready_events != 0) {
                c.setResult(.pipe_poll, {});
                return .completed;
            }
            return .requeue;
        },
        .process_wait => {
            const data = c.cast(ProcessWait);
            defer _ = linux.close(@intCast(data.internal.pidfd));

            var siginfo: linux.siginfo_t = undefined;
            const wait_rc = linux.waitid(.PIDFD, @intCast(data.internal.pidfd), &siginfo, linux.W.EXITED, null);
            switch (posix.errno(wait_rc)) {
                .SUCCESS => {
                    const si_status = siginfo.fields.common.second.sigchld.status;
                    const si_code = siginfo.code;
                    const CLD_EXITED = 1;
                    const CLD_KILLED = 2;
                    const CLD_DUMPED = 3;
                    const terminated_by_signal = (si_code == CLD_KILLED or si_code == CLD_DUMPED);
                    c.setResult(.process_wait, .{
                        .code = if (si_code == CLD_EXITED) @intCast(si_status) else 0,
                        .signal = if (terminated_by_signal) @intCast(si_status) else null,
                    });
                },
                .CHILD => c.setError(error.ProcessNotFound),
                else => c.setError(error.Unexpected),
            }
            return .completed;
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}
