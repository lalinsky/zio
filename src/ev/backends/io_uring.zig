const std = @import("std");
const linux = std.os.linux;
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const fs = @import("../../os/fs.zig");
const linux_sys = @import("../../os/system/linux.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const common = @import("common.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Queue = @import("../queue.zig").Queue;
const Cancel = @import("../completion.zig").Cancel;

// user_data encoding. A *Completion pointer is aligned, so its low bit is 0;
// internal ops set the low bit and pack a kind (bits 1-2) plus, for the wall
// timers, a generation counter (bits 3+) so a stale timeout CQE that arrives
// after a re-arm can be told apart from the current one and ignored.
const UD_SPECIAL: u64 = 1;

const SpecialKind = enum(u2) { waker = 0, cancel = 1, wall_boot = 2, wall_real = 3 };

fn specialUd(kind: SpecialKind, generation: u32) u64 {
    return UD_SPECIAL | (@as(u64, @intFromEnum(kind)) << 1) | (@as(u64, generation) << 3);
}

fn udIsSpecial(ud: u64) bool {
    return ud & UD_SPECIAL != 0;
}

fn udKind(ud: u64) SpecialKind {
    return @enumFromInt(@as(u2, @truncate(ud >> 1)));
}

fn udGeneration(ud: u64) u32 {
    return @truncate(ud >> 3);
}

fn wallKind(idx: usize) SpecialKind {
    return if (idx == 0) .wall_boot else .wall_real;
}

const NetOpen = @import("../completion.zig").NetOpen;
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
const NetShutdown = @import("../completion.zig").NetShutdown;
const FileOpen = @import("../completion.zig").FileOpen;
const FileCreate = @import("../completion.zig").FileCreate;
const DirCreateDir = @import("../completion.zig").DirCreateDir;
const DirRename = @import("../completion.zig").DirRename;
const DirRenamePreserve = @import("../completion.zig").DirRenamePreserve;
const DirDeleteFile = @import("../completion.zig").DirDeleteFile;
const DirDeleteDir = @import("../completion.zig").DirDeleteDir;
const FileSize = @import("../completion.zig").FileSize;
const FileStat = @import("../completion.zig").FileStat;
const FileClose = @import("../completion.zig").FileClose;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;
const FileReadStreaming = @import("../completion.zig").FileReadStreaming;
const FileWriteStreaming = @import("../completion.zig").FileWriteStreaming;
const FileSync = @import("../completion.zig").FileSync;
const FileSetSize = @import("../completion.zig").FileSetSize;
const DirOpen = @import("../completion.zig").DirOpen;
const DirClose = @import("../completion.zig").DirClose;
const PipePoll = @import("../completion.zig").PipePoll;
const PipeClose = @import("../completion.zig").PipeClose;
const ProcessWait = @import("../completion.zig").ProcessWait;

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .file_read = true,
    .file_write = true,
    .file_read_streaming = true,
    .file_write_streaming = true,
    .file_open = true,
    .file_create = true,
    .file_close = true,
    .file_sync = true,
    // Runtime-dispatched, not statically native: the native IORING_OP_FTRUNCATE
    // needs Linux >= 6.9. `false` makes the completion carry a DelegatedWork so
    // the thread-pool path is available; the Loop upgrades to the native SQE at
    // runtime when `fileSetSizeSupported()` (probed once) says the kernel has it.
    .file_set_size = false,
    .dir_create_dir = true,
    .dir_rename = true,
    .dir_rename_preserve = true,
    .dir_delete_file = true,
    .dir_delete_dir = true,
    .file_size = true,
    .file_stat = true,
    .dir_open = true,
    .dir_close = true,
    .process_wait = true,
    .native_wall_timers = true,
};

// Tri-state for the once-probed IORING_OP_FTRUNCATE support. `unknown` is treated
// as `no` at the dispatch site, so a missed/failed probe is always safe (the
// thread-pool fallback works on every kernel) — never a rejected SQE.
const ftruncate_unknown: u8 = 0;
const ftruncate_yes: u8 = 1;
const ftruncate_no: u8 = 2;

pub const SharedState = struct {
    master_fd: std.atomic.Value(c_int) = .init(-1),
    refcount: std.atomic.Value(usize) = .init(0),
    /// Whether the running kernel supports IORING_OP_FTRUNCATE (Linux >= 6.9),
    /// probed exactly once when the master ring is created (see `init`). Read by
    /// `fileSetSizeSupported()`.
    ftruncate_support: std.atomic.Value(u8) = .init(ftruncate_unknown),
};

pub const NetRecvData = struct {
    msg: linux.msghdr = undefined,
};

pub const NetSendData = struct {
    msg: linux.msghdr_const = undefined,
};

pub const NetRecvFromData = struct {
    msg: linux.msghdr = undefined,
};

pub const NetSendToData = struct {
    msg: linux.msghdr_const = undefined,
};

pub const NetRecvMsgData = struct {
    msg: linux.msghdr = undefined,
};

pub const NetSendMsgData = struct {
    msg: linux.msghdr_const = undefined,
};

pub const FileOpenData = struct {
    path: [:0]const u8 = "",
    how: linux_sys.open_how = undefined,
};

pub const FileCreateData = struct {
    path: [:0]const u8 = "",
    how: linux_sys.open_how = undefined,
};

pub const DirCreateDirData = struct {
    path: [:0]const u8 = "",
};

pub const DirRenameData = struct {
    old_path: [:0]const u8 = "",
    new_path: [:0]const u8 = "",
};

pub const DirRenamePreserveData = struct {
    old_path: [:0]const u8 = "",
    new_path: [:0]const u8 = "",
};

pub const DirDeleteFileData = struct {
    path: [:0]const u8 = "",
};

