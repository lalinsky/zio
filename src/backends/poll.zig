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
    index: usize,
};

const Self = @This();

const log = std.log.scoped(.zio_poll);

allocator: std.mem.Allocator,
poll_queue: std.AutoHashMapUnmanaged(NetHandle, PollEntry) = .empty,
poll_fds: std.ArrayList(socket.pollfd) = .empty,
waker: Waker,

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
        .waker = undefined,
    };

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

fn getEvents(op: OperationType) @FieldType(socket.pollfd, "events") {
    return switch (op) {
        .net_connect => socket.POLL.OUT,
        .net_accept => socket.POLL.IN,
        .net_recv => socket.POLL.IN,
        .net_send => socket.POLL.OUT,
        .net_recvfrom => socket.POLL.IN,
        .net_sendto => socket.POLL.OUT,
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
        try self.poll_fds.append(self.allocator, .{ .fd = fd, .events = op_events, .revents = 0 });
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
    var new_events: @FieldType(socket.pollfd, "events") = 0;
    var iter: ?*Completion = entry.completions.head;
    while (iter) |c| : (iter = c.next) {
        new_events |= getEvents(c.op);
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

        completion.setResult(.cancel, {});
        cancel.cancel_c.setError(error.Canceled);
        state.markCompleted(cancel.cancel_c);
    }
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);

    const n = try socket.poll(self.poll_fds.items, timeout);
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
            state.loop.processAsyncHandles();
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
                    state.markCompleted(completion);
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

pub fn startCompletion(self: *Self, c: *Completion) !enum { completed, running } {
    switch (c.op) {
        .timer, .async, .work => unreachable, // Manged by the loop
        .cancel => return .running, // Cancel was marked by loop and waits until the target completes

        // Synchronous operations - complete immediately
        .net_open => {
            const data = c.cast(NetOpen);
            if (socket.socket(data.domain, data.socket_type, data.protocol, data.flags)) |handle| {
                c.setResult(.net_open, handle);
            } else |err| {
                c.setError(err);
            }
            return .completed;
        },
        .net_bind => {
            const data = c.cast(NetBind);
            if (socket.bind(data.handle, data.addr, data.addr_len)) |_| {
                c.setResult(.net_bind, {});
            } else |err| {
                c.setError(err);
            }
            return .completed;
        },
        .net_listen => {
            const data = c.cast(NetListen);
            if (socket.listen(data.handle, data.backlog)) |_| {
                c.setResult(.net_listen, {});
            } else |err| {
                c.setError(err);
            }
            return .completed;
        },
        .net_close => {
            const data = c.cast(NetClose);
            socket.close(data.handle);
            c.setResult(.net_close, {});
            return .completed;
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            if (socket.shutdown(data.handle, data.how)) |_| {
                c.setResult(.net_shutdown, {});
            } else |err| {
                c.setError(err);
            }
            return .completed;
        },

        // Potentially async operations - try first, register if WouldBlock
        .net_connect => {
            const data = c.cast(NetConnect);
            if (socket.connect(data.handle, data.addr, data.addr_len)) |_| {
                // Connected immediately (e.g., localhost)
                c.setResult(.net_connect, {});
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Register for POLLOUT to detect when connection completes
                    try self.addToPollQueue(data.handle, c);
                    return .running;
                },
                else => {
                    c.setError(err);
                    return .completed;
                },
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

fn handlePollError(item: *const socket.pollfd, comptime errnoToError: fn (i32) anyerror) ?anyerror {
    const has_error = (item.revents & socket.POLL.ERR) != 0;
    const has_hup = (item.revents & socket.POLL.HUP) != 0;
    if (!has_error and !has_hup) return null;

    const sock_err = socket.getSockError(item.fd) catch return error.Unexpected;
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

pub fn checkCompletion(c: *Completion, item: *const socket.pollfd) CheckResult {
    switch (c.op) {
        .net_connect => {
            if (handlePollError(item, socket.errnoToConnectError)) |err| {
                c.setError(err);
            } else {
                c.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (handlePollError(item, socket.errnoToAcceptError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (socket.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
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
            if (handlePollError(item, socket.errnoToRecvError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (socket.recv(data.handle, data.buffers, data.flags)) |n| {
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
            if (handlePollError(item, socket.errnoToSendError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (socket.send(data.handle, data.buffers, data.flags)) |n| {
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
            if (handlePollError(item, socket.errnoToRecvError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (socket.recvfrom(data.handle, data.buffers, data.flags, data.addr, data.addr_len)) |n| {
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
            if (handlePollError(item, socket.errnoToSendError)) |err| {
                c.setError(err);
                return .completed;
            }
            if (socket.sendto(data.handle, data.buffers, data.flags, data.addr, data.addr_len)) |n| {
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

/// Async notification implementation using pipe (POSIX) or loopback socket (Windows)
pub const Waker = struct {
    const builtin = @import("builtin");

    read_fd: socket.fd_t = undefined,
    write_fd: socket.fd_t = undefined,
    backend: *Self,

    pub fn init(self: *Waker, backend: *Self) !void {
        socket.ensureWSAInitialized();

        switch (builtin.os.tag) {
            .windows => {
                // Windows: use loopback socket pair
                const pair = try socket.createLoopbackSocketPair();
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
            .events = socket.POLL.IN,
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

        socket.close(self.read_fd);
        socket.close(self.write_fd);
    }

    /// Notify the event loop (thread-safe)
    pub fn notify(self: *Waker) void {
        const byte: [1]u8 = .{1};
        switch (builtin.os.tag) {
            .windows => {
                _ = socket.send(self.write_fd, &[_]socket.iovec_const{socket.iovecConstFromSlice(&byte)}, .{}) catch |err| {
                    log.err("Failed to send to wakeup socket: {}", .{err});
                };
            },
            else => {
                _ = std.posix.write(self.write_fd, &byte) catch |err| {
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
                var bufs: [1]socket.iovec = .{socket.iovecFromSlice(&buf)};
                _ = socket.recv(self.read_fd, &bufs, .{}) catch {};
            },
            else => {
                _ = std.posix.read(self.read_fd, &buf) catch {};
            },
        }
    }
};
