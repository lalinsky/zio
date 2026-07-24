const std = @import("std");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const common = @import("common.zig");

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
const sockreg = @import("../sockreg.zig");

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .process_wait = true,
    .native_wall_timers = true,
};

pub const SharedState = struct {
    /// Backend-internal inflight count: ops accepted by submit() and not yet
    /// completed. A completion submitted on one loop may be finished by the
    /// loop that owns the fd registration, so the count is a group-shared
    /// atomic (either loop's decrInflight hits the same storage). Read by
    /// hasInflight() to skip the poll syscall when nothing can arrive.
    inflight_io: std.atomic.Value(usize) = .init(0),
    /// Cross-loop single-owner socket registration table, shared by every loop
    /// in the group. See sockreg.zig.
    sock_table: sockreg.Table = .{},
};

// Persistent edge-triggered interest used for sockets. A socket fd is added to
// its owner loop's epoll once per direction it owns and stays registered for the
// fd's lifetime (no per-op MOD on read/write switch, no DEL on completion).
// Edge-triggered is safe because submit() always tries the syscall first
// (draining to EAGAIN) before it ever waits, so no readiness edge is missed.
const epoll_et: u32 = linux.EPOLL.ET;

// epoll_event.data.u64 tag bit distinguishing socket registrations (single-owner
// path) from everything else (waker, wall timerfds, one-shot poll_queue fds).
// fds are small non-negative i32, so bit 32 is always free to use as the tag.
const sock_tag: u64 = 1 << 32;

fn sockData(fd: NetHandle) u64 {
    return sock_tag | @as(u64, @as(u32, @bitCast(fd)));
}

fn fdData(fd: i32) u64 {
    return @as(u64, @as(u32, @bitCast(fd)));
}

fn eventFd(event: *const linux.epoll_event) i32 {
    return @bitCast(@as(u32, @truncate(event.data.u64)));
}

fn eventIsSocket(event: *const linux.epoll_event) bool {
    return (event.data.u64 & sock_tag) != 0;
}

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
/// Shared cross-loop socket registration table (see sockreg.zig). All loops in
/// a group point at the same table.
shared: *SharedState = undefined,
epoll_fd: i32 = -1,
waker_eventfd: i32 = -1,
/// timerfds for the boot/real wall-clock timers (index 0 = boot, 1 = real),
/// armed by `syncWallTimers`. `wall_armed[i]` is the currently-armed absolute
/// deadline (ns in that clock's epoch) for dedup, or null if disarmed.
wall_timerfd: [2]i32 = .{ -1, -1 },
wall_armed: [2]?u64 = .{ null, null },
events: []std.os.linux.epoll_event,
queue_size: u16,
pending_changes: usize = 0,
/// Whether epoll_pwait2 (nanosecond timeout, Linux 5.11+) is available. Set to
/// false the first time the syscall returns ENOSYS, after which we use the
/// millisecond epoll_wait for the rest of this loop's lifetime.
epoll_pwait2_supported: bool = true,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    shared_state.sock_table.acquire(allocator);
    errdefer shared_state.sock_table.release();
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
        .data = .{ .u64 = fdData(waker_eventfd) },
    };
    const ctl_rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, waker_eventfd, &event);
    if (posix.errno(ctl_rc) != .SUCCESS) {
        return unexpectedError(posix.errno(ctl_rc));
    }

    self.* = .{
        .allocator = allocator,
        .shared = shared_state,
        .epoll_fd = epoll_fd,
        .waker_eventfd = waker_eventfd,
        .events = undefined,
        .queue_size = queue_size,
    };

    self.events = try allocator.alloc(std.os.linux.epoll_event, queue_size);
    errdefer allocator.free(self.events);

    try self.poll_queue.ensureTotalCapacity(self.allocator, queue_size);

    // Boot/real wall-clock timers: a persistent timerfd each, registered for
    // readiness now and armed absolutely by syncWallTimers.
    self.wall_timerfd[0] = try addWallTimerfd(epoll_fd, .BOOTTIME);
    errdefer closeWallTimerfd(epoll_fd, self.wall_timerfd[0]);
    self.wall_timerfd[1] = try addWallTimerfd(epoll_fd, .REALTIME);
    errdefer closeWallTimerfd(epoll_fd, self.wall_timerfd[1]);
}

