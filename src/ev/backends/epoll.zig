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
};

// Persistent edge-triggered interest used for sockets. Both IN and OUT are armed
// once for the socket's lifetime, so the backend never issues epoll_ctl(MOD) when
// a socket switches between reading and writing, and never disarms on completion.
// Edge-triggered is safe because submit() always tries the syscall first (draining
// to EAGAIN) before it ever waits in epoll, so no readiness edge can be missed.
const persist_events: u32 = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.ET;

// --- Shared socket registration table -------------------------------------
//
// epoll interest is per-loop: an fd registered in loop A's epoll only produces
// events on A's thread. zio runs one loop per executor and migrates fibers
// between executors, so the *same* socket fd can be used from different loops
// over its lifetime (migration), and a reader and a writer on one socket can
// live on different loops at once (concurrent full-duplex). To keep the fd
// registered (no per-op epoll_ctl) without leaving stale state behind, the loops
// in a group share one table that records, per fd, which loops currently have it
// registered in their epoll. A loop adds the fd to its own epoll the first time
// it sees an operation for it and records its bit; on close the whole entry is
// dropped (the kernel removes a closed fd from every epoll instance). The table
// is sharded by fd to keep the common path off a single global lock.
//
// Only true sockets (the net_* operations) go through this table. Other pollable
// fds (pidfd for process_wait, pipes, streaming files) are closed through paths
// that do not run net_close, so they stay on the original one-shot level-triggered
// path where each operation arms and disarms its own interest.

const reg_shard_count = 64; // power of two

const RegShard = struct {
    mutex: os.Mutex = .{},
    // fd -> bitmask of loop ids that have this socket registered in their epoll.
    map: std.AutoHashMapUnmanaged(NetHandle, u64) = .empty,
};

pub const SharedState = struct {
    mutex: os.Mutex = .{},
    refcount: usize = 0,
    next_loop_id: u32 = 0,
    allocator: std.mem.Allocator = undefined,
    shards: [reg_shard_count]RegShard = [_]RegShard{.{}} ** reg_shard_count,

    /// Register a loop with the group. Returns a small stable id (0..63) used as
    /// the loop's bit in the per-fd registration masks. Ids are recycled once the
    /// group empties out (refcount back to zero), matching the executor lifetime.
    pub fn acquire(self: *SharedState, allocator: std.mem.Allocator) u6 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) {
            self.allocator = allocator;
            self.next_loop_id = 0;
        }
        const id = self.next_loop_id;
        std.debug.assert(id < 64); // at most 64 executors share a group
        self.next_loop_id += 1;
        self.refcount += 1;
        return @intCast(id);
    }

    pub fn release(self: *SharedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;
        if (self.refcount == 0) {
            // Last loop is gone; nobody can touch the shards now. Free them.
            for (&self.shards) |*shard| {
                shard.map.deinit(self.allocator);
                shard.map = .empty;
            }
            self.next_loop_id = 0;
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
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
epoll_fd: i32 = -1,
waker_eventfd: i32 = -1,
events: []std.os.linux.epoll_event,
queue_size: u16,
pending_changes: usize = 0,
/// Shared per-group socket registration table (see SharedState above).
shared: *SharedState = undefined,
/// This loop's bit in the per-fd registration masks.
loop_bit: u64 = 0,
/// Whether epoll_pwait2 (nanosecond timeout, Linux 5.11+) is available. Set to
/// false the first time the syscall returns ENOSYS, after which we use the
/// millisecond epoll_wait for the rest of this loop's lifetime.
epoll_pwait2_supported: bool = true,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    const loop_id = shared_state.acquire(allocator);
    errdefer shared_state.release();

    const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    const epoll_fd: i32 = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = std.os.linux.close(epoll_fd);

    const waker_eventfd = try posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
    errdefer _ = std.os.linux.close(waker_eventfd);

    // Register eventfd with epoll
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
        .loop_bit = @as(u64, 1) << loop_id,
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
        .net_accept => .accept,
        .net_connect => .connect,
        .net_recv => .send_or_recv,
        .net_send => .send_or_recv,
        .net_recvfrom => .send_or_recv,
        .net_sendto => .send_or_recv,
        .net_recvmsg => .send_or_recv,
        .net_sendmsg => .send_or_recv,
        .net_poll => .send_or_recv,
        .file_read_streaming, .file_write_streaming => .send_or_recv,
        .pipe_poll => .send_or_recv,
        .process_wait => .send_or_recv,
        else => unreachable,
    };
}

