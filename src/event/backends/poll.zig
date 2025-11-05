const std = @import("std");
const posix = @import("../os/posix.zig");
const socket = @import("../os/posix/socket.zig");
const time = @import("../time.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
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

pub const NetHandle = posix.system.fd_t;

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = socket.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const Poll = struct {
    fd: socket.pollfd,
    completion: *Completion,
};

const Self = @This();

const log = std.log.scoped(.zio_poll);
const max_fds = 256;

fds: std.MultiArrayList(Poll) = .empty,

pub fn init(self: *Self) !void {
    self.* = .{};
}

pub fn deinit(self: *Self) void {
    if (self.fds.len > 0) {
        std.debug.panic("poll: still have {d} fds", .{self.fds.len});
    }
}

fn cancelCompletion(completion: *Completion, cancel: *Completion) void {
    // Set error.Canceled result based on operation type
    switch (completion.op) {
        .net_connect => {
            const data = completion.cast(NetConnect);
            data.result = error.Canceled;
        },
        .net_accept => {
            const data = completion.cast(NetAccept);
            data.result = error.Canceled;
        },
        .net_recv => {
            const data = completion.cast(NetRecv);
            data.result = error.Canceled;
        },
        .net_send => {
            const data = completion.cast(NetSend);
            data.result = error.Canceled;
        },
        else => unreachable, // Only async ops can be in fds
    }
    // Mark both completions as done
    completion.state = .completed;
    cancel.state = .completed;
}

fn processCancelations(self: *Self, state: *LoopState) void {
    var i: usize = 0;
    const completions = self.fds.items(.completion);
    while (i < self.fds.len) {
        const completion = completions[i];
        if (completion.canceled) |cancel| {
            cancelCompletion(completion, cancel);
            // Remove from poll queue
            self.fds.swapRemove(i);
            state.active -= 2; // Both the operation and the cancel
        } else {
            i += 1;
        }
    }
}

pub fn tick(self: *Self, state: *LoopState, timeout_ms: u64) !void {
    var submissions = state.submissions;
    state.submissions = null;

    while (submissions) |completion| {
        submissions = completion.next;
        if (try self.start(completion)) {
            completion.state = .completed;
            state.active -= 1;
        }
    }

    // Process cancelations before polling
    self.processCancelations(state);

    const timeout: i32 = std.math.cast(i32, timeout_ms) orelse std.math.maxInt(i32);
    if (self.fds.len > 0) {
        const n = try socket.poll(self.fds.items(.fd), timeout);
        if (n == 0) {
            return;
        }
    } else if (timeout_ms > 0) {
        time.sleep(timeout);
    }

    var i: usize = 0;
    const items = self.fds.slice();
    const fds = items.items(.fd).ptr;
    const completions = items.items(.completion).ptr;
    while (i < self.fds.len) {
        const fd = fds[i];
        if (fd.revents != 0) {
            self.complete(completions[i], fd.revents);
            self.fds.swapRemove(i);
            state.active -= 1;
        } else {
            i += 1;
        }
    }
}

pub fn start(self: *Self, c: *Completion) !bool {
    switch (c.op) {
        .timer => {
            // handled elsewhere in loop
            return false;
        },
        .cancel => {
            const data = c.cast(Cancel);
            data.cancel_c.canceled = c;
            return false; // Cancel waits until target is actually cancelled
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
            return true;
        },
        .net_bind => {
            const data = c.cast(NetBind);
            data.result = socket.bind(data.handle, data.addr, data.addr_len);
            return true;
        },
        .net_listen => {
            const data = c.cast(NetListen);
            data.result = socket.listen(data.handle, data.backlog);
            return true;
        },
        .net_close => {
            const data = c.cast(NetClose);
            data.result = socket.close(data.handle);
            return true;
        },
        .net_shutdown => {
            const data = c.cast(NetShutdown);
            data.result = socket.shutdown(data.handle, data.how);
            return true;
        },

        // Potentially async operations - try first, register if WouldBlock
        .net_connect => {
            const data = c.cast(NetConnect);
            data.result = socket.connect(data.handle, data.addr, data.addr_len);
            if (data.result) |_| {
                // Connected immediately (e.g., localhost)
                return true;
            } else |err| switch (err) {
                error.WouldBlock, error.ConnectionPending => {
                    // Register for POLLOUT to detect when connection completes
                    c.state = .running;
                    try self.fds.append(std.heap.page_allocator, .{
                        .fd = .{
                            .fd = data.handle,
                            .events = socket.POLL.OUT | socket.POLL.ERR | socket.POLL.HUP,
                            .revents = 0,
                        },
                        .completion = c,
                    });
                    return false;
                },
                else => return true, // Error, complete immediately
            }
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            if (data.result) |_| {
                // Accepted immediately
                return true;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Register for POLLIN to detect when client connects
                    c.state = .running;
                    try self.fds.append(std.heap.page_allocator, .{
                        .fd = .{
                            .fd = data.handle,
                            .events = socket.POLL.IN,
                            .revents = 0,
                        },
                        .completion = c,
                    });
                    return false;
                },
                else => return true, // Error, complete immediately
            }
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            data.result = socket.recv(data.handle, data.buffer, data.flags);
            if (data.result) |_| {
                // Received data immediately
                return true;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Register for POLLIN to detect when data arrives
                    c.state = .running;
                    try self.fds.append(std.heap.page_allocator, .{
                        .fd = .{
                            .fd = data.handle,
                            .events = socket.POLL.IN,
                            .revents = 0,
                        },
                        .completion = c,
                    });
                    return false;
                },
                else => return true, // Error, complete immediately
            }
        },
        .net_send => {
            const data = c.cast(NetSend);
            data.result = socket.send(data.handle, data.buffer, data.flags);
            if (data.result) |_| {
                // Sent data immediately
                return true;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Register for POLLOUT to detect when buffer space available
                    c.state = .running;
                    try self.fds.append(std.heap.page_allocator, .{
                        .fd = .{
                            .fd = data.handle,
                            .events = socket.POLL.OUT,
                            .revents = 0,
                        },
                        .completion = c,
                    });
                    return false;
                },
                else => return true, // Error, complete immediately
            }
        },
    }
}

pub fn complete(self: *Self, c: *Completion, events: @FieldType(socket.pollfd, "revents")) void {
    _ = self;

    // Check for error conditions first
    const has_error = (events & socket.POLL.ERR) != 0;
    const has_hup = (events & socket.POLL.HUP) != 0;

    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);
            if (has_error or has_hup) {
                // Connection failed - need to get the actual error via getsockopt
                data.result = error.ConnectionRefused;
            } else {
                // Connection succeeded
                data.result = {};
            }
            c.state = .completed;
        },
        .net_accept => {
            const data = c.cast(NetAccept);
            if (has_error or has_hup) {
                data.result = error.ConnectionAborted;
            } else {
                // Retry accept now that socket is ready
                data.result = socket.accept(data.handle, data.addr, data.addr_len, data.flags);
            }
            c.state = .completed;
        },
        .net_recv => {
            const data = c.cast(NetRecv);
            if (has_error or has_hup) {
                data.result = error.ConnectionResetByPeer;
            } else {
                // Retry recv now that data is available
                data.result = socket.recv(data.handle, data.buffer, data.flags);
            }
            c.state = .completed;
        },
        .net_send => {
            const data = c.cast(NetSend);
            if (has_error or has_hup) {
                data.result = error.BrokenPipe;
            } else {
                // Retry send now that buffer space is available
                data.result = socket.send(data.handle, data.buffer, data.flags);
            }
            c.state = .completed;
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{c.op});
        },
    }
}