/// Create a timerfd on `clockid` and register it with `epoll_fd` for readiness.
fn addWallTimerfd(epoll_fd: i32, clockid: linux.timerfd_clockid_t) !i32 {
    const rc = linux.timerfd_create(clockid, .{ .CLOEXEC = true, .NONBLOCK = true });
    const fd: i32 = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = linux.close(fd);
    var event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = fdData(fd) } };
    switch (posix.errno(linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &event))) {
        .SUCCESS => return fd,
        else => |err| return unexpectedError(err),
    }
}

fn closeWallTimerfd(epoll_fd: i32, fd: i32) void {
    if (fd == -1) return;
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
    _ = linux.close(fd);
}

pub fn deinit(self: *Self) void {
    if (self.waker_eventfd != -1) {
        _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, self.waker_eventfd, null);
        _ = std.os.linux.close(self.waker_eventfd);
    }
    closeWallTimerfd(self.epoll_fd, self.wall_timerfd[0]);
    closeWallTimerfd(self.epoll_fd, self.wall_timerfd[1]);
    self.poll_queue.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.epoll_fd != -1) {
        _ = std.os.linux.close(self.epoll_fd);
    }
    self.shared.sock_table.release();
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    posix.eventfd_write(self.waker_eventfd, 1) catch {};
}

/// Arm/update/disarm the given wall clock's timerfd to an absolute deadline (ns
/// in that clock's epoch; null = disarm). Returns false only if it couldn't arm
/// a pending deadline, so the loop folds that clock into the capped poll timeout.
pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
    const idx: usize = switch (clock) {
        .boot => 0,
        .real => 1,
        else => unreachable,
    };
    if (self.wall_armed[idx] == deadline) return true; // unchanged (incl. both null)
    // A zero it_value disarms; otherwise an absolute one-shot. checkTimers only
    // ever passes future deadlines, so 0 never means "fire now".
    var its: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 0 },
    };
    if (deadline) |d| {
        its.it_value = .{ .sec = @intCast(d / time.ns_per_s), .nsec = @intCast(d % time.ns_per_s) };
    }
    switch (posix.errno(linux.timerfd_settime(self.wall_timerfd[idx], .{ .ABSTIME = true }, &its, null))) {
        .SUCCESS => {
            self.wall_armed[idx] = deadline;
            return true;
        },
        else => |err| {
            log.err("timerfd_settime failed: {}", .{err});
            // Only signal failure when a pending deadline couldn't be armed; a
            // failed disarm has no pending deadline to fold into the poll cap.
            return deadline == null;
        },
    }
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

/// Add a completion to the poll queue, merging with existing fd if present.
/// If queuing fails, completes the completion with error.Unexpected.
fn addToPollQueue(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
    // If at capacity, flush with non-blocking poll to drain completions
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
            .data = .{ .u64 = fdData(fd) },
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
            .data = .{ .u64 = fdData(fd) },
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
            .data = .{ .u64 = fdData(fd) },
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

// ---- single-owner socket registration path ----------------------------------

// Backend hooks for the generic single-owner socket path in sockreg.zig.

const epoll_bit_in: u32 = linux.EPOLL.IN;
const epoll_bit_out: u32 = linux.EPOLL.OUT;

fn dirBit(dir: sockreg.Dir) u32 {
    return switch (dir) {
        .read => epoll_bit_in,
        .write => epoll_bit_out,
    };
}

/// Arm this loop's epoll for `(fd, dir)`, edge-triggered and persistent. If this
/// loop already owns the other direction, the fd is already in this epoll, so MOD
/// the combined mask; otherwise ADD. Called by sockreg.park.
pub fn registerSocket(self: *Self, fd: NetHandle, dir: sockreg.Dir, other_owned_here: bool) bool {
    const cur_mask: u32 = if (other_owned_here) dirBit(sockreg.other(dir)) else 0;
    const new_mask = cur_mask | dirBit(dir) | epoll_et;
    var event = linux.epoll_event{ .data = .{ .u64 = sockData(fd) }, .events = new_mask };
    const ctl: u32 = if (cur_mask == 0) linux.EPOLL.CTL_ADD else linux.EPOLL.CTL_MOD;
    switch (posix.errno(linux.epoll_ctl(self.epoll_fd, ctl, fd, &event))) {
        .SUCCESS => return true,
        // Stale registration survived a teardown; MOD to the desired mask.
        .EXIST => return posix.errno(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &event)) == .SUCCESS,
        else => |err| {
            log.err("Failed to epoll_ctl socket: {}", .{err});
            return false;
        },
    }
}

