const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../os/posix.zig");
const net = @import("../os/net.zig");
const time = @import("../os/time.zig");
const common = @import("common.zig");

const unexpectedError = @import("../os/base.zig").unexpectedError;
const ReadBuf = @import("../buf.zig").ReadBuf;
const WriteBuf = @import("../buf.zig").WriteBuf;
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
const NetPoll = @import("../completion.zig").NetPoll;
const NetClose = @import("../completion.zig").NetClose;
const NetShutdown = @import("../completion.zig").NetShutdown;

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

const log = std.log.scoped(.zio_kqueue);

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
user_event_waker: UserEventWaker,
fd_waker: FdWaker,
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

    self.* = .{
        .allocator = allocator,
        .kqueue_fd = kqueue_fd,
        .user_event_waker = undefined,
        .fd_waker = undefined,
        .change_buffer = change_buffer,
        .events = events,
        .queue_size = queue_size,
    };

    // Initialize both wakers
    try self.user_event_waker.init(kqueue_fd);
    errdefer self.user_event_waker.deinit();
    try self.fd_waker.init(kqueue_fd);
}

pub fn deinit(self: *Self) void {
    self.user_event_waker.deinit();
    self.fd_waker.deinit();
    self.change_buffer.deinit(self.allocator);
    self.allocator.free(self.events);
    if (self.kqueue_fd != -1) {
        _ = std.c.close(self.kqueue_fd);
    }
}

pub fn wake(self: *Self) void {
    // Use efficient EVFILT_USER mechanism for thread-safe wakeups
    self.user_event_waker.notify();
}

pub fn wakeFromAnywhere(self: *Self) void {
    // Use async-signal-safe fd-based mechanism (eventfd/pipe)
    self.fd_waker.notify();
}

fn getFilter(completion: *Completion) i16 {
    return switch (completion.op) {
        .net_connect => std.c.EVFILT.WRITE,
        .net_accept => std.c.EVFILT.READ,
        .net_recv => std.c.EVFILT.READ,
        .net_send => std.c.EVFILT.WRITE,
        .net_recvfrom => std.c.EVFILT.READ,
        .net_sendto => std.c.EVFILT.WRITE,
        .net_poll => blk: {
            const poll_data = completion.cast(NetPoll);
            break :blk switch (poll_data.event) {
                .recv => std.c.EVFILT.READ,
                .send => std.c.EVFILT.WRITE,
            };
        },
        else => unreachable,
    };
}

