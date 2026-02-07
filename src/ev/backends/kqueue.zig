const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const common = @import("common.zig");

const unexpectedError = @import("../../os/base.zig").unexpectedError;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
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
const PipePoll = @import("../completion.zig").PipePoll;
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

const Self = @This();

const log = @import("../../common.zig").log;

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
waker_ident: usize = undefined,
change_buffer: std.ArrayList(std.c.Kevent) = .{},
events: []std.c.Kevent,
queue_size: u16,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    _ = shared_state;
    const kq = std.c.kqueue();
    const kqueue_fd: i32 = switch (posix.errno(kq)) {
        .SUCCESS => @intCast(kq),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = std.c.close(kqueue_fd);

    const events = try allocator.alloc(std.c.Kevent, queue_size);
    errdefer allocator.free(events);

    var change_buffer = try std.ArrayList(std.c.Kevent).initCapacity(allocator, queue_size);
    errdefer change_buffer.deinit(allocator);

    // Use address of self as unique waker ident
    const waker_ident = @intFromPtr(self);

    // Register EVFILT_USER for wakeups
    var changes: [1]std.c.Kevent = .{.{
        .ident = waker_ident,
        .filter = EVFILT_USER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    const rc = std.c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return unexpectedError(err),
    }

    self.* = .{
        .allocator = allocator,
        .kqueue_fd = kqueue_fd,
        .waker_ident = waker_ident,
        .change_buffer = change_buffer,
        .events = events,
        .queue_size = queue_size,
    };
}

pub fn deinit(self: *Self) void {
    self.change_buffer.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.kqueue_fd != -1) {
        _ = std.c.close(self.kqueue_fd);
    }
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    // TODO: Could also submit other pending changes if we have any
    var changes: [1]std.c.Kevent = .{.{
        .ident = self.waker_ident,
        .filter = EVFILT_USER,
        .flags = 0,
        .fflags = NOTE_TRIGGER,
        .data = 0,
        .udata = 0,
    }};
    _ = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
}

fn getFilter(completion: *Completion) i16 {
    return switch (completion.op) {
        .net_connect => std.c.EVFILT.WRITE,
        .net_accept => std.c.EVFILT.READ,
        .net_recv => std.c.EVFILT.READ,
        .net_send => std.c.EVFILT.WRITE,
        .net_recvfrom => std.c.EVFILT.READ,
        .net_sendto => std.c.EVFILT.WRITE,
        .net_recvmsg => std.c.EVFILT.READ,
        .net_sendmsg => std.c.EVFILT.WRITE,
        .net_poll => blk: {
            const poll_data = completion.cast(NetPoll);
            break :blk switch (poll_data.event) {
                .recv => std.c.EVFILT.READ,
                .send => std.c.EVFILT.WRITE,
            };
        },
        .pipe_read => std.c.EVFILT.READ,
        .pipe_write => std.c.EVFILT.WRITE,
        .pipe_poll => blk: {
            const poll_data = completion.cast(PipePoll);
            break :blk switch (poll_data.event) {
                .read => std.c.EVFILT.READ,
                .write => std.c.EVFILT.WRITE,
            };
        },
        else => unreachable,
    };
}

/// Reserve a slot in the change buffer, flushing with non-blocking poll if full
fn reserveChange(self: *Self, state: *LoopState) !*std.c.Kevent {
    // If at capacity, flush with non-blocking poll to drain completions
    if (self.change_buffer.items.len >= self.queue_size) {
        _ = try self.poll(state, .zero);
    }
    // We pre-allocated capacity, so this will never fail
    return self.change_buffer.addOneAssumeCapacity();
}

/// Queue a kevent change to register a completion.
/// If queuing fails, completes the completion with error.Unexpected.
fn queueRegister(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) void {
    const filter = getFilter(completion);
    const change = self.reserveChange(state) catch {
        log.err("Failed to reserve kevent change slot", .{});
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return;
    };
    change.* = .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.ONESHOT,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    };
}

