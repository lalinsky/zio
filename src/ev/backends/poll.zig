const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const common = @import("common.zig");
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
const FileStreamPoll = @import("../completion.zig").FileStreamPoll;
const FileStreamRead = @import("../completion.zig").FileStreamRead;
const FileStreamWrite = @import("../completion.zig").FileStreamWrite;

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;
const fs = @import("../../os/fs.zig");

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
    index: usize,
};

const Self = @This();

const log = std.log.scoped(.zio_poll);

allocator: std.mem.Allocator,
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
poll_fds: std.ArrayList(net.pollfd) = .empty,
waker: Waker,
queue_size: u16,
pending_changes: usize = 0,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    _ = shared_state;
    self.* = .{
        .allocator = allocator,
        .waker = undefined,
        .queue_size = queue_size,
    };

    try self.poll_fds.ensureTotalCapacity(self.allocator, queue_size);
    errdefer self.poll_fds.deinit(self.allocator);

    try self.poll_queue.ensureTotalCapacity(self.allocator, queue_size);
    errdefer self.poll_queue.deinit(self.allocator);

    // Initialize Waker
    try self.waker.init(self);
}

pub fn deinit(self: *Self) void {
    self.waker.deinit();
    self.poll_queue.deinit(self.allocator);
    self.poll_fds.deinit(self.allocator);
}

pub fn wake(self: *Self) void {
    self.waker.notify();
}

pub fn wakeFromAnywhere(self: *Self) void {
    // pipe write is async-signal-safe on POSIX, so we can use the same mechanism
    self.waker.notify();
}

