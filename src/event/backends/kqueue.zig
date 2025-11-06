const std = @import("std");
const posix = @import("../os/posix.zig");
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

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = socket.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const Self = @This();

const log = std.log.scoped(.zio_kqueue);

const c = std.c;

allocator: std.mem.Allocator,
kqueue_fd: i32 = -1,
async_impl: ?AsyncImpl = null,

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    const kq = c.kqueue();
    const kqueue_fd: i32 = switch (posix.errno(kq)) {
        .SUCCESS => @intCast(kq),
        else => |err| return posix.unexpectedErrno(err),
    };
    errdefer _ = c.close(kqueue_fd);

    self.* = .{
        .allocator = allocator,
        .kqueue_fd = kqueue_fd,
    };

    // Initialize AsyncImpl
    var async_impl: AsyncImpl = undefined;
    try async_impl.init(kqueue_fd);
    self.async_impl = async_impl;
}

pub fn deinit(self: *Self) void {
    if (self.async_impl) |*impl| {
        impl.deinit();
    }
    if (self.kqueue_fd != -1) {
        _ = c.close(self.kqueue_fd);
    }
}

pub fn wake(self: *Self) void {
    if (self.async_impl) |*impl| {
        impl.notify();
    }
}

fn getFilter(op: OperationType) i16 {
    return switch (op) {
        .net_connect => c.EVFILT.WRITE,
        .net_accept => c.EVFILT.READ,
        .net_recv => c.EVFILT.READ,
        .net_send => c.EVFILT.WRITE,
        .net_recvfrom => c.EVFILT.READ,
        .net_sendto => c.EVFILT.WRITE,
        else => unreachable,
    };
}

/// Register a completion with kqueue
fn registerCompletion(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const filter = getFilter(completion.op);
    var changes: [1]c.Kevent = undefined;
    changes[0] = .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    };
    const rc = c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Unregister a completion from kqueue
fn unregisterCompletion(self: *Self, fd: NetHandle, completion: *Completion) void {
    const filter = getFilter(completion.op);
    var changes: [1]c.Kevent = undefined;
    changes[0] = .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    };
    // Ignore errors - the fd might already be closed or the event might not exist
    _ = c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
}

fn getHandle(completion: *Completion) NetHandle {
    return switch (completion.op) {
        .net_accept => completion.cast(NetAccept).handle,
        .net_connect => completion.cast(NetConnect).handle,
        .net_recv => completion.cast(NetRecv).handle,
        .net_send => completion.cast(NetSend).handle,
        .net_recvfrom => completion.cast(NetRecvFrom).handle,
        .net_sendto => completion.cast(NetSendTo).handle,
        else => unreachable,
    };
}

fn processSubmissions(self: *Self, state: *LoopState) !void {
    var submissions = state.submissions;
    state.submissions = .{};

    var operations: Queue(Completion) = .{};
    var cancels: Queue(Completion) = .{};

    // First go over cancelations and mark operations as canceled
    while (submissions.pop()) |completion| {
        if (completion.op == .cancel) {
            var data = completion.cast(Cancel);
            if (data.cancel_c.canceled == null) {
                data.cancel_c.canceled = completion;
                cancels.push(completion);
            } else {
                data.result = error.AlreadyCanceled;
                state.markCompleted(completion);
            }
        } else {
            operations.push(completion);
        }
    }

    // Now start normal operations, ignoring the canceled ones
    while (operations.pop()) |completion| {
        if (completion.state == .completed) continue;
        if (completion.canceled != null) {
            state.markCompleted(completion);
        } else {
            switch (try self.startCompletion(completion)) {
                .completed => state.markCompleted(completion),
                .running => state.markRunning(completion),
            }
        }
    }

    // And now go over remaining cancelations and unregister the operations from kqueue
    while (cancels.pop()) |completion| {
        if (completion.state == .completed) continue;
        const cancel = completion.cast(Cancel);
        const fd = getHandle(cancel.cancel_c);
        self.unregisterCompletion(fd, cancel.cancel_c);

        // Set cancel result to success
        // The canceled operation's result will be error.Canceled via getResult()
        cancel.result = {};

        // Mark the canceled operation as completed, which will recursively mark the cancel as completed
        state.markCompleted(cancel.cancel_c);
    }
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !void {
    // Process incoming submissions, handle cancelations
    try self.processSubmissions(state);

    var events: [64]c.Kevent = undefined;
    var timeout_spec: c.timespec = undefined;
    const timeout_ptr: ?*const c.timespec = if (timeout_ms < std.math.maxInt(u64)) blk: {
        timeout_spec = .{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((timeout_ms % 1000) * 1_000_000),
        };
        break :blk &timeout_spec;
    } else null;

    const rc = c.kevent(self.kqueue_fd, &.{}, 0, &events, events.len, timeout_ptr);
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return posix.unexpectedErrno(err),
    };

    for (events[0..n]) |event| {
        const fd: NetHandle = @intCast(event.ident);

        // Check if this is the async wakeup fd
        if (self.async_impl) |*impl| {
            if (fd == impl.read_fd) {
                state.loop.processAsyncHandles();
                impl.drain();
                continue;
            }
        }

        // Get completion pointer from udata
        if (event.udata == 0) continue; // Shouldn't happen, but be defensive

        const completion: *Completion = @ptrFromInt(event.udata);

        switch (checkCompletion(completion, &event)) {
            .completed => {
                self.unregisterCompletion(fd, completion);
                state.markCompleted(completion);
            },
            .requeue => {
                // Spurious wakeup - kevent stays registered
            },
        }
    }
}

