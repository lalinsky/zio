const std = @import("std");
const linux = std.os.linux;
const posix_os = @import("../os/posix.zig");
const socket = @import("../os/posix/socket.zig");
const time = @import("../time.zig");
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

pub const NetHandle = socket.fd_t;

// Backend-specific completion data embedded in each Completion
// Stores msghdr structures that must remain valid for io_uring operations
pub const CompletionData = struct {
    msg_recv: linux.msghdr = undefined,
    msg_send: linux.msghdr_const = undefined,
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

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    // Initialize io_uring with 256 entries
    // This is a reasonable default - the kernel will round up to next power of 2

    var flags: u32 = 0;
    flags |= linux.IORING_SETUP_SINGLE_ISSUER;
    flags |= linux.IORING_SETUP_DEFER_TASKRUN;
    flags |= linux.IORING_SETUP_COOP_TASKRUN;

    var ring = try linux.IoUring.init(256, flags);
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

pub fn processSubmissions(
    self: *Self,
    state: *LoopState,
    submissions: *Queue(Completion),
) !void {
    // Process all submissions in the queue
    while (submissions.pop()) |c| {
        // Start the completion - this will either:
        // 1. Complete synchronously (socket/bind/listen)
        // 2. Submit to io_uring and return .running
        const result = try self.startCompletion(c);
        switch (result) {
            .completed => state.markCompleted(c),
            .running => state.markRunning(c),
        }
    }

    // Submit all queued SQEs to the kernel
    // io_uring batches all the operations we just prepared
    _ = try self.ring.submit();
}

pub fn processCancellations(
    self: *Self,
    state: *LoopState,
    cancels: *Queue(Completion),
) !void {
    while (cancels.pop()) |cancel_c| {
        const cancel_op = cancel_c.cast(Cancel);
        const target = cancel_op.cancel_c;

        switch (target.state) {
            .new => {
                // UNREACHABLE: When cancel is added via loop.add() and target.state == .new,
                // the cancel is not submitted to the queue (loop.add returns early).
                // Therefore processCancellations never sees this case.
                unreachable;
            },
            .adding => {
                // UNREACHABLE: When cancel is added via loop.add() and target.state == .adding,
                // the cancel is not submitted to the queue (loop.add returns early).
                // By the time processCancellations runs, processSubmissions has already
                // transitioned all .adding operations to .running or .completed.
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
                const sqe = try self.ring.cancel(
                    @intFromPtr(cancel_c),
                    @intFromPtr(target),
                    0,
                );
                _ = sqe;
                state.markRunning(cancel_c);
            },
            .completed => {
                // Target already completed before cancel was processed.
                // No CQEs will arrive. Complete cancel immediately.
                cancel_op.result = error.AlreadyCompleted;
                state.markCompleted(cancel_c);
            },
        }
    }

    // Submit the cancel operations
    _ = try self.ring.submit();
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
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

fn startCompletion(self: *Self, c: *Completion) !enum { completed, running } {
    switch (c.op) {
        // Synchronous operations (no io_uring support or always immediate)
        .net_open => {
            const data = c.cast(NetOpen);
            data.result = socket.socket(
                data.domain,
                data.socket_type,
                data.protocol,
                data.flags,
            );
            return .completed;
        },
        .net_bind => {
            const data = c.cast(NetBind);
            data.result = socket.bind(data.handle, data.addr, data.addr_len);
            return .completed;
        },
        .net_listen => {
            const data = c.cast(NetListen);
            data.result = socket.listen(data.handle, data.backlog);
            return .completed;
        },

        // Async operations through io_uring
        .net_connect => {
            const data = c.cast(NetConnect);
            _ = try self.ring.connect(
                @intFromPtr(c),
                data.handle,
                data.addr,
                data.addr_len,
            );
            return .running;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            _ = try self.ring.accept(
                @intFromPtr(c),
                data.handle,
                data.addr,
                data.addr_len,
                0, // flags
            );
            return .running;
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            // Store msghdr in completion internal data so it remains valid
            c.internal.msg_recv = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = try self.ring.recvmsg(
                @intFromPtr(c),
                data.handle,
                &c.internal.msg_recv,
                recvFlagsToMsg(data.flags),
            );
            return .running;
        },
        .net_send => {
            const data = c.cast(NetSend);
            // Store msghdr in completion internal data so it remains valid
            c.internal.msg_send = .{
                .name = null,
                .namelen = 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = try self.ring.sendmsg(
                @intFromPtr(c),
                data.handle,
                &c.internal.msg_send,
                sendFlagsToMsg(data.flags),
            );
            return .running;
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            // Store msghdr in completion internal data so it remains valid
            c.internal.msg_recv = .{
                .name = @ptrCast(data.addr),
                .namelen = if (data.addr_len) |len| len.* else 0,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = try self.ring.recvmsg(
                @intFromPtr(c),
                data.handle,
                &c.internal.msg_recv,
                recvFlagsToMsg(data.flags),
            );
            return .running;
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            // Store msghdr in completion internal data so it remains valid
            c.internal.msg_send = .{
                .name = @ptrCast(data.addr),
                .namelen = data.addr_len,
                .iov = data.buffers.ptr,
                .iovlen = data.buffers.len,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            _ = try self.ring.sendmsg(
                @intFromPtr(c),
                data.handle,
                &c.internal.msg_send,
                sendFlagsToMsg(data.flags),
            );
            return .running;
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            _ = try self.ring.shutdown(
                @intFromPtr(c),
                data.handle,
                @intFromEnum(data.how),
            );
            return .running;
        },
        .net_close => {
            const data = c.cast(NetClose);
            _ = try self.ring.close(
                @intFromPtr(c),
                data.handle,
            );
            return .running;
        },

        else => unreachable,
    }
}

fn storeResult(self: *Self, c: *Completion, res: i32) void {
    _ = self;

    // ECANCELED (125) is returned by io_uring when an operation is canceled
    const ECANCELED = 125;

    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToConnectError(-res);
                }
            } else {
                data.result = {};
            }
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToAcceptError(-res);
                }
            } else {
                data.result = @intCast(res);
            }
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToRecvError(-res);
                }
            } else {
                data.result = @intCast(res);
            }
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToSendError(-res);
                }
            } else {
                data.result = @intCast(res);
            }
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToRecvError(-res);
                }
            } else {
                data.result = @intCast(res);
                // Propagate the peer address length filled in by the kernel
                if (data.addr_len) |len_ptr| {
                    len_ptr.* = c.internal.msg_recv.namelen;
                }
            }
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = socket.errnoToSendError(-res);
                }
            } else {
                data.result = @intCast(res);
            }
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            if (res < 0) {
                if (-res == ECANCELED) {
                    data.result = error.Canceled;
                } else {
                    data.result = errnoToShutdownError(-res);
                }
            } else {
                data.result = {};
            }
        },
        .net_close => {
            const data = c.cast(NetClose);
            if (res < 0) {
                // Close errors are generally ignored, but we store them
                data.result = {};
            } else {
                data.result = {};
            }
        },
        // Cancel CQEs are always skipped in tick(), so cancel should never reach storeResult
        else => unreachable,
    }
}

fn errnoToShutdownError(err: i32) socket.ShutdownError {
    const errno_val: linux.E = @enumFromInt(err);
    return switch (errno_val) {
        .NOTCONN => error.NotConnected,
        .NOTSOCK => error.NotSocket,
        else => posix_os.unexpectedErrno(errno_val) catch error.Unexpected,
    };
}

fn recvFlagsToMsg(flags: socket.RecvFlags) u32 {
    var msg_flags: u32 = 0;
    if (flags.peek) msg_flags |= linux.MSG.PEEK;
    if (flags.waitall) msg_flags |= linux.MSG.WAITALL;
    return msg_flags;
}

fn sendFlagsToMsg(flags: socket.SendFlags) u32 {
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
