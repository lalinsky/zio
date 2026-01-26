const std = @import("std");
const linux = std.os.linux;
const posix_os = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const fs = @import("../../os/fs.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const common = @import("common.zig");
const ReadBuf = @import("../buf.zig").ReadBuf;
const WriteBuf = @import("../buf.zig").WriteBuf;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
const Queue = @import("../queue.zig").Queue;
const Cancel = @import("../completion.zig").Cancel;

// Special user_data values for internal operations
const USER_DATA_WAKER: u64 = 0; // Waker FUTEX_WAIT operations
const USER_DATA_CANCEL: u64 = 1; // Cancel SQE operations (should be skipped)

// Futex constants for io_uring FUTEX_WAIT/WAKE
const FUTEX_BITSET_MATCH_ANY: u64 = 0xffffffff;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
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
const DirDeleteFile = @import("../completion.zig").DirDeleteFile;
const DirDeleteDir = @import("../completion.zig").DirDeleteDir;
const FileSize = @import("../completion.zig").FileSize;
const FileStat = @import("../completion.zig").FileStat;
const FileClose = @import("../completion.zig").FileClose;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;
const FileSync = @import("../completion.zig").FileSync;
const FileSetSize = @import("../completion.zig").FileSetSize;
const DirOpen = @import("../completion.zig").DirOpen;
const DirClose = @import("../completion.zig").DirClose;
const FileStreamPoll = @import("../completion.zig").FileStreamPoll;
const FileStreamRead = @import("../completion.zig").FileStreamRead;
const FileStreamWrite = @import("../completion.zig").FileStreamWrite;

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .file_read = true,
    .file_write = true,
    .file_open = true,
    .file_create = true,
    .file_close = true,
    .file_sync = true,
    .file_set_size = true,
    .dir_create_dir = true,
    .dir_rename = true,
    .dir_delete_file = true,
    .dir_delete_dir = true,
    .file_size = true,
    .file_stat = true,
    .dir_open = true,
    .dir_close = true,
};

pub const SharedState = struct {};

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
};

pub const FileCreateData = struct {
    path: [:0]const u8 = "",
};

pub const DirCreateDirData = struct {
    path: [:0]const u8 = "",
};

pub const DirRenameData = struct {
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

const Self = @This();

const log = std.log.scoped(.zio_uring);

allocator: std.mem.Allocator,
ring: linux.IoUring,
waker_needs_rearm: bool,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    _ = shared_state;
    var flags: u32 = 0;
    flags |= linux.IORING_SETUP_SINGLE_ISSUER;
    flags |= linux.IORING_SETUP_DEFER_TASKRUN;
    flags |= linux.IORING_SETUP_COOP_TASKRUN;

    var ring = try linux.IoUring.init(queue_size, flags);
    errdefer ring.deinit();

    self.* = .{
        .allocator = allocator,
        .ring = ring,
        .waker_needs_rearm = true,
    };
}

pub fn deinit(self: *Self) void {
    self.ring.deinit();
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = self;
    // wake_requested is already set by Loop.wake() before calling us.
    // Just do the futex wake syscall.
    _ = linux.futex_3arg(
        @ptrCast(&state.wake_requested.raw),
        .{ .cmd = .WAKE, .private = true },
        1, // wake 1 waiter
    );
}

fn rearmWaker(self: *Self, state: *LoopState) !void {
    if (!self.waker_needs_rearm) return;
    const sqe = try self.ring.get_sqe();
    // Prep FUTEX_WAIT: wait while wake_requested == 0
    prepFutexWait(sqe, &state.wake_requested.raw, 0);
    sqe.user_data = USER_DATA_WAKER;
    self.waker_needs_rearm = false;
}

fn drainWaker(self: *Self) void {
    // wake_requested is reset by Loop after poll returns.
    // Just mark that we need to rearm the FUTEX_WAIT.
    self.waker_needs_rearm = true;
}