pub fn startCompletion(self: *Self, comp: *Completion) !enum { completed, running } {
    switch (comp.op) {
        .timer => unreachable, // Timers are handled elsewhere in the loop
        .async => unreachable, // Async handles are managed separately
        .cancel => {
            const data = comp.cast(Cancel);
            data.cancel_c.canceled = comp;
            return .running; // Cancel waits until target is actually cancelled
        },

        // Synchronous operations - complete immediately
        .net_open => {
            const data = comp.cast(NetOpen);
            data.result = socket.socket(
                data.domain,
                data.socket_type,
                data.protocol,
                data.flags,
            );
            return .completed;
        },
        .net_bind => {
            const data = comp.cast(NetBind);
            data.result = socket.bind(data.handle, data.addr, data.addr_len);
            return .completed;
        },
        .net_listen => {
            const data = comp.cast(NetListen);
            data.result = socket.listen(data.handle, data.backlog);
            return .completed;
        },
        .net_close => {
            const data = comp.cast(NetClose);
            data.result = socket.close(data.handle);
            return .completed;
        },
        .net_shutdown => {
            const data = comp.cast(NetShutdown);
            data.result = socket.shutdown(data.handle, data.how);
            return .completed;
        },

        // Potentially async operations - try first, register if WouldBlock
        .net_connect => {
            const data = comp.cast(NetConnect);
            data.result = socket.connect(data.handle, data.addr, data.addr_len);
            if (data.result) |_| {
                // Connected immediately (e.g., localhost)
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Register for EVFILT_WRITE to detect when connection completes
                    try self.registerCompletion(data.handle, comp);
                    return .running;
                },
                else => return .completed, // Error, complete immediately
            }
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            try self.registerCompletion(data.handle, comp);
            return .running;
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            try self.registerCompletion(data.handle, comp);
            return .running;
        },
        .net_send => {
            const data = comp.cast(NetSend);
            try self.registerCompletion(data.handle, comp);
            return .running;
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            try self.registerCompletion(data.handle, comp);
            return .running;
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            try self.registerCompletion(data.handle, comp);
            return .running;
        },
    }
}

const CheckResult = enum { completed, requeue };

fn handleKqueueError(event: *const c.Kevent, comptime errnoToError: fn (i32) anyerror) ?anyerror {
    const has_error = (event.flags & c.EV.ERROR) != 0;
    const has_eof = (event.flags & c.EV.EOF) != 0;
    if (!has_error and !has_eof) return null;

    if (has_error) {
        // event.data contains the errno when EV_ERROR is set
        if (event.data != 0) {
            return errnoToError(@intCast(event.data));
        }
    }

    const sock_err = socket.getSockError(@intCast(event.ident)) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
    return errnoToError(sock_err);
}

fn checkSpuriousWakeup(result: anytype) CheckResult {
    if (result) |_| {
        return .completed;
    } else |err| switch (err) {
        error.WouldBlock => return .requeue,
        else => return .completed,
    }
}

pub fn checkCompletion(comp: *Completion, event: *const c.Kevent) CheckResult {
    switch (comp.op) {
        .net_connect => {
            const data = comp.cast(NetConnect);
            if (handleKqueueError(event, socket.errnoToConnectError)) |err| {
                data.result = @errorCast(err);
            } else {
                data.result = {};
            }
            return .completed;
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            if (handleKqueueError(event, socket.errnoToAcceptError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            if (handleKqueueError(event, socket.errnoToRecvError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.recv(data.handle, data.buffers, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_send => {
            const data = comp.cast(NetSend);
            if (handleKqueueError(event, socket.errnoToSendError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.send(data.handle, data.buffers, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            if (handleKqueueError(event, socket.errnoToRecvError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.recvfrom(data.handle, data.buffers, data.flags, data.addr, data.addr_len);
            return checkSpuriousWakeup(data.result);
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            if (handleKqueueError(event, socket.errnoToSendError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.sendto(data.handle, data.buffers, data.flags, data.addr, data.addr_len);
            return checkSpuriousWakeup(data.result);
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{comp.op});
        },
    }
}

/// Async notification implementation using pipe
pub const AsyncImpl = struct {
    read_fd: socket.fd_t = undefined,
    write_fd: socket.fd_t = undefined,
    kqueue_fd: i32,

    pub fn init(self: *AsyncImpl, kqueue_fd: i32) !void {
        // Use pipe for async notifications
        const pipefd = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
        errdefer {
            std.posix.close(pipefd[0]);
            std.posix.close(pipefd[1]);
        }

        // Register read end with kqueue
        var changes: [1]c.Kevent = undefined;
        changes[0] = .{
            .ident = @intCast(pipefd[0]),
            .filter = c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        const rc = c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
        if (posix.errno(rc) != .SUCCESS) {
            return posix.unexpectedErrno(posix.errno(rc));
        }

        self.* = .{
            .read_fd = pipefd[0],
            .write_fd = pipefd[1],
            .kqueue_fd = kqueue_fd,
        };
    }

    pub fn deinit(self: *AsyncImpl) void {
        // Remove from kqueue
        var changes: [1]c.Kevent = undefined;
        changes[0] = .{
            .ident = @intCast(self.read_fd),
            .filter = c.EVFILT.READ,
            .flags = c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        _ = c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);

        std.posix.close(self.read_fd);
        std.posix.close(self.write_fd);
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *AsyncImpl) void {
        const byte: [1]u8 = .{1};
        _ = std.posix.write(self.write_fd, &byte) catch |err| {
            log.err("Failed to write to wakeup pipe: {}", .{err});
        };
    }

    /// Drain the pipe (called by event loop when EVFILT_READ is ready)
    pub fn drain(self: *AsyncImpl) void {
        var buf: [64]u8 = undefined;
        _ = std.posix.read(self.read_fd, &buf) catch {};
    }
};
