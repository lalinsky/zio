const std = @import("std");
const posix = @import("../os/posix.zig");
const net = @import("../os/net.zig");
const time = @import("../os/time.zig");
const common = @import("common.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
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

pub const NetHandle = net.fd_t;

pub const supports_file_ops = false;

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

const log = std.log.scoped(.zio_epoll);

allocator: std.mem.Allocator,
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
epoll_fd: i32 = -1,
waker: Waker,
events: []std.os.linux.epoll_event,
queue_size: u16,
pending_changes: usize = 0,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16) !void {
    const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
    const epoll_fd: i32 = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| return posix.unexpectedErrno(err),
    };
    errdefer _ = std.os.linux.close(epoll_fd);

    self.* = .{
        .allocator = allocator,
        .epoll_fd = epoll_fd,
        .waker = undefined,
        .events = undefined,
        .queue_size = queue_size,
    };

    self.events = try allocator.alloc(std.os.linux.epoll_event, queue_size);
    errdefer allocator.free(self.events);

    try self.poll_queue.ensureTotalCapacity(self.allocator, queue_size);
    errdefer self.poll_queue.deinit(self.allocator);

    // Initialize Waker
    try self.waker.init(epoll_fd);
}

pub fn deinit(self: *Self) void {
    self.waker.deinit();
    self.poll_queue.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.epoll_fd != -1) {
        _ = std.os.linux.close(self.epoll_fd);
    }
}

pub fn wake(self: *Self) void {
    self.waker.notify();
}

fn getEvents(op: Op) u32 {
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

fn getPollType(op: Op) PollEntryType {
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

/// Add a completion to the poll queue, merging with existing fd if present.
/// If queuing fails, completes the completion with error.Unexpected.
fn addToPollQueue(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
    // If at capacity, flush with non-blocking poll to drain completions
    if (self.pending_changes >= self.queue_size) {
        _ = self.poll(state, 0) catch {
            log.err("Failed to do no-wait poll during addToPollQueue", .{});
        };
    }
    self.pending_changes += 1;

    completion.prev = null;
    completion.next = null;

    const gop = self.poll_queue.getOrPut(self.allocator, fd) catch {
        log.err("Failed to add to poll queue: OutOfMemory", .{});
        completion.setError(error.Unexpected);
        state.markCompleted(completion);
        return;
    };

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
            else => |err| {
                log.err("Failed to epoll_ctl(CTL_ADD): {}", .{err});
                _ = self.poll_queue.remove(fd);
                completion.setError(error.Unexpected);
                state.markCompleted(completion);
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
                state.markCompleted(completion);
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

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.active += 1;

    switch (c.op) {
        .timer, .async, .work => unreachable, // Managed by the loop
        .cancel => unreachable, // Handled separately via cancel() method

        // Synchronous operations - complete immediately
        .net_open => {
            common.handleNetOpen(c);
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
        .net_close => {
            common.handleNetClose(c);
            state.markCompleted(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompleted(c);
        },

        // Connect - must call connect() first
        .net_connect => {
            const data = c.cast(NetConnect);
            if (net.connect(data.handle, data.addr, data.addr_len)) |_| {
                // Connected immediately (e.g., localhost)
                c.setResult(.net_connect, {});
                state.markCompleted(c);
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Queue for completion - addToPollQueue handles errors
                    self.addToPollQueue(state, data.handle, c);
                },
                else => {
                    c.setError(err);
                    state.markCompleted(c);
                },
            }
        },

        // Other async operations - queue and try on wakeup
        .net_accept => {
            const data = c.cast(NetAccept);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_send => {
            const data = c.cast(NetSend);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            self.addToPollQueue(state, data.handle, c);
        },

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_rename, .file_delete => unreachable,
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() before this is called.
pub fn cancel(self: *Self, state: *LoopState, c: *Completion) void {
    // Mark cancel operation as running
    c.state = .running;
    state.active += 1;

    const cancel_data = c.cast(Cancel);
    const target = cancel_data.target;

    // Try to remove from queue
    const fd = getHandle(target);
    self.removeFromPollQueue(fd, target) catch {
        // Removal failed - target is still in queue with target.canceled set
        // When target completes, markCompleted(target) will recursively complete cancel
        log.err("Failed to remove completion from poll queue during cancel", .{});
        return; // Do nothing, let target complete naturally
    };

    // Successfully removed - complete target with error.Canceled
    // markCompleted(target) will recursively complete the cancel operation
    target.setError(error.Canceled);
    state.markCompleted(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);

    // Reset pending changes counter before poll (less aggressive)
    self.pending_changes = 0;

    const rc = std.os.linux.epoll_wait(self.epoll_fd, self.events.ptr, @intCast(self.events.len), timeout);
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return posix.unexpectedErrno(err),
    };

    if (n == 0) {
        return true; // Timed out
    }

    for (self.events[0..n]) |event| {
        const fd = event.data.fd;

        // Check if this is the async wakeup fd
        if (fd == self.waker.eventfd_fd) {
            state.loop.processAsyncHandles();
            self.waker.drain();
            continue;
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
            if (net.recv(data.handle, data.buffers, data.flags)) |n| {
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
            if (net.send(data.handle, data.buffers, data.flags)) |n| {
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
            if (net.recvfrom(data.handle, data.buffers, data.flags, data.addr, data.addr_len)) |n| {
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
            if (net.sendto(data.handle, data.buffers, data.flags, data.addr, data.addr_len)) |n| {
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
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}

/// Async notification implementation using eventfd
pub const Waker = struct {
    eventfd_fd: i32 = -1,
    epoll_fd: i32,

    pub fn init(self: *Waker, epoll_fd: i32) !void {
        const efd = try posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
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
            .eventfd_fd = efd,
            .epoll_fd = epoll_fd,
        };
    }

    pub fn deinit(self: *Waker) void {
        if (self.eventfd_fd != -1) {
            // Remove from epoll
            _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, self.eventfd_fd, null);
            _ = std.os.linux.close(self.eventfd_fd);
            self.eventfd_fd = -1;
        }
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *Waker) void {
        posix.eventfd_write(self.eventfd_fd, 1) catch |err| {
            log.err("Failed to write to eventfd: {}", .{err});
        };
    }

    /// Drain the eventfd counter (called by event loop when EPOLLIN is ready)
    pub fn drain(self: *Waker) void {
        _ = posix.eventfd_read(self.eventfd_fd) catch |err| {
            log.err("Failed to read from eventfd: {}", .{err});
        };
    }
};
