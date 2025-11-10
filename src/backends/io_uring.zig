const std = @import("std");
const linux = std.os.linux;
const posix_os = @import("../os/posix.zig");
const net = @import("../os/net.zig");
const fs = @import("../os/fs.zig");
const time = @import("../os/time.zig");
const common = @import("common.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const OperationType = @import("../completion.zig").OperationType;
const Queue = @import("../queue.zig").Queue;
const Cancel = @import("../completion.zig").Cancel;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetConnect = @import("../completion.zig").NetConnect;
const NetAccept = @import("../completion.zig").NetAccept;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetRecvFrom = @import("../completion.zig").NetRecvFrom;
const NetSendTo = @import("../completion.zig").NetSendTo;
const NetClose = @import("../completion.zig").NetClose;
const NetShutdown = @import("../completion.zig").NetShutdown;
const FileOpen = @import("../completion.zig").FileOpen;
const FileClose = @import("../completion.zig").FileClose;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;

pub const NetHandle = net.fd_t;

pub const supports_file_ops = true;

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

pub const FileOpenData = struct {
    path: [:0]const u8 = "",
};

const Self = @This();

const log = std.log.scoped(.zio_uring);

// DESIGN NOTES:
//
// io_uring is fundamentally different from epoll/kqueue/poll:
// - It's completion-based, not readiness-based
// - We submit the actual operations (connect, recv, send) to the kernel
// - The kernel completes them and posts results in the completion queue
// - No need for "try first, register if EAGAIN" pattern
// - No need for tracking hashmaps - we use CQE.user_data to store completion pointers
//
// Ubuntu 22.04 ships with kernel 5.15, which has these io_uring operations:
// ✅ IORING_OP_CONNECT (5.5)
// ✅ IORING_OP_ACCEPT (5.5)
// ✅ IORING_OP_RECV (5.6)
// ✅ IORING_OP_SEND (5.6)
// ✅ IORING_OP_RECVMSG (5.3)
// ✅ IORING_OP_SENDMSG (5.3)
// ✅ IORING_OP_SHUTDOWN (5.11)
// ✅ IORING_OP_CLOSE (5.6)
// ✅ IORING_OP_ASYNC_CANCEL (5.5)
// ❌ IORING_OP_SOCKET (5.19 - not available)
// ❌ IORING_OP_BIND (doesn't exist)
// ❌ IORING_OP_LISTEN (doesn't exist)
//
// For socket/bind/listen, we'll use direct syscalls since:
// 1. They're not available in io_uring on kernel 5.15
// 2. They always complete synchronously anyway
// 3. This matches the existing backend pattern

allocator: std.mem.Allocator,
ring: linux.IoUring,
waker: Waker,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16) !void {
    // Initialize io_uring with specified queue size
    // The kernel will round up to next power of 2

    var flags: u32 = 0;
    flags |= linux.IORING_SETUP_SINGLE_ISSUER;
    flags |= linux.IORING_SETUP_DEFER_TASKRUN;
    flags |= linux.IORING_SETUP_COOP_TASKRUN;

    var ring = try linux.IoUring.init(queue_size, flags);
    errdefer ring.deinit();

    self.* = .{
        .allocator = allocator,
        .ring = ring,
        .waker = undefined,
    };

    // Initialize async notification mechanism
    try self.waker.init(&self.ring);
}

pub fn deinit(self: *Self) void {
    self.waker.deinit();
    self.ring.deinit();
}

