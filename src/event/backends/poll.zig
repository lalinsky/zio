const std = @import("std");
const posix = @import("../os/posix.zig");

const Self = @This();

const log = std.log.scoped(.zio_poll);
const max_fds = 256;

fds: [max_fds]posix.system.pollfd = undefined,
num_fds: posix.system.nfds_t = 0,

pub fn init(self: *Self) !void {
    self.* = .{};
}

pub fn deinit(self: *Self) void {
    if (self.num_fds > 0) {
        std.debug.panic("poll: still have {d} fds", .{self.num_fds});
    }
}

pub fn tick(self: *Self, timeout_ms: u64) !void {
    while (true) {
        const rc = posix.system.poll(&self.fds, self.num_fds, @intCast(timeout_ms));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                // TODO: handle
                return;
            },
            // fds points outside the process's accessible address space.  The array given as argument was not contained in the calling program's address space.
            .FAULT => unreachable,
            // A signal occurred before any requested event
            .INTR => continue,
            // The nfds value exceeds the RLIMIT_NOFILE value.
            .INVAL => return error.SystemResources,
            // Unable to allocate memory for kernel data structures.
            .NOMEM => return error.SystemResources,
            // Anything else
            else => |err| return posix.unexpectedErrno(err),
        }
        unreachable;
    }
}
