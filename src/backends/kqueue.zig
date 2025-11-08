const std = @import("std");
const builtin = @import("builtin");
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

// These are not defined in std.c for FreeBSD/NetBSD,
// but the values are the same across all systems using kqueue
const EV_ERROR: u16 = 0x4000;
const EV_EOF: u16 = 0x8000;

// std.c has wrong numbers for EVFILT_USER and NOTE_TRIGGER on NetBSD
// https://github.com/ziglang/zig/pull/25853
const EVFILT_USER: i16 = switch (builtin.target.os.tag) {
    .netbsd => 8,
    else => std.c.EVFILT.USER,
};
const NOTE_TRIGGER: u32 = 0x01000000;

allocator: std.mem.Allocator,
kqueue_fd: i32 = -1,
async_impl: ?AsyncImpl = null,
change_buffer: std.ArrayListUnmanaged(c.Kevent) = .{},

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
        .async_impl = null,
        .change_buffer = .{},
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
    self.change_buffer.deinit(self.allocator);
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

/// Queue a kevent change to register a completion
fn queueRegister(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const filter = getFilter(completion.op);
    try self.change_buffer.append(self.allocator, .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    });
}

/// Queue a kevent change to unregister a completion
/// NOTE: Only used for cancellations; normal completions use EV_ONESHOT which auto-removes events
fn queueUnregister(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const filter = getFilter(completion.op);
    try self.change_buffer.append(self.allocator, .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    });
}

/// Submit all queued kevent changes in batches
fn submitChanges(self: *Self) !void {
    if (self.change_buffer.items.len == 0) return;

    var offset: usize = 0;
    while (offset < self.change_buffer.items.len) {
        const batch_size = @min(self.change_buffer.items.len - offset, 64);
        const batch = self.change_buffer.items[offset..][0..batch_size];

        const rc = c.kevent(self.kqueue_fd, batch.ptr, @intCast(batch_size), &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }

        offset += batch_size;
    }

    self.change_buffer.clearRetainingCapacity();
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

pub fn processSubmissions(self: *Self, state: *LoopState, submissions: *Queue(Completion)) !void {
    while (submissions.pop()) |completion| {
        switch (try self.startCompletion(completion)) {
            .completed => state.markCompleted(completion),
            .running => state.markRunning(completion),
        }
    }

    // Submit all queued changes in batches (non-blocking)
    try self.submitChanges();
}

pub fn processCancellations(self: *Self, state: *LoopState, cancels: *Queue(Completion)) !void {
    while (cancels.pop()) |completion| {
        if (completion.state == .completed) continue;
        const cancel = completion.cast(Cancel);

        const fd = getHandle(cancel.cancel_c);
        try self.queueUnregister(fd, cancel.cancel_c);

        cancel.result = {};
        state.markCompleted(cancel.cancel_c);
    }

    // Submit all queued changes in batches (non-blocking)
    try self.submitChanges();
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
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

    if (n == 0) {
        return true; // Timed out
    }

    for (events[0..n]) |event| {
        // Check if this is the async wakeup user event
        if (self.async_impl) |*impl| {
            if (event.filter == EVFILT_USER and event.ident == impl.ident) {
                state.loop.processAsyncHandles();
                impl.drain();
                continue;
            }
        }

        // Get completion pointer from udata
        if (event.udata == 0) continue; // Shouldn't happen, but be defensive

        const completion: *Completion = @ptrFromInt(event.udata);
        const fd: NetHandle = @intCast(event.ident);

        switch (checkCompletion(completion, &event)) {
            .completed => {
                // EV_ONESHOT automatically removes the event
                state.markCompleted(completion);
            },
            .requeue => {
                // Spurious wakeup - EV_ONESHOT already consumed the event, re-register
                try self.queueRegister(fd, completion);
            },
        }
    }

    // Submit any unregister operations that were queued while processing events
    try self.submitChanges();

    return false; // Did not timeout, woke up due to events
}

pub fn startCompletion(self: *Self, comp: *Completion) !enum { completed, running } {
    switch (comp.op) {
        .timer, .async, .work => unreachable, // Manged by the loop
        .cancel => return .running, // Cancel was marked by loop and waits until the target completes

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
                    // Queue for EVFILT_WRITE to detect when connection completes
                    try self.queueRegister(data.handle, comp);
                    return .running;
                },
                else => return .completed, // Error, complete immediately
            }
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            try self.queueRegister(data.handle, comp);
            return .running;
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            try self.queueRegister(data.handle, comp);
            return .running;
        },
        .net_send => {
            const data = comp.cast(NetSend);
            try self.queueRegister(data.handle, comp);
            return .running;
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            try self.queueRegister(data.handle, comp);
            return .running;
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            try self.queueRegister(data.handle, comp);
            return .running;
        },
    }
}

const CheckResult = enum { completed, requeue };

fn handleKqueueError(event: *const c.Kevent, comptime errnoToError: fn (i32) anyerror) ?anyerror {
    const has_error = (event.flags & EV_ERROR) != 0;
    const has_eof = (event.flags & EV_EOF) != 0;
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

/// Async notification implementation using EVFILT_USER
pub const AsyncImpl = struct {
    kqueue_fd: i32,
    ident: usize,

    pub fn init(self: *AsyncImpl, kqueue_fd: i32) !void {
        var changes: [1]c.Kevent = .{.{
            .ident = @intFromPtr(self),
            .filter = EVFILT_USER,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to add user kevent: {}", .{err});
                return posix.unexpectedErrno(err);
            },
        }

        self.* = .{
            .kqueue_fd = kqueue_fd,
            .ident = changes[0].ident,
        };
    }

    pub fn deinit(self: *AsyncImpl) void {
        var changes: [1]c.Kevent = .{.{
            .ident = self.ident,
            .filter = EVFILT_USER,
            .flags = c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to remove user kevent: {}", .{err});
            },
        }
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *AsyncImpl) void {
        var changes: [1]c.Kevent = .{.{
            .ident = self.ident,
            .filter = EVFILT_USER,
            .flags = 0,
            .fflags = NOTE_TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        const rc = c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to trigger user kevent: {}", .{err});
                @panic("TODO: handle error");
            },
        }
    }

    /// No draining needed for EVFILT_USER
    pub fn drain(self: *AsyncImpl) void {
        _ = self;
    }
};