pub fn wake(self: *Self) void {
    self.waker.notify();
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.active += 1;

    switch (c.op) {
        .timer, .async, .work => unreachable, // Managed by the loop
        .cancel => unreachable, // Handled separately via cancel() method

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
            state.markCompleted(c);
        },
        .net_bind => {
            common.handleNetBind(c);
            state.markCompleted(c);
        },
        .net_listen => {
            common.handleNetListen(c);
            state.markCompleted(c);
        },

        // Async operations through io_uring
        .net_connect => {
            const data = c.cast(NetConnect);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for connect", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
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
                state.markCompleted(c);
                return;
            };
            sqe.prep_accept(data.handle, data.addr, data.addr_len, 0);
            sqe.user_data = @intFromPtr(c);
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            // Store msghdr in completion internal data so it remains valid
            data.internal.msg = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for recvmsg", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            sqe.prep_recvmsg(data.handle, &data.internal.msg, recvFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_send => {
            const data = c.cast(NetSend);
            // Store msghdr in completion internal data so it remains valid
            data.internal.msg = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for sendmsg", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            // Store msghdr in completion internal data so it remains valid
            data.internal.msg = .{
                .name = @ptrCast(data.addr),
                .namelen = if (data.addr_len) |len| len.* else 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for recvmsg", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            sqe.prep_recvmsg(data.handle, &data.internal.msg, recvFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            // Store msghdr in completion internal data so it remains valid
            data.internal.msg = .{
                .name = @ptrCast(data.addr),
                .namelen = data.addr_len,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for sendmsg", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            sqe.prep_sendmsg(data.handle, &data.internal.msg, sendFlagsToMsg(data.flags));
            sqe.user_data = @intFromPtr(c);
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for shutdown", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
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
                state.markCompleted(c);
                return;
            };
            sqe.prep_close(data.handle);
            sqe.user_data = @intFromPtr(c);
        },

        .file_open => {
            const data = c.cast(FileOpen);
            const path = self.allocator.dupeZ(u8, data.path) catch {
                c.setError(error.SystemResources);
                state.markCompleted(c);
                return;
            };
            const sqe = self.getSqe(state) catch {
                self.allocator.free(path);
                log.err("Failed to get io_uring SQE for file_open", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            const flags = linux.O{
                .APPEND = data.flags.append,
                .CREAT = data.flags.create,
                .TRUNC = data.flags.truncate,
                .EXCL = data.flags.exclusive,
            };
            sqe.prep_openat(data.dir, path, flags, data.mode);
            sqe.user_data = @intFromPtr(c);
            data.internal.path = path;
        },
        .file_close => {
            const data = c.cast(FileClose);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_close", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
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
                state.markCompleted(c);
                return;
            };
            sqe.prep_readv(data.handle, data.buffers, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
        .file_write => {
            const data = c.cast(FileWrite);
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for file_write", .{});
                c.setError(error.Unexpected);
                state.markCompleted(c);
                return;
            };
            sqe.prep_writev(data.handle, data.buffers, data.offset);
            sqe.user_data = @intFromPtr(c);
        },
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() before this is called.
pub fn cancel(self: *Self, state: *LoopState, c: *Completion) void {
    // Mark cancel operation as running
    c.state = .running;
    state.active += 1;

    const cancel_op = c.cast(Cancel);
    const target = cancel_op.cancel_c;

    switch (target.state) {
        .new => {
            // UNREACHABLE: When cancel is added via loop.add() and target.state == .new,
            // loop.add() handles it directly and doesn't call backend.cancel().
            unreachable;
        },
        .running => {
            // Target is executing in io_uring. Submit a cancel SQE.
            // This will generate TWO CQEs:
            // 1. Cancel CQE (user_data=cancel_c, res=0 or -ENOENT)
            // 2. Target CQE (user_data=target, res=-ECANCELED or success if cancel was too late)
            //
            // In tick(), we:
            // - Skip cancel CQEs (they never complete the cancel directly)
            // - Process target CQE and mark target complete
            // - markCompleted(target) recursively completes the cancel via target.canceled link
            const sqe = self.getSqe(state) catch {
                log.err("Failed to get io_uring SQE for cancel", .{});
                // Cancel SQE failed - do nothing, let target complete naturally
                // When target completes, markCompleted(target) will recursively complete cancel
                return;
            };
            sqe.prep_cancel(@intFromPtr(target), 0);
            sqe.user_data = @intFromPtr(c);
        },
        .completed => {
            // Target already completed before cancel was processed.
            // No CQEs will arrive. Complete cancel immediately.
            c.setError(error.AlreadyCompleted);
            state.markCompleted(c);
        },
    }
}

/// Get an SQE, flushing the queue with non-blocking poll if full
fn getSqe(self: *Self, state: *LoopState) !*linux.io_uring_sqe {
    return self.ring.get_sqe() catch |err| {
        if (err == error.SubmissionQueueFull) {
            // Queue full - flush with non-blocking poll to drain completions
            _ = try self.poll(state, 0);
            // Retry after flush
            return self.ring.get_sqe();
        }
        return err;
    };
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const linux_os = @import("../os/linux.zig");

    // Re-arm waker if needed (after drain() in previous tick)
    try self.waker.rearm();

    // Flush SQ to get number of pending submissions
    const to_submit = self.ring.flush_sq();

    // Setup timeout for io_uring_enter2 if finite
    var ts: linux.kernel_timespec = undefined;
    var arg: linux_os.io_uring_getevents_arg = .{};
    var flags: u32 = linux.IORING_ENTER_GETEVENTS;

    if (timeout_ms < std.math.maxInt(u64)) {
        ts = .{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((timeout_ms % 1000) * 1_000_000),
        };
        arg.ts = @intFromPtr(&ts);
        flags |= linux.IORING_ENTER_EXT_ARG;
    }

    // Submit and wait using io_uring_enter2 with timeout
    const submitted = linux_os.io_uring_enter2(
        self.ring.fd,
        to_submit,
        1, // min_complete = 1 to wait for at least one completion or timeout
        flags,
        if (flags & linux.IORING_ENTER_EXT_ARG != 0) &arg else null,
        @sizeOf(linux_os.io_uring_getevents_arg),
    ) catch |err| switch (err) {
        error.SignalInterrupt => return true, // Interrupted, treat as timeout
        else => return err,
    };
    _ = submitted;

    // Process all available completions
    var cqes: [256]linux.io_uring_cqe = undefined;
    const count = try self.ring.copy_cqes(&cqes, 0);

    if (count == 0) {
        return true; // Timed out
    }

    for (cqes[0..count]) |cqe| {
        // Skip internal wake-up operation (user_data == 0)
        if (cqe.user_data == 0) {
            // Wake-up POLL_ADD completion
            self.waker.drain();
            state.loop.processAsyncHandles();
            continue;
        }

        // Extract completion pointer from user_data
        const completion = @as(*Completion, @ptrFromInt(cqe.user_data));

        // Skip if already completed (can happen with cancellations)
        // When a target is canceled, it recursively completes the cancel operation
        // So when we get the cancel's CQE, it's already completed
        // Similarly, when we get the target's CQE after the cancel already completed it
        if (completion.state == .completed) {
            continue;
        }

        // For cancel operations: NEVER complete the cancel directly from tick()
        // The cancel should only be completed when the target completes (via markCompleted recursion)
        // So we always skip cancel CQEs - either the target already completed it, or will complete it
        if (completion.op == .cancel) {
            continue;
        }

        // Store the result in the completion
        self.storeResult(completion, cqe.res);

        // Mark as completed, which invokes the callback
        state.markCompleted(completion);
    }

    return false; // Did not timeout, woke up due to events
}

fn storeResult(self: *Self, c: *Completion, res: i32) void {
    // ECANCELED (125) is returned by io_uring when an operation is canceled
    const ECANCELED = 125;

    switch (c.op) {
        .timer, .async, .work, .cancel => unreachable,
        .net_open => unreachable,
        .net_bind => unreachable,
        .net_listen => unreachable,

        .net_connect => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToConnectError(-res));
                }
            } else {
                c.setResult(.net_connect, {});
            }
        },
        .net_accept => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToAcceptError(-res));
                }
            } else {
                c.setResult(.net_accept, @as(net.fd_t, @intCast(res)));
            }
        },
        .net_recv => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToRecvError(-res));
                }
            } else {
                c.setResult(.net_recv, @as(usize, @intCast(res)));
            }
        },
        .net_send => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToSendError(-res));
                }
            } else {
                c.setResult(.net_send, @as(usize, @intCast(res)));
            }
        },
        .net_recvfrom => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToRecvError(-res));
                }
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
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(net.errnoToSendError(-res));
                }
            } else {
                c.setResult(.net_sendto, @as(usize, @intCast(res)));
            }
        },
        .net_shutdown => {
            if (res < 0) {
                if (-res == ECANCELED) {
                    c.setError(error.Canceled);
                } else {
                    c.setError(errnoToShutdownError(-res));
                }
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
    }
}