fn getEvents(completion: *Completion) @FieldType(net.pollfd, "events") {
    return switch (completion.op) {
        .net_connect => net.POLL.OUT,
        .net_accept => net.POLL.IN,
        .net_recv => net.POLL.IN,
        .net_send => net.POLL.OUT,
        .net_recvfrom => net.POLL.IN,
        .net_sendto => net.POLL.OUT,
        .net_poll => blk: {
            const poll_data = completion.cast(NetPoll);
            break :blk switch (poll_data.event) {
                .recv => net.POLL.IN,
                .send => net.POLL.OUT,
            };
        },
        // File stream operations not supported on Windows (poll uses SOCKET, not HANDLE)
        .file_stream_read => if (builtin.os.tag == .windows) unreachable else net.POLL.IN,
        .file_stream_write => if (builtin.os.tag == .windows) unreachable else net.POLL.OUT,
        .file_stream_poll => if (builtin.os.tag == .windows) unreachable else blk: {
            const poll_data = completion.cast(FileStreamPoll);
            break :blk switch (poll_data.event) {
                .read => net.POLL.IN,
                .write => net.POLL.OUT,
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
        .net_poll => .send_or_recv,
        .file_stream_read => if (builtin.os.tag == .windows) unreachable else .send_or_recv,
        .file_stream_write => if (builtin.os.tag == .windows) unreachable else .send_or_recv,
        .file_stream_poll => if (builtin.os.tag == .windows) unreachable else .send_or_recv,
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
        state.markCompletedFromBackend(completion);
        return;
    };

    var entry = gop.value_ptr;
    const op_events = getEvents(completion);

    if (!gop.found_existing) {
        self.poll_fds.append(self.allocator, .{ .fd = fd, .events = op_events, .revents = 0 }) catch {
            log.err("Failed to append to poll_fds: OutOfMemory", .{});
            _ = self.poll_queue.remove(fd);
            completion.setError(error.Unexpected);
            state.markCompletedFromBackend(completion);
            return;
        };
        entry.* = .{
            .completions = .{},
            .type = getPollType(completion.op),
            .index = self.poll_fds.items.len - 1,
        };
        entry.completions.push(completion);
        return;
    }

    std.debug.assert(entry.type == getPollType(completion.op));

    self.poll_fds.items[entry.index].events |= op_events;
    entry.completions.push(completion);
}

fn removeFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) !void {
    const entry = self.poll_queue.getPtr(fd) orelse return;

    _ = entry.completions.remove(completion);
    if (entry.completions.head == null) {
        // No more completions - remove from poll list and poll queue
        const removed_pollfd = self.poll_fds.swapRemove(entry.index);
        std.debug.assert(removed_pollfd.fd == fd);

        // Because we swapped the position with the last fd,
        // we need to update the index of that fd in the poll queue
        if (entry.index < self.poll_fds.items.len) {
            const updated_fd = self.poll_fds.items[entry.index].fd;
            if (self.poll_queue.getPtr(updated_fd)) |updated_entry| {
                updated_entry.index = entry.index;
            }
        }

        // Now we can remove the entry from the poll queue
        const was_removed = self.poll_queue.remove(fd);
        std.debug.assert(was_removed);
        return;
    }

    // Recalculate events from remaining completions
    var new_events: @FieldType(net.pollfd, "events") = 0;
    var iter: ?*Completion = entry.completions.head;
    while (iter) |c| : (iter = c.next) {
        new_events |= getEvents(c);
    }

    self.poll_fds.items[entry.index].events = new_events;
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
        // File stream handles are only compatible with NetHandle on non-Windows
        .file_stream_read => if (builtin.os.tag == .windows) unreachable else completion.cast(FileStreamRead).handle,
        .file_stream_write => if (builtin.os.tag == .windows) unreachable else completion.cast(FileStreamWrite).handle,
        .file_stream_poll => if (builtin.os.tag == .windows) unreachable else completion.cast(FileStreamPoll).handle,
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
        .net_poll => {
            const data = c.cast(NetPoll);
            self.addToPollQueue(state, data.handle, c);
        },

        // File stream operations (not supported on Windows - poll uses SOCKET, not HANDLE)
        .file_stream_read => {
            if (builtin.os.tag == .windows) {
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            }
            const data = c.cast(FileStreamRead);
            self.addToPollQueue(state, data.handle, c);
        },
        .file_stream_write => {
            if (builtin.os.tag == .windows) {
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            }
            const data = c.cast(FileStreamWrite);
            self.addToPollQueue(state, data.handle, c);
        },
        .file_stream_poll => {
            if (builtin.os.tag == .windows) {
                c.setError(error.Unexpected);
                state.markCompletedFromBackend(c);
                return;
            }
            const data = c.cast(FileStreamPoll);
            self.addToPollQueue(state, data.handle, c);
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
    self.removeFromPollQueue(fd, target) catch {
        // Removal failed - target is still in queue with target.canceled set
        // When target completes, markCompleted(target) will recursively complete cancel if canceled_by is set
        log.err("Failed to remove completion from poll queue during cancel", .{});
        return; // Do nothing, let target complete naturally
    };

    // Successfully removed - complete target with error.Canceled
    // markCompleted(target) will recursively complete the Cancel operation if canceled_by is set
    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);

    // Reset pending changes counter before poll (less aggressive)
    self.pending_changes = 0;

    const n = try net.poll(self.poll_fds.items, timeout);

    if (n == 0) {
        return true; // Timed out
    }

    var i: usize = 0;
    while (i < self.poll_fds.items.len) {
        const item = &self.poll_fds.items[i];
        if (item.revents == 0) {
            i += 1;
            continue;
        }

        const fd = item.fd;

        // Check if this is the async wakeup fd
        if (fd == self.waker.read_fd) {
            self.waker.drain();
            i += 1;
            continue;
        }

        const entry = self.poll_queue.get(fd) orelse unreachable;

        var iter: ?*Completion = entry.completions.head;
        while (iter) |completion| {
            iter = completion.next;
            switch (checkCompletion(completion, item)) {
                .completed => {
                    try self.removeFromPollQueue(fd, completion);
                    state.markCompletedFromBackend(completion);
                },
                .requeue => {
                    // Spurious wakeup - keep in poll queue
                },
            }
        }

        // Only increment if the fd at position i is still the same.
        // If it changed, swapRemove moved a different fd here, so reprocess.
        if (item.fd == fd) {
            i += 1;
        }
    }

    return false; // Did not timeout, woke up due to events
}

const CheckResult = enum { completed, requeue };

fn handlePollError(item: *const net.pollfd, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (item.revents & net.POLL.ERR) != 0;
    const has_hup = (item.revents & net.POLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = net.getSockError(item.fd) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
    return errnoToError(@enumFromInt(sock_err));
}

fn checkSpuriousWakeup(result: anytype) CheckResult {
    if (result) |_| {
        return .completed;
    } else |err| switch (err) {
        error.WouldBlock => return .requeue,
        else => return .completed,
    }
}

pub fn checkCompletion(c: *Completion, item: *const net.pollfd) CheckResult {
    switch (c.op) {
        .net_connect => {
            if (handlePollError(item, net.errnoToConnectError)) |err| {
                c.setError(err);
            } else {
                c.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (handlePollError(item, net.errnoToAcceptError)) |err| {
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
            if (handlePollError(item, net.errnoToRecvError)) |err| {
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
            if (handlePollError(item, net.errnoToSendError)) |err| {
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
            if (handlePollError(item, net.errnoToRecvError)) |err| {
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
            if (handlePollError(item, net.errnoToSendError)) |err| {
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
        .net_poll => {
            // For poll operations, we want to know when the socket is "ready"
            // This includes error conditions (POLLERR, POLLHUP) because they
            // indicate the socket is ready to return an error on the next I/O
            const has_error = (item.revents & net.POLL.ERR) != 0;
            const has_hup = (item.revents & net.POLL.HUP) != 0;

            if (has_error or has_hup) {
                // Socket has error or hangup - it's "ready" in the sense that
                // the next I/O operation will complete (with an error)
                c.setResult(.net_poll, {});
                return .completed;
            }

            // Check if the requested events are actually ready
            const requested_events = getEvents(c);
            const ready_events = item.revents & requested_events;
            if (ready_events != 0) {
                c.setResult(.net_poll, {});
                return .completed;
            }
            // Requested events not ready yet - requeue
            return .requeue;
        },
        // File stream operations not supported on Windows (poll uses SOCKET, not HANDLE)
        .file_stream_read => if (builtin.os.tag == .windows) unreachable else {
            const data = c.cast(FileStreamRead);
            if (handlePollError(item, fs.errnoToFileReadError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(.file_stream_read, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .file_stream_write => if (builtin.os.tag == .windows) unreachable else {
            const data = c.cast(FileStreamWrite);
            if (handlePollError(item, fs.errnoToFileWriteError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                c.setResult(.file_stream_write, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    c.setError(err);
                    return .completed;
                },
            }
        },
        .file_stream_poll => if (builtin.os.tag == .windows) unreachable else {
            // For poll operations, we want to know when the fd is "ready"
            const has_error = (item.revents & net.POLL.ERR) != 0;
            const has_hup = (item.revents & net.POLL.HUP) != 0;

            if (has_error or has_hup) {
                // Stream has error or hangup - it's "ready"
                c.setResult(.file_stream_poll, {});
                return .completed;
            }

            // Check if the requested events are actually ready
            const requested_events = getEvents(c);
            const ready_events = item.revents & requested_events;
            if (ready_events != 0) {
                c.setResult(.file_stream_poll, {});
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

/// Async notification implementation using pipe (POSIX) or loopback socket (Windows)
pub const Waker = struct {
    read_fd: net.fd_t = undefined,
    write_fd: net.fd_t = undefined,
    backend: *Self,

    pub fn init(self: *Waker, backend: *Self) !void {
        net.ensureWSAInitialized();

        switch (builtin.os.tag) {
            .windows => {
                // Windows: use loopback socket pair
                const pair = try net.createLoopbackSocketPair();
                self.* = .{
                    .read_fd = pair[0],
                    .write_fd = pair[1],
                    .backend = backend,
                };
            },
            else => {
                // POSIX: use pipe
                const pipefd = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
                self.* = .{
                    .read_fd = pipefd[0],
                    .write_fd = pipefd[1],
                    .backend = backend,
                };
            },
        }
        errdefer self.deinit();

        // Add read fd to poll_fds
        try backend.poll_fds.append(backend.allocator, .{
            .fd = self.read_fd,
            .events = net.POLL.IN,
            .revents = 0,
        });
    }

    pub fn deinit(self: *Waker) void {
        // Remove from poll_fds by finding its index
        for (self.backend.poll_fds.items, 0..) |pfd, i| {
            if (pfd.fd == self.read_fd) {
                _ = self.backend.poll_fds.swapRemove(i);
                break;
            }
        }

        net.close(self.read_fd);
        net.close(self.write_fd);
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *Waker) void {
        const byte: [1]u8 = .{1};
        switch (builtin.os.tag) {
            .windows => {
                _ = net.send(self.write_fd, &[_]net.iovec_const{net.iovecConstFromSlice(&byte)}, .{}) catch |err| {
                    log.err("Failed to send to wakeup socket: {}", .{err});
                };
            },
            else => {
                _ = fs.write(self.write_fd, &byte) catch |err| {
                    log.err("Failed to write to wakeup pipe: {}", .{err});
                };
            },
        }
    }

    /// Drain the pipe/socket (called by event loop when POLLIN is ready)
    pub fn drain(self: *Waker) void {
        var buf: [64]u8 = undefined;
        switch (builtin.os.tag) {
            .windows => {
                var bufs: [1]net.iovec = .{net.iovecFromSlice(&buf)};
                _ = net.recv(self.read_fd, &bufs, .{}) catch {};
            },
            else => {
                _ = fs.read(self.read_fd, &buf) catch {};
            },
        }
    }
};