fn prepFutexWait(sqe: *linux.io_uring_sqe, futex: *const u32, expected: u64) void {
    sqe.* = .{
        .opcode = .FUTEX_WAIT,
        .flags = 0,
        .ioprio = 0,
        .fd = @bitCast(linux.FUTEX2_FLAGS{ .size = .U32, .private = true }),
        .off = expected,
        .addr = @intFromPtr(futex),
        .len = 0,
        .rw_flags = 0,
        .user_data = 0,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = FUTEX_BITSET_MATCH_ANY,
        .resv = 0,
    };
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
/// Can be called for initial submission (state == .new) or resubmission after EINTR (state == .running).
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    const is_new = c.state == .new;
    if (is_new) {
        c.state = .running;
        state.active += 1;
    } else {
        std.debug.assert(c.state == .running);
    }

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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for connect", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_connect(data.handle, data.addr, data.addr_len);
            sqe.user_data = @intFromPtr(c);
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for accept", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for recvmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for sendmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for recvmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for sendmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for recvmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for sendmsg", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for poll_add", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            const poll_mask: u32 = switch (data.event) {
                .recv => linux.POLL.IN,
                .send => linux.POLL.OUT,
            };
            sqe.prep_poll_add(data.handle, poll_mask);
            sqe.user_data = @intFromPtr(c);
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for shutdown", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_shutdown(data.handle, @intFromEnum(data.how));
            sqe.user_data = @intFromPtr(c);
        },
        .net_close => {
            const data = c.cast(NetClose);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for close", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },

        .file_open => {
            const data = c.cast(FileOpen);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for file_open", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            const flags = linux.O{
                .ACCMODE = switch (data.flags.mode) {
                    .read_only => .RDONLY,
                    .write_only => .WRONLY,
                    .read_write => .RDWR,
                },
                .CLOEXEC = true,
            };
            sqe.prep_openat(data.dir, data.internal.path, flags, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .file_create => {
            const data = c.cast(FileCreate);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for file_create", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            const flags = linux.O{
                .ACCMODE = if (data.flags.read) .RDWR else .WRONLY,
                .CLOEXEC = true,
                .CREAT = true,
                .TRUNC = data.flags.truncate,
                .EXCL = data.flags.exclusive,
            };
            sqe.prep_openat(data.dir, data.internal.path, flags, data.flags.mode);
            sqe.user_data = @intFromPtr(c);
        },
        .file_close => {
            const data = c.cast(FileClose);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_close", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },
        .file_read => {
            const data = c.cast(FileRead);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_read", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_readv(data.handle, data.buffer.iovecs, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
        .file_write => {
            const data = c.cast(FileWrite);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_write", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_writev(data.handle, data.buffer.iovecs, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
        .file_sync => {
            const data = c.cast(FileSync);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_sync", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            const flags: u32 = if (data.flags.only_data) linux.IORING_FSYNC_DATASYNC else 0;
            sqe.prep_fsync(data.handle, flags);
            sqe.user_data = @intFromPtr(c);
        },
        .file_set_size => {
            const data = c.cast(FileSetSize);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_set_size", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_rw(.FTRUNCATE, data.handle, 0, 0, @intCast(data.length));
            sqe.user_data = @intFromPtr(c);
        },
        .file_set_permissions => unreachable, // Handled by thread pool
        .file_set_owner => unreachable, // Handled by thread pool
        .file_set_timestamps => unreachable, // Handled by thread pool
        .dir_create_dir => {
            const data = c.cast(DirCreateDir);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for dir_create_dir", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_mkdirat(@intCast(data.dir), data.internal.path.ptr, data.mode);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_rename => {
            const data = c.cast(DirRename);
            if (is_new) {
                data.internal.old_path = self.allocator.dupeZ(u8, data.old_path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
                data.internal.new_path = self.allocator.dupeZ(u8, data.new_path) catch {
                    self.allocator.free(data.internal.old_path);
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.old_path);
                self.allocator.free(data.internal.new_path);
                log.err("Failed to get io_uring SQE for dir_rename", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_renameat(@intCast(data.old_dir), data.internal.old_path.ptr, @intCast(data.new_dir), data.internal.new_path.ptr, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_delete_file => {
            const data = c.cast(DirDeleteFile);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for dir_delete_file", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_unlinkat(@intCast(data.dir), data.internal.path.ptr, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .dir_delete_dir => {
            const data = c.cast(DirDeleteDir);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for dir_delete_dir", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_unlinkat(@intCast(data.dir), data.internal.path.ptr, linux.AT.REMOVEDIR);
            sqe.user_data = @intFromPtr(c);
        },

        .file_size => {
            const data = c.cast(FileSize);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_size", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            // Use statx with empty pathname to get stats for the fd itself
            const mask = linux.STATX_SIZE;
            const flags = linux.AT.EMPTY_PATH;
            sqe.prep_statx(data.handle, "", flags, mask, &data.internal.statx);
            sqe.user_data = @intFromPtr(c);
        },

        .file_stat => {
            const data = c.cast(FileStat);
            const mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO |
                linux.STATX_SIZE | linux.STATX_ATIME | linux.STATX_MTIME |
                linux.STATX_CTIME;

            if (data.path) |user_path| {
                // Path provided - stat relative to handle
                if (is_new) {
                    data.internal.path = self.allocator.dupeZ(u8, user_path) catch {
                        c.setError(error.SystemResources);
                        state.markCompletedFromBackend(c);
                        return;
                    };
                }
                const sqe = self.getSqe(state) catch {
                    self.allocator.free(data.internal.path);
                    log.err("Failed to get io_uring SQE for file_stat", .{});
                    c.setError(error.Unexpected);
                    state.markCompletedFromBackend(c);
                    return;
                };
                sqe.prep_statx(@intCast(data.handle), data.internal.path.ptr, 0, mask, &data.internal.statx);
                sqe.user_data = @intFromPtr(c);
            } else {
                // No path - use AT_EMPTY_PATH to stat the fd itself
                const sqe = self.getSqe(state) catch {
                    log.err("Failed to get io_uring SQE for file_stat", .{});
                    c.setError(error.Unexpected);
                    state.markCompletedFromBackend(c);
                    return;
                };
                sqe.prep_statx(data.handle, "", linux.AT.EMPTY_PATH, mask, &data.internal.statx);
                sqe.user_data = @intFromPtr(c);
            }
        },

        .dir_open => {
            const data = c.cast(DirOpen);
            if (is_new) {
                data.internal.path = self.allocator.dupeZ(u8, data.path) catch {
                    c.setError(error.SystemResources);
                    state.markCompletedFromBackend(c);
                    return;
                };
            }
            const sqe = self.getSqe(state) catch {
                self.allocator.free(data.internal.path);
                log.err("Failed to get io_uring SQE for dir_open", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for dir_close", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
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
        .file_stream_poll => {
            const data = c.cast(FileStreamPoll);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_stream_poll", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            const poll_mask: u32 = switch (data.event) {
                .read => linux.POLL.IN,
                .write => linux.POLL.OUT,
            };
            sqe.prep_poll_add(data.handle, poll_mask);
            sqe.user_data = @intFromPtr(c);
        },
        .file_stream_read => {
            const data = c.cast(FileStreamRead);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_stream_read", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_readv(data.handle, data.buffer.iovecs, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .file_stream_write => {
            const data = c.cast(FileStreamWrite);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_stream_write", .{});
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            };
            sqe.prep_writev(data.handle, data.buffer.iovecs, 0);
            sqe.user_data = @intFromPtr(c);
        },
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    switch (target.state) {
        .new => {
            // UNREACHABLE: When cancel is added via loop.add() and target.state == .new,
            // loop.add() handles it directly and doesn't call backend.cancel().
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
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for cancel", .{});
                // Cancel SQE failed - do nothing, let target complete naturally
                return;
            };
            sqe.prep_cancel(@intFromPtr(target), 0);
            sqe.user_data = USER_DATA_CANCEL;
        },
        .completed, .dead => {
            // Target already completed (has result) or fully finished (callback called).
            // No CQEs will arrive. This shouldn't happen as loop.add()/loop.cancel() check state first.
            unreachable;
        },
    }
}

/// Get an SQE, flushing the queue with non-blocking poll if full
fn getSqe(self: *Self, state: *LoopState) !*linux.io_uring_sqe {
    return self.ring.get_sqe() catch |err| {
        if (err == error.SubmissionQueueFull) {
            // Queue full - flush with non-blocking poll to drain completions
            _ = try self.poll(state, .zero);
            // Retry after flush
            return self.ring.get_sqe();
        }
        return err;
    };
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    const linux_os = @import("../../os/linux.zig");

    try self.rearmWaker(state);

    // Flush SQ to get number of pending submissions
    const to_submit = self.ring.flush_sq();

    // Setup timeout for io_uring_enter2
    // If timeout is Duration.max (infinite), pass null ts so io_uring_enter2 waits forever
    var ts: linux.kernel_timespec = undefined;
    var arg: linux_os.io_uring_getevents_arg = .{
        .ts = if (timeout.ns == Duration.max.ns) 0 else blk: {
            ts = .{
                .sec = @intCast(timeout.ns / std.time.ns_per_s),
                .nsec = @intCast(timeout.ns % std.time.ns_per_s),
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
    var cqes: [256]linux.io_uring_cqe = undefined;
    const count = try self.ring.copy_cqes(&cqes, 0);

    if (count == 0) {
        return true; // Timed out
    }

    for (cqes[0..count]) |cqe| {
        // Handle internal operations with special user_data values
        if (cqe.user_data == USER_DATA_WAKER) {
            self.drainWaker();
            continue;
        }

        if (cqe.user_data == USER_DATA_CANCEL) {
            // Cancel SQE completion - just skip it
            continue;
        }

        // Extract completion pointer from user_data
        const completion = @as(*Completion, @ptrFromInt(@as(usize, @intCast(cqe.user_data))));

        // Skip if already completed (can happen with cancellations)
        // When a target is canceled, it recursively completes the cancel operation
        // So when we get the cancel's CQE, it's already completed
        // Similarly, when we get the target's CQE after the cancel already completed it
        if (completion.state == .completed or completion.state == .dead) {
            continue;
        }

        // Handle EINTR by resubmitting - operation was interrupted by a signal
        if (cqe.res == -@as(i32, @intFromEnum(linux.E.INTR))) {
            self.submit(state, completion);
            continue;
        }

        // Store the result in the completion
        self.storeResult(completion, cqe.res);

        // Mark as completed (also decrements inflight_io)
        state.markCompletedFromBackend(completion);
    }

    return false; // Did not timeout, woke up due to events
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
                c.setError(fs.errnoToFileOpenError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_open, res);
            }
        },

        .file_create => {
            const data = c.cast(FileCreate);
            self.allocator.free(data.internal.path);
            if (res < 0) {
                c.setError(fs.errnoToFileOpenError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_create, res);
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
                c.setError(fs.errnoToFileOpenError(@enumFromInt(-res)));
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
        .file_stream_poll => {
            if (res < 0) {
                c.setError(fs.errnoToFileReadError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_stream_poll, {});
            }
        },
        .file_stream_read => {
            if (res < 0) {
                c.setError(fs.errnoToFileReadError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_stream_read, @intCast(res));
            }
        },
        .file_stream_write => {
            if (res < 0) {
                c.setError(fs.errnoToFileWriteError(@enumFromInt(-res)));
            } else {
                c.setResult(.file_stream_write, @intCast(res));
            }
        },
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
        .size = statx.size,
        .mode = statx.mode,
        .kind = kind,
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
    return msg_flags;
}

fn sendFlagsToMsg(flags: net.SendFlags) u32 {
    var msg_flags: u32 = 0;
    if (flags.no_signal) msg_flags |= linux.MSG.NOSIGNAL;
    return msg_flags;
}
