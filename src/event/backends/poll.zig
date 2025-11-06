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

pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    self.* = .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    if (self.poll_queue.count() > 0) {
        std.debug.panic("poll: still have {d} fds", .{self.poll_queue.count()});
    }
    self.poll_queue.deinit(self.allocator);
    self.poll_fds.deinit(self.allocator);
}

fn getEvents(op: OperationType) c_short {
    const event: c_short = switch (op) {
        .net_connect => socket.POLL.OUT,
        .net_accept => socket.POLL.IN,
        .net_recv => socket.POLL.IN,
        .net_send => socket.POLL.OUT,
        else => unreachable,
    };
    return socket.POLL.ERR | socket.POLL.HUP | event;
}

fn getPollType(op: OperationType) PollEntryType {
    return switch (op) {
        .net_accept => .accept,
        .net_connect => .connect,
        .net_recv => .send_or_recv,
        .net_send => .send_or_recv,
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

    if (!gop.found_existing) {
        try self.poll_fds.append(self.allocator, .{ .fd = fd, .events = getEvents(completion.op), .revents = 0 });
        entry.* = .{
            .completions = .{},
            .type = getPollType(completion.op),
            .index = self.poll_fds.items.len - 1,
        };
        entry.completions.push(completion);
        return;
    }

    std.debug.assert(entry.type == getPollType(completion.op));
    self.poll_fds.items[entry.index].events |= getEvents(completion.op);
    entry.completions.push(completion);
}

fn removeFromPollQueue(self: *Self, fd: NetHandle, completion: *Completion) void {
    const entry = self.poll_queue.getPtr(fd) orelse return;

    entry.completions.remove(completion);
    if (entry.completions.head != null) {
        // There are still pending events, so we don't need to remove the entry
        return;
    }

    // Remove from the fd list
    const removed_pollfd = self.poll_fds.swapRemove(entry.index);
    std.debug.assert(removed_pollfd.fd == fd);

    // Because we swapped the position with the last fd,
    // we need to update the index of that fd in the poll queue
    if (entry.index < self.poll_fds.items.len) {
        const updated_fd = self.poll_fds.items[entry.index].fd;
        const updated_entry = self.poll_queue.getPtr(updated_fd) orelse unreachable;
        updated_entry.index = entry.index;
    }

    // Now we can remove the entry from the poll queue
    const was_removed = self.poll_queue.remove(fd);
    std.debug.assert(was_removed);
}

fn getHandle(completion: *Completion) NetHandle {
    return switch (completion.op) {
        .net_accept => completion.cast(NetAccept).handle,
        .net_connect => completion.cast(NetConnect).handle,
        .net_recv => completion.cast(NetRecv).handle,
        .net_send => completion.cast(NetSend).handle,
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

    // And now go over remaining cancelations and remove the operations from the poll queue
    while (cancels.pop()) |completion| {
        if (completion.state == .completed) continue;
        const cancel = completion.cast(Cancel);
        const fd = getHandle(cancel.cancel_c);
        self.removeFromPollQueue(fd, cancel.cancel_c);

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

    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);

    if (self.poll_fds.items.len == 0) {
        if (timeout > 0) {
            time.sleep(timeout);
        }
        return;
    }

    const n = try socket.poll(self.poll_fds.items, timeout);
    if (n == 0) {
        return;
    }

    var i: usize = 0;
    while (i < self.poll_fds.items.len) {
        const item = &self.poll_fds.items[i];
        if (item.revents == 0) {
            i += 1;
            continue;
        }

        const fd = item.fd;
        const entry = self.poll_queue.get(fd) orelse unreachable;

        var iter: ?*Completion = entry.completions.head;
        while (iter) |completion| {
            iter = completion.next;
            switch (self.checkCompletion(completion, item.revents)) {
                .completed => {
                    self.removeFromPollQueue(fd, completion);
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
}

pub fn startCompletion(self: *Self, c: *Completion) !enum { completed, running } {
    switch (c.op) {
        .timer => {
            // handled elsewhere in loop
            return .running;
        },
        .cancel => {
            const data = c.cast(Cancel);
            data.cancel_c.canceled = c;
            return .running; // Cancel waits until target is actually cancelled
        },

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
            data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            if (data.result) |_| {
                // Accepted immediately
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Register for POLLIN to detect when client connects
                    try self.addToPollQueue(data.handle, c);
                    return .running;
                },
                else => return .completed, // Error, complete immediately
            }
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
    }
}

pub fn checkCompletion(self: *Self, c: *Completion, events: @FieldType(socket.pollfd, "revents")) enum { completed, requeue } {
    _ = self;

    // Check for error conditions first
    const has_error = (events & socket.POLL.ERR) != 0;
    const has_hup = (events & socket.POLL.HUP) != 0;

    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);
            if (has_error or has_hup) {
                // Connection failed - get the actual error via getsockopt
                const sock_err = socket.getSockError(data.handle) catch {
                    data.result = error.Unexpected;
                    return .completed;
                };
                if (sock_err == 0) {
                    // No error, connection succeeded
                    data.result = {};
                } else {
                    data.result = socket.errnoToConnectError(sock_err);
                }
            } else {
                // Connection succeeded
                data.result = {};
            }
            return .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (has_error or has_hup) {
                // Get the actual error via getsockopt
                const sock_err = socket.getSockError(data.handle) catch {
                    data.result = error.Unexpected;
                    return .completed;
                };
                if (sock_err == 0) {
                    // No error, retry accept
                    data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
                } else {
                    data.result = socket.errnoToAcceptError(sock_err);
                }
            } else {
                // Retry accept now that socket is ready
                data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            }

            // Check for spurious wakeup
            if (data.result) |_| {
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Spurious wakeup - keep in poll queue
                    return .requeue;
                },
                else => {
                    return .completed;
                },
            }
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (has_error or has_hup) {
                // Get the actual error via getsockopt
                const sock_err = socket.getSockError(data.handle) catch {
                    data.result = error.Unexpected;
                    return .completed;
                };
                if (sock_err == 0) {
                    // No error, retry recv
                    data.result = socket.recv(data.handle, data.buffer, data.flags);
                } else {
                    data.result = socket.errnoToRecvError(sock_err);
                }
            } else {
                // Retry recv now that data is available
                data.result = socket.recv(data.handle, data.buffer, data.flags);
            }

            // Check for spurious wakeup
            if (data.result) |_| {
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Spurious wakeup - keep in poll queue
                    return .requeue;
                },
                else => {
                    return .completed;
                },
            }
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (has_error or has_hup) {
                // Get the actual error via getsockopt
                const sock_err = socket.getSockError(data.handle) catch {
                    data.result = error.Unexpected;
                    return .completed;
                };
                if (sock_err == 0) {
                    // No error, retry send
                    data.result = socket.send(data.handle, data.buffer, data.flags);
                } else {
                    data.result = socket.errnoToSendError(sock_err);
                }
            } else {
                // Retry send now that buffer space is available
                data.result = socket.send(data.handle, data.buffer, data.flags);
            }

            // Check for spurious wakeup
            if (data.result) |_| {
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Spurious wakeup - keep in poll queue
                    return .requeue;
                },
                else => {
                    return .completed;
                },
            }
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}