/// Whether an operation runs against a real socket fd, i.e. one whose only close
/// path is the net_close handler. These take the persistent edge-triggered,
/// shared-registry path. Everything else (pidfd, pipes, streaming files) is
/// closed elsewhere and stays on the one-shot level-triggered path.
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

/// Ensure this loop's epoll has `fd` registered (persistent, edge-triggered),
/// adding it at most once per (loop, fd) for the fd's lifetime. The shared
/// registry records which loops have registered the fd so the ADD is skipped on
/// subsequent operations.
fn ensureRegistered(self: *Self, fd: NetHandle) !void {
    const shard = self.shared.shardFor(fd);
    shard.mutex.lock();
    defer shard.mutex.unlock();

    const gop = try shard.map.getOrPut(self.shared.allocator, fd);
    if (!gop.found_existing) gop.value_ptr.* = 0;

    if (gop.value_ptr.* & self.loop_bit != 0) return; // already registered here

    var event = std.os.linux.epoll_event{
        .data = .{ .fd = fd },
        .events = persist_events,
    };
    const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
    switch (posix.errno(rc)) {
        // SUCCESS: freshly registered. EXIST: already in this epoll (e.g. the
        // registry lost track across a teardown) - either way it is now armed.
        .SUCCESS, .EXIST => {},
        else => |err| {
            if (gop.value_ptr.* == 0) _ = shard.map.remove(fd);
            return unexpectedError(err);
        },
    }
    gop.value_ptr.* |= self.loop_bit;
}

/// Drop the shared-registry entry for a socket fd that is about to be closed.
/// Closing the fd removes it from every epoll instance at the kernel level, so
/// this only clears the software bookkeeping for all loops at once.
fn unregisterSocket(self: *Self, fd: NetHandle) void {
    const shard = self.shared.shardFor(fd);
    shard.mutex.lock();
    _ = shard.map.remove(fd);
    shard.mutex.unlock();

    // Drop this loop's local poll entry if present. Other loops keep no
    // lingering entry for an idle socket (entries are dropped when their
    // completion list empties), so there is nothing to clean up there.
    if (self.poll_queue.fetchRemove(fd)) |_| {
        _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }
}

/// Add a completion to the poll queue, dispatching to the socket (persistent,
/// edge-triggered) or one-shot (level-triggered) path. If queuing fails, the
/// completion is finished with error.Unexpected.
fn addToPollQueue(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
    if (isSocketOp(completion.op)) {
        self.addSocketToPollQueue(state, fd, completion);
    } else {
        self.addOneShotToPollQueue(state, fd, completion);
    }
}

/// Persistent edge-triggered path for sockets. The fd stays registered in this
/// loop's epoll for its lifetime; per-operation we only attach the completion to
/// the (possibly newly created) local entry.
fn addSocketToPollQueue(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
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

    if (gop.found_existing) {
        // A completion for this fd is already pending on this loop, so the fd is
        // already registered here. Just attach; no epoll_ctl needed.
        gop.value_ptr.completions.push(completion);
        return;
    }

    // First pending op for this fd on this loop: make sure it is registered.
    self.ensureRegistered(fd) catch {
        log.err("Failed to register socket with epoll", .{});
        _ = self.poll_queue.remove(fd);
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return;
    };

    gop.value_ptr.* = .{
        .completions = .{},
        .type = .send_or_recv,
        .events = persist_events,
    };
    gop.value_ptr.completions.push(completion);
}

/// Original one-shot level-triggered path, used for non-socket pollable fds
/// (pidfd, pipes, streaming files). Each operation arms its interest and the
/// last completion to drain disarms it.
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

fn removeFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) !void {
    if (isSocketOp(completion.op)) {
        self.removeSocketFromPollQueue(fd, completion);
        return;
    }
    return self.removeOneShotFromPollQueue(fd, completion);
}

/// Socket path: detach the completion. The fd stays registered (persistent,
/// edge-triggered); when no completion is left we drop the local entry but keep
/// the epoll registration for the next operation. Removing the entry when empty
/// is what keeps the registry honest: an idle socket never has a stale local
/// entry, so a closed-and-reused fd number can never be mistaken for registered.
fn removeSocketFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) void {
    const entry = self.poll_queue.getPtr(fd) orelse return;
    _ = entry.completions.remove(completion);
    if (entry.completions.head == null) {
        _ = self.poll_queue.remove(fd);
    }
}

