const std = @import("std");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const common = @import("common.zig");

const unexpectedError = @import("../../os/base.zig").unexpectedError;
const ReadBuf = @import("../buf.zig").ReadBuf;
const WriteBuf = @import("../buf.zig").WriteBuf;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
const Queue = @import("../queue.zig").Queue;
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
const PipePoll = @import("../completion.zig").PipePoll;
const PipeCreate = @import("../completion.zig").PipeCreate;
const PipeRead = @import("../completion.zig").PipeRead;
const PipeWrite = @import("../completion.zig").PipeWrite;
const PipeClose = @import("../completion.zig").PipeClose;
const fs = @import("../../os/fs.zig");

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{};

pub const SharedState = struct {};

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
waker_eventfd: i32 = -1,
events: []std.os.linux.epoll_event,
queue_size: u16,
pending_changes: usize = 0,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    _ = shared_state;
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
        .pipe_read => std.os.linux.EPOLL.IN,
        .pipe_write => std.os.linux.EPOLL.OUT,
        .pipe_poll => blk: {
            const poll_data = completion.cast(PipePoll);
            break :blk switch (poll_data.event) {
                .read => std.os.linux.EPOLL.IN,
                .write => std.os.linux.EPOLL.OUT,
            };
        },
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
        .pipe_read => .send_or_recv,
        .pipe_write => .send_or_recv,
        .pipe_poll => .send_or_recv,
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
            .SUCCESS, .NOENT => {
                // SUCCESS: successfully removed
                // NOENT: fd was not registered (already removed or never added) - safe to proceed
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
        .pipe_read => completion.cast(PipeRead).handle,
        .pipe_write => completion.cast(PipeWrite).handle,
        .pipe_close => completion.cast(PipeClose).handle,
        else => unreachable,
    };
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.active += 1;

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
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Connect - must call connect() first
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
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            self.addToPollQueue(state, data.handle, c);
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            self.addToPollQueue(state, data.handle, c);
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
        .pipe_read => {
            const data = c.cast(PipeRead);
            self.addToPollQueue(state, data.handle, c);
        },
        .pipe_write => {
            const data = c.cast(PipeWrite);
            self.addToPollQueue(state, data.handle, c);
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

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_size, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .file_stat, .dir_open, .dir_close, .dir_read, .dir_create_dir, .dir_rename, .dir_delete_file, .dir_delete_dir, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link => unreachable,
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

    // Always complete target with error.Canceled
    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    const timeout_ms: i32 = std.math.cast(i32, timeout.toMilliseconds()) orelse std.math.maxInt(i32);

    // Reset pending changes counter before poll (less aggressive)
    self.pending_changes = 0;

    const rc = std.os.linux.epoll_wait(self.epoll_fd, self.events.ptr, @intCast(self.events.len), timeout_ms);
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return unexpectedError(err),
    };

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
        .pipe_read => {
            const data = c.cast(PipeRead);
            // Try to read - there might still be data in the pipe buffer
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(.pipe_read, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // For pipes, HUP means the write end is closed
                    // If we got WouldBlock and HUP is set, that's EOF (no more data)
                    const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
                    if (has_hup) {
                        c.setResult(.pipe_read, 0);
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
        .pipe_write => {
            const data = c.cast(PipeWrite);
            // For pipes, check for errors but don't use getSockError
            const has_error = (event.events & std.os.linux.EPOLL.ERR) != 0;
            const has_hup = (event.events & std.os.linux.EPOLL.HUP) != 0;
            if (has_error or has_hup) {
                // Pipe error or read end closed
                c.setError(error.BrokenPipe);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(.pipe_write, n);
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
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}