pub const DirDeleteDirData = struct {
    path: [:0]const u8 = "",
};

pub const FileSizeData = struct {
    statx: linux.Statx = std.mem.zeroes(linux.Statx),
};

pub const FileStatData = struct {
    statx: linux.Statx = std.mem.zeroes(linux.Statx),
    path: [:0]const u8 = "",
};

pub const DirOpenData = struct {
    path: [:0]const u8 = "",
};

pub const ProcessWaitData = struct {
    siginfo: linux.siginfo_t = undefined,
};

const Self = @This();

const log = @import("../../common.zig").log;

allocator: std.mem.Allocator,
ring: linux.IoUring,
waker_eventfd: i32,
waker_needs_rearm: bool,
pending: Queue(Completion) = .{},
/// Currently-armed absolute deadline (ns, in the clock's epoch) for the
/// boot/real wall-clock timeout SQEs, or null if disarmed. Indexed by
/// `wallIndex` (0 = boot, 1 = real).
wall_armed: [2]?u64 = .{ null, null },
/// Generation of each wall timer's current SQE, encoded in its user_data and
/// bumped on every (re)arm, so a stale timeout CQE is ignored.
wall_generation: [2]u32 = .{ 0, 0 },
/// Backing storage for the wall timeout `kernel_timespec`s; must outlive the
/// SQE until the next `io_uring_enter2` reads it.
wall_ts: [2]linux.kernel_timespec = undefined,
/// Reusable batch buffer for draining ready CQEs each poll. Kept on the struct
/// rather than as a per-poll stack array so safe builds poison it (0xAA) once
/// at init instead of memset-ing 4 KB on every tick — that fill showed up as
/// ~6% of a wake-heavy workload under ReleaseSafe. A single loop thread polls,
/// so there is no aliasing concern.
cqe_buf: [256]linux.io_uring_cqe = undefined,
shared_state: *SharedState,
/// Backend-internal inflight count: ops accepted by submit() and not yet
/// completed (in the SQ/kernel or parked on `pending`). This backend is
/// strictly per-loop (submit, poll, and completion on the owner thread), so a
/// plain counter suffices. Read by hasInflight() to skip the enter syscall
/// when nothing can arrive.
inflight: usize = 0,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    var flags: u32 = 0;
    flags |= linux.IORING_SETUP_SINGLE_ISSUER;
    flags |= linux.IORING_SETUP_DEFER_TASKRUN;
    flags |= linux.IORING_SETUP_COOP_TASKRUN;

    var ring = blk: {
        const master_fd = shared_state.master_fd.load(.seq_cst);
        if (master_fd != -1) {
            flags |= linux.IORING_SETUP_ATTACH_WQ;
            break :blk try ringFromMasterFd(master_fd, flags, queue_size);
        } else {
            var ring = try linux.IoUring.init(queue_size, flags);
            // Probe FTRUNCATE support once, on this fresh ring, and publish the
            // verdict BEFORE master_fd. Any executor that later attaches sees a
            // non-negative master_fd (seq_cst) and is thus guaranteed to observe
            // the stored verdict. Racing creators store the same kernel-global
            // value, so a redundant store by a CAS loser is harmless.
            probeAndStoreFtruncate(&ring, shared_state);
            const old_fd = shared_state.master_fd.cmpxchgStrong(-1, ring.fd, .seq_cst, .seq_cst);
            if (old_fd != null) {
                ring.deinit();
                flags |= linux.IORING_SETUP_ATTACH_WQ;
                break :blk try ringFromMasterFd(old_fd.?, flags, queue_size);
            }
            break :blk ring;
        }
    };
    errdefer ring.deinit();

    const waker_eventfd = try posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
    errdefer _ = linux.close(waker_eventfd);

    _ = shared_state.refcount.fetchAdd(1, .seq_cst);

    self.* = .{
        .allocator = allocator,
        .ring = ring,
        .waker_eventfd = waker_eventfd,
        .waker_needs_rearm = true,
        .shared_state = shared_state,
    };

    // Arm the multishot poll once. It stays armed across wakes, so the loop is
    // never deaf to wake() — the SQE rides the first enter2, covering the first
    // poll and startup. wake() just writes the eventfd.
    _ = self.armWaker();
}

/// Probe (once, via IORING_REGISTER_PROBE) whether the kernel knows the
/// IORING_OP_FTRUNCATE opcode (added in Linux 6.9) and record it in `SharedState`.
/// A failed probe records "no", so file_set_size takes the always-correct
/// thread-pool fallback rather than risk a rejected SQE.
fn probeAndStoreFtruncate(ring: *linux.IoUring, shared_state: *SharedState) void {
    const supported = blk: {
        const probe = ring.get_probe() catch break :blk false;
        break :blk probe.is_supported(.FTRUNCATE);
    };
    shared_state.ftruncate_support.store(if (supported) ftruncate_yes else ftruncate_no, .seq_cst);
}

/// Runtime capability query used by the Loop: may file_set_size use the native
/// IORING_OP_FTRUNCATE SQE, or must it fall back to the thread pool? Probed once
/// at ring creation; see `SharedState.ftruncate_support`.
pub fn fileSetSizeSupported(self: *Self) bool {
    return self.shared_state.ftruncate_support.load(.seq_cst) == ftruncate_yes;
}

fn ringFromMasterFd(master_fd: i32, flags: u32, queue_size: u16) !linux.IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = flags,
        .sq_thread_idle = 1000,
        .wq_fd = @as(u32, @intCast(master_fd)),
    });

    return try linux.IoUring.init_params(queue_size, &params);
}

