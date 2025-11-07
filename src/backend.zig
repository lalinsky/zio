const builtin = @import("builtin");
const std = @import("std");
const zevent_options = @import("zevent_options");

pub const Backend = blk: {
    if (zevent_options.backend) |backend_name| {
        if (std.mem.eql(u8, backend_name, "epoll")) {
            break :blk @import("backends/epoll.zig");
        } else if (std.mem.eql(u8, backend_name, "poll")) {
            break :blk @import("backends/poll.zig");
        } else {
            @compileError("Unknown backend: " ++ backend_name);
        }
    }

    // Default backend based on OS
    break :blk switch (builtin.os.tag) {
        .linux => @import("backends/epoll.zig"),
        // TODO: implement io_uring, kqueue, iocp
        else => @import("backends/poll.zig"),
    };
};