/// One-shot path: detach the completion and disarm interest, exactly as upstream.
fn removeOneShotFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const entry = self.poll_queue.getPtr(fd) orelse return;

    _ = entry.completions.remove(completion);

    if (entry.completions.head == null) {
        // No more completions - remove from epoll and poll queue
        const del_rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        const err = posix.errno(del_rc);

        // Always remove from poll_queue when list is empty to avoid stale entries
        // (fd will be auto-removed from epoll when closed anyway)
        const was_removed = self.poll_queue.remove(fd);
        std.debug.assert(was_removed);

        switch (err) {
            .SUCCESS, .NOENT, .BADF => {
                // SUCCESS: successfully removed
                // NOENT: fd was not registered (already removed or never added) - safe to proceed
                // BADF: fd was closed (and auto-removed from epoll) - safe to proceed
            },
            else => return unexpectedError(err),
        }
        return;
    }

    // Recalculate events from remaining completions
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

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.incrActive();

    switch (c.op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        // Synchronous operations - complete immediately
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
            // Tear down the persistent registration before the fd is closed, so a
            // future socket that reuses this fd number starts clean on every loop.
            self.unregisterSocket(data.handle);
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Connect - try connect() first, register with epoll only on WouldBlock.
        .net_connect => {
            const data = c.cast(NetConnect);
            if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
                // Connected immediately (e.g., localhost)
                c.setResult(.net_connect, {});
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Queue for completion - addToPollQueue handles errors
                    self.addToPollQueue(state, data.handle, c);
                },
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },

        // Streaming socket ops try the syscall first (optimistic, like
        // net_connect) and only register with epoll on WouldBlock. This both
        // avoids an arm/disarm when the socket is already ready and, together
        // with the persistent edge-triggered registration, drains the socket to
        // EAGAIN before we ever wait - which is what makes edge-triggered safe.
        .net_accept => {
            const data = c.cast(NetAccept);
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                c.setResult(.net_accept, handle);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
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
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
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
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                c.setResult(.net_recvfrom, n);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
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
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                c.setResult(.net_recvmsg, result);
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
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
                state.markCompletedFromBackend(c);
            } else |err| switch (err) {
                error.WouldBlock => self.addToPollQueue(state, data.handle, c),
                else => {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                },
            }
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            // net_poll has no I/O to drain, so unlike recv/send it cannot rely on
            // the edge-triggered registration re-arming: a socket that is already
            // (and continuously) ready never produces a fresh edge, so waiting for
            // one would hang. Probe current readiness with a 0-timeout poll() -
            // the same "try first, wait only on not-ready" shape as the streaming
            // ops - and register for an edge only when it is not ready yet.
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
                self.addToPollQueue(state, data.handle, c);
            }
        },
        .pipe_poll => {
            const data = c.cast(PipePoll);
            self.addToPollQueue(state, data.handle, c);
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
        // Streaming file I/O is routed here by the loop only when the fd is
        // pollable (non-seekable), so it is handled exactly like pipe read/write.
        inline .file_read_streaming, .file_write_streaming => |op| {
            self.addToPollQueue(state, c.cast(op.toType()).handle, c);
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
            // Create pidfd for polling
            const rc = linux.pidfd_open(data.handle, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    data.internal.pidfd = @intCast(rc);
                    self.addToPollQueue(state, data.internal.pidfd, c);
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

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_size, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .file_stat, .dir_open, .dir_close, .dir_read, .dir_create_dir, .dir_rename, .dir_rename_preserve, .dir_delete_file, .dir_delete_dir, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link, .device_io_control => unreachable,
        // Driven by Loop's generic read/write fallback, never reaches the backend.
        .net_send_file => unreachable,
        .mach_port => unreachable,
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    // Try to remove from queue
    const fd = getHandle(target);
    self.removeFromPollQueue(fd, target) catch |err| {
        // Removal from epoll failed, but completion was already removed from
        // the poll queue linked list. Log the error but continue to complete
        // the target to avoid leaving it stuck in running state.
        log.err("Failed to remove completion from poll queue during cancel: {}", .{err});
    };

    // Close pidfd if this is a process_wait (it won't go through completion path)
    if (target.op == .process_wait) {
        const data = target.cast(ProcessWait);
        _ = linux.close(@intCast(data.internal.pidfd));
    }

    // Always complete target with error.Canceled
    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

/// Wait for events, preferring nanosecond-precision epoll_pwait2 and falling
/// back to millisecond epoll_wait on kernels without it. Returns the number of
/// ready events (0 on timeout or signal interruption).
fn waitEvents(self: *Self, timeout: Duration) !usize {
    if (self.epoll_pwait2_supported) {
        // null timespec blocks indefinitely; the loop never asks for that
        // (it caps at max_wait), but handle the sentinel defensively.
        var ts: linux.kernel_timespec = undefined;
        const ts_ptr: ?*const linux.kernel_timespec = if (timeout.value == Duration.max.value) null else blk: {
            const ns = timeout.toNanoseconds();
            ts = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
            break :blk &ts;
        };
        const rc = os_linux.epoll_pwait2(self.epoll_fd, self.events.ptr, @intCast(self.events.len), ts_ptr);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => return 0, // Interrupted by signal, no events
            .NOSYS => self.epoll_pwait2_supported = false, // Kernel < 5.11: fall back below
            else => |err| return unexpectedError(err),
        }
    }

    const timeout_ms: i32 = std.math.cast(i32, timeout.toMilliseconds()) orelse std.math.maxInt(i32);
    const rc = std.os.linux.epoll_wait(self.epoll_fd, self.events.ptr, @intCast(self.events.len), timeout_ms);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR => return 0, // Interrupted by signal, no events
        else => |err| return unexpectedError(err),
    }
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    // Reset pending changes counter before poll (less aggressive)
    self.pending_changes = 0;

    const n = try self.waitEvents(timeout);

    if (n == 0) {
        return true; // Timed out
    }

    for (self.events[0..n]) |event| {
        const fd = event.data.fd;

        // Check if this is the async wakeup fd
        if (fd == self.waker_eventfd) {
            _ = posix.eventfd_read(self.waker_eventfd) catch {};
            continue;
        }

        // A persistent socket registration can outlive its local entry (e.g. the
        // fiber migrated to another loop, or the last op already drained). Such
        // edges have no waiter here and are simply ignored - edge-triggered means
        // the data stays in the socket buffer and the next operation's optimistic
        // syscall picks it up.
        const entry = self.poll_queue.get(fd) orelse continue;

        var iter: ?*Completion = entry.completions.head;
        while (iter) |completion| {
            iter = completion.next;

            // Skip if already completed (can happen with cancellations)
            if (completion.state == .completed or completion.state == .dead) {
                continue;
            }

            switch (checkCompletion(completion, &event)) {
                .completed => {
                    try self.removeFromPollQueue(fd, completion);
                    state.markCompletedFromBackend(completion);
                },
                .requeue => {
                    // Spurious wakeup - keep in poll queue
                },
            }
        }
    }

    return false; // Did not timeout, woke up due to events
}

const CheckResult = enum { completed, requeue };

fn handleEpollError(event: *const std.os.linux.epoll_event, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = net.getSockError(event.data.fd) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
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
            // For poll operations, we want to know when the socket is "ready"
            // This includes error conditions (EPOLLERR, EPOLLHUP) because they
            // indicate the socket is ready to return an error on the next I/O
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;

            if (has_error or has_hup) {
                // Socket has error or hangup - it's "ready"
                c.setResult(.net_poll, {});
                return .completed;
            }

            // Check if the requested events are actually ready
            const requested_events = getEvents(c);
            const ready_events = event.events & requested_events;
            if (ready_events != 0) {
                c.setResult(.net_poll, {});
                return .completed;
            }
            // Requested events not ready yet - requeue
            return .requeue;
        },
        inline .file_read_streaming => |op| {
            const data = c.cast(op.toType());
            // Try to read - there might still be data in the pipe buffer
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // For pipes, HUP means the write end is closed
                    // If we got WouldBlock and HUP is set, that's EOF (no more data)
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
            // For pipes, check for errors but don't use getSockError
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
            if (has_error or has_hup) {
                // Pipe error or read end closed
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
        .pipe_close => unreachable, // Handled synchronously in submit
        .pipe_create => unreachable, // Handled synchronously in submit
        .pipe_poll => {
            // For poll operations, we want to know when the fd is "ready"
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;

            if (has_error or has_hup) {
                // Stream has error or hangup - it's "ready"
                c.setResult(.pipe_poll, {});
                return .completed;
            }

            // Check if the requested events are actually ready
            const requested_events = getEvents(c);
            const ready_events = event.events & requested_events;
            if (ready_events != 0) {
                c.setResult(.pipe_poll, {});
                return .completed;
            }
            // Requested events not ready yet - requeue
            return .requeue;
        },
        .process_wait => {
            // pidfd is readable - process has exited, get the status
            const data = c.cast(ProcessWait);
            defer _ = linux.close(@intCast(data.internal.pidfd));

            var siginfo: linux.siginfo_t = undefined;
            const wait_rc = linux.waitid(.PIDFD, @intCast(data.internal.pidfd), &siginfo, linux.W.EXITED, null);
            switch (posix.errno(wait_rc)) {
                .SUCCESS => {
                    // Extract exit status from siginfo
                    // With waitid(), si_status contains the value directly (not encoded like waitpid)
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
