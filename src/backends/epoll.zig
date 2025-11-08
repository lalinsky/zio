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

const log = std.log.scoped(.zio_epoll);

allocator: std.mem.Allocator,
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
epoll_fd: i32 = -1,
async_impl: ?AsyncImpl = null,

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    const epoll_fd: i32 = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return posix.unexpectedErrno(err),
    };
    errdefer _ = std.os.linux.close(epoll_fd);

    self.* = .{
        .allocator = allocator,
        .epoll_fd = epoll_fd,
    };

    // Initialize AsyncImpl
    var async_impl: AsyncImpl = undefined;
    try async_impl.init(epoll_fd);
    self.async_impl = async_impl;
}

pub fn deinit(self: *Self) void {
    if (self.async_impl) |*impl| {
        impl.deinit();
    }
    self.poll_queue.deinit(self.allocator);
    if (self.epoll_fd != -1) {
        _ = std.os.linux.close(self.epoll_fd);
    }
}

pub fn wake(self: *Self) void {
    if (self.async_impl) |*impl| {
        impl.notify();
    }
}

fn getEvents(op: OperationType) u32 {
    return switch (op) {
        .net_connect => std.os.linux.EPOLL.OUT,
        .net_accept => std.os.linux.EPOLL.IN,
        .net_recv => std.os.linux.EPOLL.IN,
        .net_send => std.os.linux.EPOLL.OUT,
        .net_recvfrom => std.os.linux.EPOLL.IN,
        .net_sendto => std.os.linux.EPOLL.OUT,
        else => unreachable,
    };
}

fn getPollType(op: OperationType) PollEntryType {
    return switch (op) {
        .net_accept => .accept,
        .net_connect => .connect,
        .net_recv => .send_or_recv,
        .net_send => .send_or_recv,
        .net_recvfrom => .send_or_recv,
        .net_sendto => .send_or_recv,
        else => unreachable,
    };
}

/// Add a completion to the poll queue, merging with existing fd if present
fn addToPollQueue(self: *Self, fd: NetHandle, completion: *Completion) !void {
    completion.prev = null;
    completion.next = null;

    const gop = try self.poll_queue.getOrPut(self.allocator, fd);
    errdefer if (!gop.found_existing) self.poll_queue.removeByPtr(gop.key_ptr);

    var entry = gop.value_ptr;
    const op_events = getEvents(completion.op);

    if (!gop.found_existing) {
        var event = std.os.linux.epoll_event{
            .data = .{ .fd = fd },
            .events = op_events,
        };
        const rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, &event);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
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
            else => |err| return posix.unexpectedErrno(err),
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
        switch (posix.errno(del_rc)) {
            .SUCCESS, .NOENT => {
                // SUCCESS: successfully removed
                // NOENT: fd was not registered (already removed or never added) - safe to proceed
            },
            else => |err| return posix.unexpectedErrno(err),
        }
        const was_removed = self.poll_queue.remove(fd);
        std.debug.assert(was_removed);
        return;
    }

    // Recalculate events from remaining completions
    var new_events: u32 = 0;
    var iter: ?*Completion = entry.completions.head;
    while (iter) |c| : (iter = c.next) {
        new_events |= getEvents(c.op);
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
            else => |err| return posix.unexpectedErrno(err),
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
}

pub fn processCancellations(self: *Self, state: *LoopState, cancels: *Queue(Completion)) !void {
    while (cancels.pop()) |completion| {
        if (completion.state == .completed) continue;
        const cancel = completion.cast(Cancel);

        const fd = getHandle(cancel.cancel_c);
        try self.removeFromPollQueue(fd, cancel.cancel_c);

        cancel.result = {};
        state.markCompleted(cancel.cancel_c);
    }
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);

    // Check if we have any fds to monitor (network I/O or async_impl)
    const has_fds = self.poll_queue.count() > 0 or self.async_impl != null;
    if (!has_fds) {
        if (timeout > 0) {
            time.sleep(timeout);
        }
        return true; // Slept for the full timeout
    }

    var events: [64]std.os.linux.epoll_event = undefined;
    const rc = std.os.linux.epoll_wait(self.epoll_fd, &events, events.len, timeout);
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return posix.unexpectedErrno(err),
    };

    if (n == 0) {
        return true; // Timed out
    }

    for (events[0..n]) |event| {
        const fd = event.data.fd;

        // Check if this is the async wakeup fd
        if (self.async_impl) |*impl| {
            if (fd == impl.eventfd) {
                state.loop.processAsyncHandles();
                continue;
            }
        }

        const entry = self.poll_queue.get(fd) orelse continue;

        var iter: ?*Completion = entry.completions.head;
        while (iter) |completion| {
            iter = completion.next;
            switch (checkCompletion(completion, &event)) {
                .completed => {
                    try self.removeFromPollQueue(fd, completion);
                    state.markCompleted(completion);
                },
                .requeue => {
                    // Spurious wakeup - keep in poll queue
                },
            }
        }
    }

    return false; // Did not timeout, woke up due to events
}