pub fn deinit(self: *Self) void {
    _ = linux.close(self.waker_eventfd);
    const master_fd = self.shared_state.master_fd.load(.seq_cst);
    if (self.ring.fd == master_fd) {
        self.ring.cq.deinit();
        self.ring.sq.deinit();
        self.ring.fd = -1;
    } else self.ring.deinit();

    if (self.shared_state.refcount.fetchSub(1, .seq_cst) == 1) {
        if (master_fd != -1) {
            _ = linux.close(master_fd);
            _ = self.shared_state.master_fd.swap(-1, .seq_cst);
        }
    }
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    posix.eventfd_write(self.waker_eventfd, 1) catch {};
}

/// Arm the multishot poll on the waker eventfd if needed. Returns false only
/// when a rearm was needed but the SQ was full (caller must not block).
/// Normally a no-op: the poll is armed once and the kernel keeps it armed.
fn armWaker(self: *Self) bool {
    if (!self.waker_needs_rearm) return true;
    const sqe = self.ring.get_sqe() catch return false;
    sqe.prep_poll_add(self.waker_eventfd, linux.POLL.IN);
    sqe.len = linux.IORING_POLL_ADD_MULTI;
    sqe.user_data = specialUd(.waker, 0);
    self.waker_needs_rearm = false;
    return true;
}

fn drainWaker(self: *Self, cqe: linux.io_uring_cqe) void {
    // Clear the level-triggered readiness so the multishot poll doesn't refire.
    _ = posix.eventfd_read(self.waker_eventfd) catch {};
    // The multishot poll normally stays armed (F_MORE). If the kernel dropped
    // it, mark for re-arm on the next poll.
    if (cqe.flags & linux.IORING_CQE_F_MORE == 0) self.waker_needs_rearm = true;
}

/// Drop one inflight op. Called via LoopState.markCompletedFromBackend on the
/// owner thread.
pub fn decrInflight(self: *Self) void {
    self.inflight -= 1;
}

/// Whether poll() could produce completions. Used by the loop to skip the
/// wait syscall in no-wait ticks when nothing can arrive.
pub fn hasInflight(self: *const Self) bool {
    return self.inflight > 0;
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    // Counted once per accepted op (sync completers decrement right back via
    // markCompletedFromBackend); EINTR resubmissions go through resubmit and
    // stay counted from their first submit.
    self.inflight += 1;
    self.submitInner(state, c, true);
}

fn resubmit(self: *Self, state: *LoopState, c: *Completion) void {
    std.debug.assert(c.loadState().phase == .running);
    self.submitInner(state, c, false);
}