/// Queue a kevent change to unregister a completion.
/// NOTE: Only used for cancellations; normal completions use EV_ONESHOT which auto-removes events
/// Returns true if successfully queued, false if OOM (caller should let target complete naturally)
fn queueUnregister(self: *Self, state: *LoopState, fd: NetHandle, completion: *Completion) bool {
    const filter = getFilter(completion);
    const change = self.reserveChange(state) catch {
        log.err("Failed to reserve kevent change slot for unregister", .{});
        return false;
    };
    change.* = .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = std.c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(completion),
    };
    return true;
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
                    // Queue for completion - queueRegister handles errors
                    self.queueRegister(state, data.handle, c);
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
            self.queueRegister(state, data.handle, c);
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            self.queueRegister(state, data.handle, c);
        },
        .net_send => {
            const data = c.cast(NetSend);
            self.queueRegister(state, data.handle, c);
        },
        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            self.queueRegister(state, data.handle, c);
        },
        .net_sendto => {
            const data = c.cast(NetSendTo);
            self.queueRegister(state, data.handle, c);
        },
        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            self.queueRegister(state, data.handle, c);
        },
        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            self.queueRegister(state, data.handle, c);
        },
        .net_poll => {
            const data = c.cast(NetPoll);
            self.queueRegister(state, data.handle, c);
        },
        .pipe_poll => {
            const data = c.cast(PipePoll);
            self.queueRegister(state, data.handle, c);
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
            self.queueRegister(state, data.handle, c);
        },
        .pipe_write => {
            const data = c.cast(PipeWrite);
            self.queueRegister(state, data.handle, c);
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
    // Try to queue unregister
    const fd = getHandle(target);
    if (!self.queueUnregister(state, fd, target)) {
        // Queueing failed - target is still registered, let it complete naturally
        return;
    }

    // Successfully queued - target will be unregistered on flush
    // Complete target with error.Canceled immediately
    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    var timeout_spec: std.c.timespec = undefined;
    const timeout_ptr: ?*const std.c.timespec = if (timeout.value < std.math.maxInt(time.TimeInt)) blk: {
        const timeout_ns = timeout.toNanoseconds();
        timeout_spec = .{
            .sec = @intCast(timeout_ns / time.ns_per_s),
            .nsec = @intCast(timeout_ns % time.ns_per_s),
        };
        break :blk &timeout_spec;
    } else null;

    // Submit ALL pending changes AND wait for events in a single kevent() call
    const changes_to_submit = self.change_buffer.items;
    const rc = std.c.kevent(
        self.kqueue_fd,
        changes_to_submit.ptr,
        @intCast(changes_to_submit.len),
        self.events.ptr,
        @intCast(self.events.len),
        timeout_ptr,
    );
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return unexpectedError(err),
    };

    // Clear submitted changes from buffer
    self.change_buffer.clearRetainingCapacity();

    if (n == 0) {
        return true; // Timed out
    }

    for (self.events[0..n]) |event| {
        // Check if this is the async wakeup user event
        if (event.filter == EVFILT_USER and event.ident == self.waker_ident) {
            continue;
        }

        // Get completion pointer from udata
        if (event.udata == 0) continue; // Shouldn't happen, but be defensive

        const completion: *Completion = @ptrFromInt(event.udata);
        const fd: NetHandle = @intCast(event.ident);

        // Skip if already completed (can happen with cancellations)
        if (completion.state == .completed or completion.state == .dead) {
            continue;
        }

        switch (checkCompletion(completion, &event)) {
            .completed => {
                // EV_ONESHOT automatically removes the event
                state.markCompletedFromBackend(completion);
            },
            .requeue => {
                // Spurious wakeup - EV_ONESHOT already consumed the event, re-register
                self.queueRegister(state, fd, completion);
            },
        }
    }

    return false; // Did not timeout, woke up due to events
}

const CheckResult = enum { completed, requeue };

fn handleKqueueError(event: *const std.c.Kevent, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.flags & EV_ERROR) != 0;
    const has_eof = (event.flags & EV_EOF) != 0;
    if (!has_error and !has_eof) return null;

    if (has_error) {
        // event.data contains the errno when EV_ERROR is set
        if (event.data != 0) {
            return errnoToError(@enumFromInt(@as(i32, @intCast(event.data))));
        }
    }

    const sock_err = net.getSockError(@intCast(event.ident)) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
    return errnoToError(@enumFromInt(sock_err));
}

pub fn checkCompletion(comp: *Completion, event: *const std.c.Kevent) CheckResult {
    switch (comp.op) {
        .net_connect => {
            if (handleKqueueError(event, net.errnoToConnectError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            if (handleKqueueError(event, net.errnoToAcceptError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                comp.setResult(.net_accept, handle);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |n| {
                comp.setResult(.net_recv, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_send => {
            const data = comp.cast(NetSend);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.send(data.handle, data.buffer.iovecs, data.flags)) |n| {
                comp.setResult(.net_send, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_recvfrom, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_sendto, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvmsg => {
            const data = comp.cast(NetRecvMsg);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                comp.setResult(.net_recvmsg, result);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendmsg => {
            const data = comp.cast(NetSendMsg);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |n| {
                comp.setResult(.net_sendmsg, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_poll => {
            // For poll operations, EOF means the socket is "ready" (will return EOF on next read).
            // Reuse handleKqueueError so we only fail on real socket errors (SO_ERROR != 0),
            // consistent with the other net_* ops.
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_poll, {});
            }
            return .completed;
        },
        .pipe_read => {
            const data = comp.cast(PipeRead);
            // Check for actual errors first
            const has_error = (event.flags & EV_ERROR) != 0;
            if (has_error and event.data != 0) {
                comp.setError(fs.errnoToFileReadError(@enumFromInt(@as(i32, @intCast(event.data)))));
                return .completed;
            }
            // Try to read - there might still be data in the pipe buffer
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(.pipe_read, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // For pipes, EV_EOF means the write end is closed
                    // If we got WouldBlock and EOF is set, that's EOF (no more data)
                    const has_eof = (event.flags & EV_EOF) != 0;
                    if (has_eof) {
                        comp.setResult(.pipe_read, 0);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .pipe_write => {
            const data = comp.cast(PipeWrite);
            // For pipes, check for errors but don't use getSockError
            const has_error = (event.flags & EV_ERROR) != 0;
            const has_eof = (event.flags & EV_EOF) != 0;
            if (has_error and event.data != 0) {
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                const err = fs.errnoToFileWriteError(@enumFromInt(@as(i32, @intCast(event.data))));
                comp.setError(switch (err) {
                    error.NotOpenForWriting => error.BrokenPipe,
                    else => err,
                });
                return .completed;
            }
            if (has_eof) {
                // Read end closed
                comp.setError(error.BrokenPipe);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(.pipe_write, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                error.NotOpenForWriting => {
                    comp.setError(error.BrokenPipe);
                    return .completed;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .pipe_close => unreachable, // Handled synchronously in submit
        .pipe_create => unreachable, // Handled synchronously in submit
        .pipe_poll => {
            // For poll operations, any event (error, EOF, or readiness) means "ready"
            // The actual error (if any) will be discovered on the next read/write
            comp.setResult(.pipe_poll, {});
            return .completed;
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{comp.op});
        },
    }
}
