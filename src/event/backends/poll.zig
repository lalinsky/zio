const std = @import("std");
const posix = @import("../os/posix.zig");
const socket = @import("../os/posix/socket.zig");

const Self = @This();

const log = std.log.scoped(.zio_poll);
const max_fds = 256;

fds: [max_fds]socket.pollfd = undefined,
num_fds: socket.nfds_t = 0,

pub fn init(self: *Self) !void {
    self.* = .{};
}

pub fn deinit(self: *Self) void {
    if (self.num_fds > 0) {
        std.debug.panic("poll: still have {d} fds", .{self.num_fds});
    }
}

pub fn tick(self: *Self, timeout_ms: u64) !void {
    _ = try socket.poll(&self.fds, self.num_fds, @intCast(timeout_ms));
    // TODO: handle events
}