fn errnoToShutdownError(err: i32) net.ShutdownError {
    const errno_val: linux.E = @enumFromInt(err);
    return switch (errno_val) {
        .NOTCONN => error.NotConnected,
        .NOTSOCK => error.NotSocket,
        else => posix_os.unexpectedErrno(errno_val) catch error.Unexpected,
    };
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

// Async notification mechanism using eventfd with POLL_ADD
const Waker = struct {
    const linux_os = @import("../os/linux.zig");

    ring: *linux.IoUring,
    eventfd: i32,
    needs_rearm: bool,

    fn init(self: *Waker, ring: *linux.IoUring) !void {
        // Create an eventfd for wake-up notifications
        const efd = try posix_os.eventfd(0, posix_os.EFD.CLOEXEC | posix_os.EFD.NONBLOCK);
        errdefer _ = linux.close(efd);

        self.* = .{
            .ring = ring,
            .eventfd = efd,
            .needs_rearm = true, // Arm on first tick
        };
    }

    fn deinit(self: *Waker) void {
        _ = linux.close(self.eventfd);
    }

    fn notify(self: *Waker) void {
        // Write to eventfd to wake up the POLL operation
        posix_os.eventfd_write(self.eventfd, 1) catch {};
    }

    fn drain(self: *Waker) void {
        // Read and clear the eventfd counter
        _ = posix_os.eventfd_read(self.eventfd) catch {};

        // Mark that we need to re-arm the POLL_ADD for next wake-up
        // This will be done in tick() before io_uring_enter2
        self.needs_rearm = true;
    }

    fn rearm(self: *Waker) !void {
        if (!self.needs_rearm) return;

        const sqe = try self.ring.get_sqe();
        sqe.prep_poll_add(self.eventfd, linux.POLL.IN);
        sqe.user_data = 0; // Special marker for wake-up events

        self.needs_rearm = false;
    }
};