/// Reserve a slot in the change buffer, flushing with non-blocking poll if full
fn reserveChange(self: *Self, state: *LoopState) !*std.c.Kevent {
    // If at capacity, flush with non-blocking poll to drain completions
    if (self.change_buffer.items.len >= self.queue_size) {
        _ = try self.poll(state, 0);
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
        state.markCompleted(completion);
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
        .net_poll => completion.cast(NetPoll).handle,
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
                    // Queue for completion - queueRegister handles errors
                    self.queueRegister(state, data.handle, c);
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
        .net_poll => {
            const data = c.cast(NetPoll);
            self.queueRegister(state, data.handle, c);
        },

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_rename, .file_delete, .file_size, .file_stat => unreachable,
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    // Try to queue unregister
    const fd = getHandle(target);
    if (!self.queueUnregister(state, fd, target)) {
        // Queueing failed - target is still registered with target.canceled set
        // When target completes, markCompleted(target) will recursively complete cancel if canceled_by is set
        return; // Do nothing, let target complete naturally
    }

    // Successfully queued - target will be unregistered on flush
    // Complete target with error.Canceled immediately
    // markCompleted(target) will recursively complete the Cancel operation if canceled_by is set
    target.setError(error.Canceled);
    state.markCompleted(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    var timeout_spec: std.c.timespec = undefined;
    const timeout_ptr: ?*const std.c.timespec = if (timeout_ms < std.math.maxInt(u64)) blk: {
        timeout_spec = .{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((timeout_ms % 1000) * 1_000_000),
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
        if (event.filter == EVFILT_USER and event.ident == self.user_event_waker.ident) {
            state.loop.processAsyncHandles();
            self.user_event_waker.drain();
            continue;
        }

        // Check if this is the async-signal-safe wakeup fd event
        if (event.filter == std.c.EVFILT.READ and event.ident == self.fd_waker.read_fd) {
            state.loop.processAsyncHandles();
            self.fd_waker.drain();
            continue;
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
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{comp.op});
        },
    }
}

/// Async notification implementation using EVFILT_USER (thread-safe, not async-signal-safe)
pub const UserEventWaker = struct {
    kqueue_fd: i32,
    ident: usize,

    pub fn init(self: *UserEventWaker, kqueue_fd: i32) !void {
        var changes: [1]std.c.Kevent = .{.{
            .ident = @intFromPtr(self),
            .filter = EVFILT_USER,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to add user kevent: {}", .{err});
                return unexpectedError(err);
            },
        }

        self.* = .{
            .kqueue_fd = kqueue_fd,
            .ident = changes[0].ident,
        };
    }

    pub fn deinit(self: *UserEventWaker) void {
        var changes: [1]std.c.Kevent = .{.{
            .ident = self.ident,
            .filter = EVFILT_USER,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to remove user kevent: {}", .{err});
            },
        }
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *UserEventWaker) void {
        var changes: [1]std.c.Kevent = .{.{
            .ident = self.ident,
            .filter = EVFILT_USER,
            .flags = 0,
            .fflags = NOTE_TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                // Log error but don't panic - the loop may not wake up immediately,
                // but it will wake up on the next timeout or event.
                log.err("Failed to trigger user kevent: {}", .{err});
            },
        }
    }

    /// No draining needed for EVFILT_USER
    pub fn drain(self: *UserEventWaker) void {
        _ = self;
    }
};

/// Async-signal-safe notification using eventfd (FreeBSD/NetBSD) or pipe (macOS)
pub const FdWaker = struct {
    kqueue_fd: i32,
    read_fd: net.fd_t,
    write_fd: net.fd_t,

    pub fn init(self: *FdWaker, kqueue_fd: i32) !void {
        const fds = switch (builtin.target.os.tag) {
            .freebsd, .netbsd => blk: {
                // Use eventfd for FreeBSD/NetBSD (async-signal-safe)
                const efd = try posix.eventfd(0, posix.EFD.CLOEXEC | posix.EFD.NONBLOCK);
                break :blk .{ efd, efd };
            },
            .macos => blk: {
                // Use pipe for macOS (write is async-signal-safe)
                const pipe_fds = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
                break :blk .{ pipe_fds[0], pipe_fds[1] };
            },
            else => @compileError("Unsupported OS for kqueue backend"),
        };
        errdefer {
            std.posix.close(fds[0]);
            if (fds[0] != fds[1]) std.posix.close(fds[1]);
        }

        // Register read fd with kqueue using EVFILT_READ
        var changes: [1]std.c.Kevent = .{.{
            .ident = @intCast(fds[0]),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to add read fd to kqueue: {}", .{err});
                return unexpectedError(err);
            },
        }

        self.* = .{
            .kqueue_fd = kqueue_fd,
            .read_fd = fds[0],
            .write_fd = fds[1],
        };
    }

    pub fn deinit(self: *FdWaker) void {
        // Remove from kqueue
        var changes: [1]std.c.Kevent = .{.{
            .ident = @intCast(self.read_fd),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        const rc = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| {
                log.err("Failed to remove read fd from kqueue: {}", .{err});
            },
        }

        // Close fds
        std.posix.close(self.read_fd);
        if (self.read_fd != self.write_fd) {
            std.posix.close(self.write_fd);
        }
    }

    /// Notify the event loop (async-signal-safe)
    pub fn notify(self: *FdWaker) void {
        switch (builtin.target.os.tag) {
            .freebsd, .netbsd => {
                // eventfd_write is async-signal-safe
                posix.eventfd_write(self.write_fd, 1) catch |err| {
                    log.err("Failed to write to eventfd: {}", .{err});
                };
            },
            .macos => {
                // write() is async-signal-safe
                const byte: [1]u8 = .{1};
                _ = std.posix.write(self.write_fd, &byte) catch |err| {
                    log.err("Failed to write to pipe: {}", .{err});
                };
            },
            else => @compileError("Unsupported OS for kqueue backend"),
        }
    }

    /// Drain any pending notifications
    pub fn drain(self: *FdWaker) void {
        switch (builtin.target.os.tag) {
            .freebsd, .netbsd => {
                // Read and discard the counter
                _ = posix.eventfd_read(self.read_fd) catch {};
            },
            .macos => {
                // Read and discard bytes from pipe (up to 64 bytes)
                var buf: [64]u8 = undefined;
                _ = std.posix.read(self.read_fd, &buf) catch {};
            },
            else => @compileError("Unsupported OS for kqueue backend"),
        }
    }
};