/// Drop this loop's epoll entry for `fd` (best-effort: ENOENT if owned elsewhere;
/// the kernel drops the rest when the fd is closed). Called by sockreg.unregister.
pub fn unregisterCleanup(self: *Self, fd: NetHandle) void {
    _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
}

/// A no-error event for the optimistic (pre-park) checkCompletion attempt.
pub fn probeEvent(fd: NetHandle, dir: sockreg.Dir) linux.epoll_event {
    _ = dir;
    return .{ .data = .{ .u64 = sockData(fd) }, .events = 0 };
}

/// Drop one inflight op. Called via LoopState.markCompletedFromBackend from
/// whichever loop finishes the op; the storage is group-shared, so any
/// instance's decrement balances any instance's increment.
pub fn decrInflight(self: *Self) void {
    _ = self.shared.inflight_io.fetchSub(1, .monotonic);
}

/// Whether poll() could produce completions. Used by the loop to skip the
/// wait syscall in no-wait ticks when nothing can arrive.
pub fn hasInflight(self: *const Self) bool {
    return self.shared.inflight_io.load(.monotonic) > 0;
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    // Counted for every accepted op (sync completers decrement right back via
    // markCompletedFromBackend), mirroring the decrInflight in every completion
    // path so the balance needs no per-path reasoning.
    _ = self.shared.inflight_io.fetchAdd(1, .monotonic);

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
            sockreg.unregister(self, data.handle);
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Sockets take the single-owner, persistent edge-triggered path: try the
        // syscall optimistically, register with the owning loop only on WouldBlock.
        .net_connect => sockreg.submitConnect(self, state, c),
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_sendmsg,
        => sockreg.submitIo(self, state, c),
        .net_poll => sockreg.submitPoll(self, state, c),
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
    if (sockreg.isSocketOp(target.op)) {
        // Sockets are parked in the shared (fd, dir) waiter queue of the loop that
        // owns the poller registration, which need not be this one: the op stays
        // owned by its submitting loop (see sockreg.park), so this cancel can run
        // concurrently with the owner servicing the op on another thread. detach
        // claims the op against that race; if it lost, the owner already produced
        // a natural result, so leave the op alone rather than overwriting it with
        // Canceled and completing it twice. cancel is advisory - the callback
        // still fires exactly once, and cancelLocal's epilogue dispatches the
        // completion once the owner marks it completed. The epoll registration is
        // persistent and left in place for the fd's lifetime.
        if (!sockreg.detach(self, target)) return;
    } else {
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

    var wall_fired = false;
    for (self.events[0..n]) |event| {
        // Sockets (single-owner path): service the ready directions. ERR/HUP is
        // delivered to both so a pending op on either side returns the error.
        if (eventIsSocket(&event)) {
            const sock_fd = eventFd(&event);
            const ev = event.events;
            const err_hup = ev & (linux.EPOLL.ERR | linux.EPOLL.HUP);
            if ((ev & linux.EPOLL.IN) != 0 or err_hup != 0)
                sockreg.service(self, state, sock_fd, .read, &event);
            if ((ev & linux.EPOLL.OUT) != 0 or err_hup != 0)
                sockreg.service(self, state, sock_fd, .write, &event);
            continue;
        }

        const fd = eventFd(&event);

        // Check if this is the async wakeup fd
        if (fd == self.waker_eventfd) {
            _ = posix.eventfd_read(self.waker_eventfd) catch {};
            continue;
        }

        // A boot/real wall timer fired: drain the expiration count and report a
        // timeout so the loop re-runs checkTimers and fires the due timers.
        if (fd == self.wall_timerfd[0] or fd == self.wall_timerfd[1]) {
            var buf: u64 = undefined;
            _ = std.os.linux.read(fd, std.mem.asBytes(&buf), @sizeOf(u64));
            wall_fired = true;
            continue;
        }

        const entry = self.poll_queue.get(fd) orelse continue;

        var iter: ?*Completion = entry.completions.head;
        while (iter) |completion| {
            iter = completion.next;

            // Skip if already completed (can happen with cancellations)
            if (completion.loadState().phase != .running) {
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

    // A fired wall timer is reported as a timeout so the loop re-runs
    // checkTimers and fires the due boot/real timers.
    return wall_fired;
}

const CheckResult = enum { completed, requeue };

fn handleEpollError(event: *const std.os.linux.epoll_event, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = net.getSockError(eventFd(event)) catch return error.Unexpected;
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