pub fn startCompletion(self: *Self, c: *Completion) !enum { completed, running } {
    switch (c.op) {
        .timer, .async, .work => unreachable, // Manged by the loop
        .cancel => return .running, // Cancel was marked by loop and waits until the target completes

        // Synchronous operations - complete immediately
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
        .net_close => {
            const data = c.cast(NetClose);
            data.result = socket.close(data.handle);
            return .completed;
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            data.result = socket.shutdown(data.handle, data.how);
            return .completed;
        },

        // Potentially async operations - try first, register if WouldBlock
        .net_connect => {
            const data = c.cast(NetConnect);
            data.result = socket.connect(data.handle, data.addr, data.addr_len);
            if (data.result) |_| {
                // Connected immediately (e.g., localhost)
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Register for POLLOUT to detect when connection completes
                    try self.addToPollQueue(data.handle, c);
                    return .running;
                },
                else => return .completed, // Error, complete immediately
            }
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            try self.addToPollQueue(data.handle, c);
            return .running;
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            try self.addToPollQueue(data.handle, c);
            return .running;
        },
        .net_send => {
            const data = c.cast(NetSend);
            try self.addToPollQueue(data.handle, c);
            return .running;
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            try self.addToPollQueue(data.handle, c);
            return .running;
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            try self.addToPollQueue(data.handle, c);
            return .running;
        },
    }
}

const CheckResult = enum { completed, requeue };

fn handleEpollError(event: *const std.os.linux.epoll_event, comptime errnoToError: fn (i32) anyerror) ?anyerror {
    const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = socket.getSockError(event.data.fd) catch return error.Unexpected;
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

pub fn checkCompletion(c: *Completion, event: *const std.os.linux.epoll_event) CheckResult {
    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);
            if (handleEpollError(event, socket.errnoToConnectError)) |err| {
                data.result = @errorCast(err);
            } else {
                data.result = {};
            }
            return .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (handleEpollError(event, socket.errnoToAcceptError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (handleEpollError(event, socket.errnoToRecvError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.recv(data.handle, data.buffers, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (handleEpollError(event, socket.errnoToSendError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.send(data.handle, data.buffers, data.flags);
            return checkSpuriousWakeup(data.result);
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            if (handleEpollError(event, socket.errnoToRecvError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.recvfrom(data.handle, data.buffers, data.flags, data.addr, data.addr_len);
            return checkSpuriousWakeup(data.result);
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            if (handleEpollError(event, socket.errnoToSendError)) |err| {
                data.result = @errorCast(err);
                return .completed;
            }
            data.result = socket.sendto(data.handle, data.buffers, data.flags, data.addr, data.addr_len);
            return checkSpuriousWakeup(data.result);
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}

/// Async notification implementation using eventfd
pub const AsyncImpl = struct {
    const linux = @import("../os/linux.zig");

    eventfd: i32 = -1,
    epoll_fd: i32,

    pub fn init(self: *AsyncImpl, epoll_fd: i32) !void {
        const efd = try linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        errdefer _ = std.os.linux.close(efd);

        // Register eventfd with epoll
        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = efd },
        };
        const rc = std.os.linux.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, efd, &event);
        if (posix.errno(rc) != .SUCCESS) {
            return posix.unexpectedErrno(posix.errno(rc));
        }

        self.* = .{
            .eventfd = efd,
            .epoll_fd = epoll_fd,
        };
    }

    pub fn deinit(self: *AsyncImpl) void {
        if (self.eventfd != -1) {
            // Remove from epoll
            _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, self.eventfd, null);
            _ = std.os.linux.close(self.eventfd);
            self.eventfd = -1;
        }
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *AsyncImpl) void {
        linux.eventfd_write(self.eventfd, 1) catch |err| {
            log.err("Failed to write to eventfd: {}", .{err});
        };
    }

    /// Drain the eventfd counter (called by event loop when EPOLLIN is ready)
    pub fn drain(self: *AsyncImpl) void {
        _ = linux.eventfd_read(self.eventfd) catch |err| {
            log.err("Failed to read from eventfd: {}", .{err});
        };
    }
};