/// `is_new` distinguishes the first submission (allocate op-owned resources)
/// from an EINTR/SQ-full resubmission (reuse them).
fn submitInner(self: *Self, state: *LoopState, c: *Completion, is_new: bool) void {
    switch (c.op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        // Synchronous operations (no io_uring support or always immediate)
        .net_open => {
            const data = c.cast(NetOpen);
            if (net.socket(
                data.domain,
                data.socket_type,
                data.protocol,
                data.flags,
            )) |handle| {
                c.setResult(.net_open, handle);
            } else |err| {
                c.setError(err);
            }
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

        // Async operations through io_uring
        .net_connect => {
            const data = c.cast(NetConnect);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_connect(data.handle, data.addr, data.addr_len);
            sqe.user_data = @intFromPtr(c);
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_accept(data.handle, data.addr, data.addr_len, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            data.internal.msg = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffers.iovecs.ptr,
                .iovlen = data.buffers.iovecs.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_recvmsg(data.handle, &data.internal.msg, recvFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_send => {
            const data = c.cast(NetSend);
            data.internal.msg = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffer.iovecs.ptr,
                .iovlen = data.buffer.iovecs.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            data.internal.msg = .{
                .name = @ptrCast(data.addr),
                .namelen = if (data.addr_len) |len| len.* else 0,
                .iov = data.buffer.iovecs.ptr,
                .iovlen = data.buffer.iovecs.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_recvmsg(data.handle, &data.internal.msg, recvFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            data.internal.msg = .{
                .name = @ptrCast(data.addr),
                .namelen = data.addr_len,
                .iov = data.buffer.iovecs.ptr,
                .iovlen = data.buffer.iovecs.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            data.internal.msg = .{
                .name = if (data.addr) |addr| @ptrCast(addr) else null,
                .namelen = if (data.addr_len) |len| len.* else 0,
                .iov = data.data.iovecs.ptr,
                .iovlen = data.data.iovecs.len,
                .control = if (data.control) |ctl| ctl.ptr else null,
                .controllen = if (data.control) |ctl| ctl.len else 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_recvmsg(data.handle, &data.internal.msg, recvFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            data.internal.msg = .{
                .name = if (data.addr) |addr| @ptrCast(addr) else null,
                .namelen = data.addr_len,
                .iov = data.data.iovecs.ptr,
                .iovlen = data.data.iovecs.len,
                .control = if (data.control) |ctl| ctl.ptr else null,
                .controllen = if (data.control) |ctl| ctl.len else 0,
                .flags = 0,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            const sqe = self.getSqeOrDefer(c) orelse return;
            const poll_mask: u32 = switch (data.event) {
                .recv => linux.POLL.IN,
                .send => linux.POLL.OUT,
            };
            sqe.prep_poll_add(data.handle, poll_mask);
            sqe.user_data = @intFromPtr(c);
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_shutdown(data.handle, @intFromEnum(data.how));
            sqe.user_data = @intFromPtr(c);
        },
        .net_close => {
            const data = c.cast(NetClose);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },

        .file_open => {
            const data = c.cast(FileOpen);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const oflags = linux.O{
                .ACCMODE = switch (data.flags.mode) {
                    .read_only => .RDONLY,
                    .write_only => .WRONLY,
                    .read_write => .RDWR,
                },
                .CLOEXEC = true,
                .NOFOLLOW = !data.flags.follow_symlinks,
                .NOCTTY = !data.flags.allow_ctty,
                .PATH = data.flags.path_only,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            if (data.flags.resolve_beneath) {
                data.internal.how = .{
                    .flags = @as(u64, @as(u32, @bitCast(oflags))),
                    .mode = 0,
                    .resolve = linux_sys.RESOLVE.BENEATH | linux_sys.RESOLVE.NO_MAGICLINKS,
                };
                prep_openat2(sqe, data.dir, data.internal.path, &data.internal.how);
            } else {
                sqe.prep_openat(data.dir, data.internal.path, oflags, 0);
            }
            sqe.user_data = @intFromPtr(c);
        },
        .file_create => {
            const data = c.cast(FileCreate);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const oflags = linux.O{
                .ACCMODE = if (data.flags.read) .RDWR else .WRONLY,
                .CLOEXEC = true,
                .CREAT = true,
                .TRUNC = data.flags.truncate,
                .EXCL = data.flags.exclusive,
            };
            const sqe = self.getSqeOrDefer(c) orelse return;
            if (data.flags.resolve_beneath) {
                data.internal.how = .{
                    .flags = @as(u64, @as(u32, @bitCast(oflags))),
                    .mode = data.flags.mode,
                    .resolve = linux_sys.RESOLVE.BENEATH | linux_sys.RESOLVE.NO_MAGICLINKS,
                };
                prep_openat2(sqe, data.dir, data.internal.path, &data.internal.how);
            } else {
                sqe.prep_openat(data.dir, data.internal.path, oflags, data.flags.mode);
            }
            sqe.user_data = @intFromPtr(c);
        },
        .file_close => {
            const data = c.cast(FileClose);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },
        .file_read => {
            const data = c.cast(FileRead);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_readv(data.handle, data.buffer.iovecs, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
        .file_write => {
            const data = c.cast(FileWrite);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_writev(data.handle, data.buffer.iovecs, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
        .file_read_streaming => {
            const data = c.cast(FileReadStreaming);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_readv(data.handle, data.buffer.iovecs, @bitCast(@as(i64, -1)));
            sqe.user_data = @intFromPtr(c);
        },
        .file_write_streaming => {
            const data = c.cast(FileWriteStreaming);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_writev(data.handle, data.buffer.iovecs, @bitCast(@as(i64, -1)));
            sqe.user_data = @intFromPtr(c);
        },
        .file_sync => {
            const data = c.cast(FileSync);
            const sqe = self.getSqeOrDefer(c) orelse return;
            const flags: u32 = if (data.flags.only_data) linux.IORING_FSYNC_DATASYNC else 0;
            sqe.prep_fsync(data.handle, flags);
            sqe.user_data = @intFromPtr(c);
        },
        .file_set_size => {
            const data = c.cast(FileSetSize);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_rw(.FTRUNCATE, data.handle, 0, 0, @intCast(data.length));
            sqe.user_data = @intFromPtr(c);
        },
        .file_set_permissions => unreachable, // Handled by thread pool
        .file_set_owner => unreachable, // Handled by thread pool
        .file_set_timestamps => unreachable, // Handled by thread pool
        .dir_create_dir => {
            const data = c.cast(DirCreateDir);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_mkdirat(@intCast(data.dir), data.internal.path.ptr, data.mode);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_rename => {
            const data = c.cast(DirRename);
            if (is_new) {
                data.internal.old_path = self.allocator.dupeSentinel(u8, data.old_path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
                data.internal.new_path = self.allocator.dupeSentinel(u8, data.new_path, 0) catch {
                    self.allocator.free(data.internal.old_path);
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_renameat(@intCast(data.old_dir), data.internal.old_path.ptr, @intCast(data.new_dir), data.internal.new_path.ptr, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_rename_preserve => {
            const data = c.cast(DirRenamePreserve);
            if (is_new) {
                data.internal.old_path = self.allocator.dupeSentinel(u8, data.old_path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
                data.internal.new_path = self.allocator.dupeSentinel(u8, data.new_path, 0) catch {
                    self.allocator.free(data.internal.old_path);
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_renameat(@intCast(data.old_dir), data.internal.old_path.ptr, @intCast(data.new_dir), data.internal.new_path.ptr, @as(u32, @bitCast(linux.RENAME{ .NOREPLACE = true })));
            sqe.user_data = @intFromPtr(c);
        },
        .dir_delete_file => {
            const data = c.cast(DirDeleteFile);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_unlinkat(@intCast(data.dir), data.internal.path.ptr, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_delete_dir => {
            const data = c.cast(DirDeleteDir);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_unlinkat(@intCast(data.dir), data.internal.path.ptr, linux.AT.REMOVEDIR);
            sqe.user_data = @intFromPtr(c);
        },

        .file_size => {
            const data = c.cast(FileSize);
            const sqe = self.getSqeOrDefer(c) orelse return;
            // Use statx with empty pathname to get stats for the fd itself
            const mask: linux.STATX = .{ .SIZE = true };
            const flags = linux.AT.EMPTY_PATH;
            sqe.prep_statx(data.handle, "", flags, mask, &data.internal.statx);
            sqe.user_data = @intFromPtr(c);
        },

        .file_stat => {
            const data = c.cast(FileStat);
            const mask: linux.STATX = .{
                .TYPE = true,
                .MODE = true,
                .INO = true,
                .NLINK = true,
                .SIZE = true,
                .ATIME = true,
                .MTIME = true,
                .CTIME = true,
            };

            if (data.path) |user_path| {
                // Path provided - stat relative to handle
                if (is_new) {
                    data.internal.path = self.allocator.dupeSentinel(u8, user_path, 0) catch {
                        c.setError(error.SystemResources);
                        state.markCompletedFromBackend(c);
                        return;
                    };
                }
                const sqe = self.getSqeOrDefer(c) orelse return;
                const statx_flags: u32 = if (data.flags.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
                sqe.prep_statx(@intCast(data.handle), data.internal.path.ptr, statx_flags, mask, &data.internal.statx);
                sqe.user_data = @intFromPtr(c);
            } else {
                // No path - use AT_EMPTY_PATH to stat the fd itself
                const sqe = self.getSqeOrDefer(c) orelse return;
                sqe.prep_statx(data.handle, "", linux.AT.EMPTY_PATH, mask, &data.internal.statx);
                sqe.user_data = @intFromPtr(c);
            }
        },

        .dir_open => {
            const data = c.cast(DirOpen);
            if (is_new) {
                data.internal.path = self.allocator.dupeSentinel(u8, data.path, 0) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqeOrDefer(c) orelse return;
            var flags = linux.O{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
                .NOFOLLOW = !data.flags.follow_symlinks,
            };
            // On Linux, O_PATH can be used to open a directory descriptor without read permission
            // but only if we don't plan to iterate it
            if (!data.flags.iterate) {
                flags.PATH = true;
            }
            sqe.prep_openat(data.dir, data.internal.path, flags, 0);
            sqe.user_data = @intFromPtr(c);
        },

        .dir_close => {
            const data = c.cast(DirClose);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_set_permissions => unreachable, // Handled by thread pool
        .dir_set_owner => unreachable, // Handled by thread pool
        .dir_set_file_permissions => unreachable, // Handled by thread pool
        .dir_set_file_owner => unreachable, // Handled by thread pool
        .dir_set_file_timestamps => unreachable, // Handled by thread pool
        .dir_sym_link => unreachable, // Handled by thread pool
        .dir_read_link => unreachable, // Handled by thread pool
        .dir_hard_link => unreachable, // Handled by thread pool
        .dir_access => unreachable, // Handled by thread pool
        .dir_read => unreachable, // Handled by thread pool
        .dir_real_path => unreachable, // Handled by thread pool
        .dir_real_path_file => unreachable, // Handled by thread pool
        .file_real_path => unreachable, // Handled by thread pool
        .file_hard_link => unreachable, // Handled by thread pool
        .pipe_poll => {
            const data = c.cast(PipePoll);
            const sqe = self.getSqeOrDefer(c) orelse return;
            const poll_mask: u32 = switch (data.event) {
                .read => linux.POLL.IN,
                .write => linux.POLL.OUT,
            };
            sqe.prep_poll_add(data.handle, poll_mask);
            sqe.user_data = @intFromPtr(c);
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
        .pipe_close => {
            const data = c.cast(PipeClose);
            const sqe = self.getSqeOrDefer(c) orelse return;
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },
        .process_wait => {
            const data = c.cast(ProcessWait);
            const sqe = self.getSqeOrDefer(c) orelse return;
            // Use WAITID to wait for process exit
            sqe.prep_waitid(linux.P.PID, data.handle, &data.internal.siginfo, linux.W.EXITED, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .device_io_control => unreachable, // Handled via thread pool
        // Driven by Loop's generic read/write fallback, never reaches the backend.
        .net_send_file => unreachable,
        .mach_port => unreachable,
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, _: *LoopState, target: *Completion) void {
    switch (target.loadState().phase) {
        .new => {
            // UNREACHABLE: cancelLocal only forwards running completions.
            unreachable;
        },
        .running => {
            // Target is executing in io_uring. Submit a cancel SQE.
            // This will generate TWO CQEs:
            // 1. Cancel CQE (user_data=USER_DATA_CANCEL, res=0 or -ENOENT)
            // 2. Target CQE (user_data=target, res=-ECANCELED or success if cancel was too late)
            //
            // In poll(), we:
            // - Skip cancel CQEs with user_data=USER_DATA_CANCEL
            // - Process target CQE and mark target complete with error.Canceled (or natural result)
            const sqe = self.ring.get_sqe() catch {
                log.err("Failed to get io_uring SQE for cancel", .{});
                // Cancel SQE failed - do nothing, let target complete naturally
                return;
            };
            sqe.prep_cancel(@intFromPtr(target), 0);
            sqe.user_data = specialUd(.cancel, 0);
        },
        .completed, .dead => {
            // Target already completed (has result) or fully finished (callback called).
            // No CQEs will arrive. This shouldn't happen as loop.add()/loop.cancel() check state first.
            unreachable;
        },
    }
}

/// Get an SQE or defer the completion to the pending list if the SQ is full.
/// Returns null if deferred (caller should return immediately).
fn getSqeOrDefer(self: *Self, c: *Completion) ?*linux.io_uring_sqe {
    return self.ring.get_sqe() catch {
        self.pending.push(c);
        return null;
    };
}

/// Arm/update/disarm the native boot and real wall-clock timeout SQEs to the
/// given absolute deadlines (ns in each clock's epoch; null = none). Called by
/// the loop when the boot/real timer-heap minimums change; the SQEs ride the
/// next `io_uring_enter2`.
pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
    const idx: usize, const clock_flag: u32 = switch (clock) {
        .boot => .{ 0, linux.IORING_TIMEOUT_BOOTTIME },
        .real => .{ 1, linux.IORING_TIMEOUT_REALTIME },
        else => unreachable,
    };

    if (self.wall_armed[idx] == deadline) return true; // unchanged (incl. both null)

    // Remove the existing timeout (if any) before re-arming. The removed
    // timeout's CQE and the remove op's CQE are both ignored in poll(). If the
    // SQ is full, leave wall_armed unchanged (old timeout stays valid) and
    // report failure so the loop folds this clock into the capped poll timeout.
    if (self.wall_armed[idx] != null) {
        const sqe = self.ring.get_sqe() catch return false;
        sqe.prep_timeout_remove(specialUd(wallKind(idx), self.wall_generation[idx]), 0);
        sqe.user_data = specialUd(.cancel, 0);
    }

    if (deadline) |d| {
        const sqe = self.ring.get_sqe() catch {
            // Remove was queued but we can't arm the new timeout now. Forget it
            // (the next scan re-arms) and report failure so the loop folds.
            self.wall_armed[idx] = null;
            return false;
        };
        self.wall_generation[idx] +%= 1;
        self.wall_ts[idx] = .{
            .sec = @intCast(d / time.ns_per_s),
            .nsec = @intCast(d % time.ns_per_s),
        };
        sqe.prep_timeout(&self.wall_ts[idx], 0, linux.IORING_TIMEOUT_ABS | clock_flag);
        sqe.user_data = specialUd(wallKind(idx), self.wall_generation[idx]);
    }

    self.wall_armed[idx] = deadline;
    return true;
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    const linux_os = @import("../../os/linux.zig");

    // The waker poll is normally already armed (a no-op here). It only needs
    // re-arming in the rare case the kernel dropped the multishot; if the SQ is
    // full then, don't block — a non-blocking enter2 drains it so the next poll
    // can arm.
    // Don't block if a critical internal SQE (waker or a wall timer) still
    // needs arming — a zero-timeout enter2 drains the SQ so the next scan can.
    const effective_timeout: Duration = if (self.armWaker()) timeout else .zero;

    const to_submit = self.ring.flush_sq();
    var ts: linux.kernel_timespec = undefined;
    var arg: linux_os.io_uring_getevents_arg = .{
        .ts = if (effective_timeout.value == Duration.max.value) 0 else blk: {
            const timeout_ns = effective_timeout.toNanoseconds();
            ts = .{
                .sec = @intCast(timeout_ns / time.ns_per_s),
                .nsec = @intCast(timeout_ns % time.ns_per_s),
            };
            break :blk @intFromPtr(&ts);
        },
    };
    const flags: u32 = linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG;

    // Submit and wait using io_uring_enter2 with timeout
    _ = linux_os.io_uring_enter2(
        self.ring.fd,
        to_submit,
        1, // min_complete = 1 to wait for at least one completion or timeout
        flags,
        &arg,
        @sizeOf(linux_os.io_uring_getevents_arg),
    ) catch |err| switch (err) {
        error.SignalInterrupt => return true, // Interrupted, treat as timeout
        else => return err,
    };

    // Process all available completions
    const count = try self.ring.copy_cqes(&self.cqe_buf, 0);

    if (count == 0) {
        self.drainPending(state);
        return true; // Timed out
    }

    var wall_fired = false;
    for (self.cqe_buf[0..count]) |cqe| {
        // Internal ops carry the special low bit; completions are pointers.
        if (udIsSpecial(cqe.user_data)) {
            switch (udKind(cqe.user_data)) {
                .waker => self.drainWaker(cqe),
                .cancel => {}, // cancel/remove op completion — skip
                // Wall-clock (boot/real) timeout. A fire (-ETIME) of the current
                // generation means the timer is due: report a timeout below to
                // re-run checkTimers, and forget the armed deadline (the kernel
                // auto-removed the one-shot). A stale generation or -ECANCELED
                // (from re-arming) is ignored.
                .wall_boot, .wall_real => {
                    const idx: usize = if (udKind(cqe.user_data) == .wall_boot) 0 else 1;
                    if (cqe.res == -@as(i32, @intFromEnum(linux.E.TIME)) and
                        udGeneration(cqe.user_data) == self.wall_generation[idx] and
                        self.wall_armed[idx] != null)
                    {
                        wall_fired = true;
                        self.wall_armed[idx] = null;
                    }
                },
            }
            continue;
        }

        // Extract completion pointer from user_data
        const completion = @as(*Completion, @ptrFromInt(@as(usize, @intCast(cqe.user_data))));

        // Skip if already completed (can happen with cancellations)
        // When a target is canceled, it recursively completes the cancel operation
        // So when we get the cancel's CQE, it's already completed
        // Similarly, when we get the target's CQE after the cancel already completed it
        if (completion.loadState().phase != .running) {
            continue;
        }

        // Handle EINTR by deferring to pending — resubmit after armWaker so the
        // waker always gets priority over EINTR resubmissions.
        if (cqe.res == -@as(i32, @intFromEnum(linux.E.INTR))) {
            self.pending.push(completion);
            continue;
        }

        // Store the result in the completion
        self.storeResult(completion, cqe.res);

        // Mark as completed (also decrements inflight_io)
        state.markCompletedFromBackend(completion);
    }

    self.drainPending(state);

    // A fired wall timer is reported as a timeout so the loop re-runs
    // checkTimers and fires the due boot/real timers.
    return wall_fired;
}

fn drainPending(self: *Self, state: *LoopState) void {
    // Swap out the pending list so that re-deferred items during this drain go
    // into a fresh self.pending rather than back into the list we are iterating.
    var to_drain = self.pending;
    self.pending = .{};

    while (to_drain.pop()) |c| {
        if (c.loadState().cancel_requested) {
            // Complete canceled pending ops immediately rather than writing a SQE.
            // storeResult handles resource cleanup (e.g. allocated paths).
            self.storeResult(c, -@as(i32, @intFromEnum(linux.E.CANCELED)));
            state.markCompletedFromBackend(c);
        } else {
            // resubmit() will call getSqeOrDefer(); if the SQ fills up again the
            // completion lands in self.pending and will be retried next poll.
            self.resubmit(state, c);
        }
    }
}

fn storeResult(self: *Self, c: *Completion, res: i32) void {
    switch (c.op) {
        .group, .timer, .async, .work => unreachable,
        .net_open => unreachable,
        .net_bind => unreachable,
        .net_listen => unreachable,
        .dir_set_permissions => unreachable, // Handled synchronously
        .dir_set_owner => unreachable, // Handled synchronously
        .dir_set_file_permissions => unreachable, // Handled synchronously
        .dir_set_file_owner => unreachable, // Handled synchronously
        .dir_set_file_timestamps => unreachable, // Handled synchronously
        .dir_sym_link => unreachable, // Handled synchronously
        .dir_read_link => unreachable, // Handled synchronously
        .dir_hard_link => unreachable, // Handled synchronously
        .dir_access => unreachable, // Handled synchronously
        .dir_read => unreachable, // Handled synchronously
        .dir_real_path => unreachable, // Handled synchronously
        .dir_real_path_file => unreachable, // Handled synchronously
        .file_real_path => unreachable, // Handled synchronously
        .file_hard_link => unreachable, // Handled synchronously

        .net_connect => {
            if (res < 0) {
                c.setError(net.errnoToConnectError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_connect, {});
            }
        },
        .net_accept => {
            if (res < 0) {
                c.setError(net.errnoToAcceptError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_accept, @as(net.fd_t, @intCast(res)));
            }
        },
        .net_recv => {
            if (res < 0) {
                c.setError(net.errnoToRecvError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_recv, @as(usize, @intCast(res)));
            }
        },
        .net_send => {
            if (res < 0) {
                c.setError(net.errnoToSendError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_send, @as(usize, @intCast(res)));
            }
        },
        .net_recvfrom => {
            if (res < 0) {
                c.setError(net.errnoToRecvError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_recvfrom, @as(usize, @intCast(res)));
                // Propagate the peer address length filled in by the kernel
                const data = c.cast(NetRecvFrom);
                if (data.addr_len) |len_ptr| {
                    len_ptr.* = data.internal.msg.namelen;
                }
            }
        },
        .net_sendto => {
            if (res < 0) {
                c.setError(net.errnoToSendError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_sendto, @as(usize, @intCast(res)));
            }
        },
        .net_recvmsg => {
            if (res < 0) {
                c.setError(net.errnoToRecvError(@enumFromInt(-res)));
            } else {
                const data = c.cast(NetRecvMsg);
                c.setResult(.net_recvmsg, .{
                    .len = @as(usize, @intCast(res)),
                    .flags = data.internal.msg.flags,
                    .controllen = @intCast(data.internal.msg.controllen),
                });
                // Propagate the peer address length filled in by the kernel
                if (data.addr_len) |len_ptr| {
                    len_ptr.* = data.internal.msg.namelen;
                }
            }
        },
        .net_sendmsg => {
            if (res < 0) {
                c.setError(net.errnoToSendError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_sendmsg, @as(usize, @intCast(res)));
            }
        },
        .net_poll => {
            if (res < 0) {
                c.setError(net.errnoToRecvError(@enumFromInt(-res)));
            } else {
                // Poll succeeded - requested events are ready
                c.setResult(.net_poll, {});
            }
        },
        .net_shutdown => {
            if (res < 0) {
                c.setError(net.errnoToShutdownError(@enumFromInt(-res)));
            } else {
                c.setResult(.net_shutdown, {});
            }
        },
        .net_close => {
            // Close errors and cancelations are generally ignored
            // But we still need to use setResult to handle cancelation race conditions
            c.setResult(.net_close, {});
        },

        .file_open => {
            const data = c.cast(FileOpen);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToFileOpenError(@enumFromInt(-res), data.flags));
            } else {
                c.setResult(.file_open, .{ .fd = res });
            }
        },

        .file_create => {
            const data = c.cast(FileCreate);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToFileOpenError(@enumFromInt(-res), data.flags));
            } else {
                c.setResult(.file_create, .{ .fd = res });
            }
        },

        .file_close => {
            if (res < 0) {
                c.setError(fs.errnoToFileCloseError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_close, {});
            }
        },

        .file_read => {
            if (res < 0) {
                c.setError(fs.errnoToFileReadError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_read, @intCast(res));
            }
        },

        .file_write => {
            if (res < 0) {
                c.setError(fs.errnoToFileWriteError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_write, @intCast(res));
            }
        },

        .file_read_streaming => {
            if (res < 0) {
                c.setError(fs.errnoToFileReadError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_read_streaming, @intCast(res));
            }
        },

        .file_write_streaming => {
            if (res < 0) {
                c.setError(fs.errnoToFileWriteError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_write_streaming, @intCast(res));
            }
        },

        .file_sync => {
            if (res < 0) {
                c.setError(fs.errnoToFileSyncError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_sync, {});
            }
        },

        .file_set_size => {
            if (res < 0) {
                c.setError(fs.errnoToFileSetSizeError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_set_size, {});
            }
        },

        .file_set_permissions => unreachable, // Handled synchronously
        .file_set_owner => unreachable, // Handled synchronously
        .file_set_timestamps => unreachable, // Handled synchronously

        .dir_create_dir => {
            const data = c.cast(DirCreateDir);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToDirCreateDirError(@enumFromInt(-res)));
            } else {
                c.setResult(.dir_create_dir, {});
            }
        },

        .dir_rename => {
            const data = c.cast(DirRename);
            self.allocator.free(data.internal.old_path);
            self.allocator.free(data.internal.new_path);
            if (res < 0) {
                c.setError(fs.errnoToDirRenameError(@enumFromInt(-res)));
            } else {
                c.setResult(.dir_rename, {});
            }
        },

        .dir_rename_preserve => {
            const data = c.cast(DirRenamePreserve);
            self.allocator.free(data.internal.old_path);
            self.allocator.free(data.internal.new_path);
            if (res < 0) {
                const errno: linux.E = @enumFromInt(-res);
                if (errno == .EXIST) {
                    c.setError(error.PathAlreadyExists);
                } else {
                    c.setError(fs.errnoToDirRenameError(errno));
                }
            } else {
                c.setResult(.dir_rename_preserve, {});
            }
        },

        .dir_delete_file => {
            const data = c.cast(DirDeleteFile);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToDirDeleteFileError(@enumFromInt(-res)));
            } else {
                c.setResult(.dir_delete_file, {});
            }
        },

        .dir_delete_dir => {
            const data = c.cast(DirDeleteDir);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToDirDeleteDirError(@enumFromInt(-res)));
            } else {
                c.setResult(.dir_delete_dir, {});
            }
        },

        .file_size => {
            const data = c.cast(FileSize);
            if (res < 0) {
                c.setError(fs.errnoToFileSizeError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_size, data.internal.statx.size);
            }
        },

        .file_stat => {
            const data = c.cast(FileStat);
            // Free path if it was allocated (only when user provided a path)
            if (data.path != null) {
                self.allocator.free(data.internal.path);
            }
            if (res < 0) {
                c.setError(fs.errnoToFileStatError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_stat, statxToFileStat(data.internal.statx));
            }
        },

        .dir_open => {
            const data = c.cast(DirOpen);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToDirOpenError(@enumFromInt(-res), data.flags));
            } else {
                c.setResult(.dir_open, res);
            }
        },

        .dir_close => {
            if (res < 0) {
                c.setError(fs.errnoToFileCloseError(@enumFromInt(-res)));
            } else {
                c.setResult(.dir_close, {});
            }
        },
        .pipe_poll => {
            if (res < 0) {
                c.setError(fs.errnoToFileReadError(@enumFromInt(-res)));
            } else {
                c.setResult(.pipe_poll, {});
            }
        },
        .pipe_create => unreachable, // Handled synchronously
        .pipe_close => {
            if (res < 0) {
                c.setError(fs.errnoToFileCloseError(@enumFromInt(-res)));
            } else {
                c.setResult(.pipe_close, {});
            }
        },
        .process_wait => {
            if (res < 0) {
                const err: linux.E = @enumFromInt(-res);
                switch (err) {
                    .CHILD => c.setError(error.ProcessNotFound),
                    else => c.setError(error.Unexpected),
                }
            } else {
                // Extract exit status from siginfo
                // With waitid(), si_status contains the value directly (not encoded like waitpid)
                const data = c.cast(ProcessWait);
                const si_status = data.internal.siginfo.fields.common.second.sigchld.status;
                const si_code = data.internal.siginfo.code;
                const CLD_EXITED = 1;
                const CLD_KILLED = 2;
                const CLD_DUMPED = 3;
                const terminated_by_signal = (si_code == CLD_KILLED or si_code == CLD_DUMPED);
                c.setResult(.process_wait, .{
                    .code = if (si_code == CLD_EXITED) @intCast(si_status) else 0,
                    .signal = if (terminated_by_signal) @intCast(si_status) else null,
                });
            }
        },
        .device_io_control => unreachable, // Handled via thread pool
        // Driven by Loop's generic read/write fallback, never reaches the backend.
        .net_send_file => unreachable,
        .mach_port => unreachable,
    }
}

fn statxToFileStat(statx: linux.Statx) fs.FileStatInfo {
    const S = linux.S;
    const kind: fs.FileKind = switch (statx.mode & S.IFMT) {
        S.IFBLK => .block_device,
        S.IFCHR => .character_device,
        S.IFDIR => .directory,
        S.IFIFO => .named_pipe,
        S.IFLNK => .sym_link,
        S.IFREG => .file,
        S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };

    return .{
        .inode = statx.ino,
        .nlink = statx.nlink,
        .size = statx.size,
        .mode = statx.mode,
        .kind = kind,
        .block_size = statx.blksize,
        .atime = statxTimeToNanos(statx.atime),
        .mtime = statxTimeToNanos(statx.mtime),
        .ctime = statxTimeToNanos(statx.ctime),
    };
}

fn statxTimeToNanos(ts: linux.statx_timestamp) i64 {
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn recvFlagsToMsg(flags: net.RecvFlags) u32 {
    var msg_flags: u32 = 0;
    if (flags.peek) msg_flags |= linux.MSG.PEEK;
    if (flags.waitall) msg_flags |= linux.MSG.WAITALL;
    if (flags.oob) msg_flags |= linux.MSG.OOB;
    if (flags.trunc) msg_flags |= linux.MSG.TRUNC;
    return msg_flags;
}

fn sendFlagsToMsg(flags: net.SendFlags) u32 {
    var msg_flags: u32 = 0;
    if (flags.no_signal) msg_flags |= linux.MSG.NOSIGNAL;
    return msg_flags;
}

fn prep_openat2(sqe: *linux.io_uring_sqe, fd: linux.fd_t, path: [*:0]const u8, how: *const linux_sys.open_how) void {
    sqe.* = .{
        .opcode = .OPENAT2,
        .fd = fd,
        .addr = @intFromPtr(path),
        .len = @sizeOf(linux_sys.open_how),
        .off = @intFromPtr(how),
        .user_data = 0,
        .flags = 0,
        .ioprio = 0,
        .rw_flags = 0,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .resv = 0,
    };
}
