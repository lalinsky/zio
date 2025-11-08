const builtin = @import("builtin");
const std = @import("std");
const options = @import("aio_options");

pub const BackendType = enum {
    poll,
    epoll,
    kqueue,
};

pub const backend = blk: {
    if (options.backend) |backend_name| {
        if (std.mem.eql(u8, backend_name, "epoll")) {
            break :blk BackendType.epoll;
        } else if (std.mem.eql(u8, backend_name, "poll")) {
            break :blk BackendType.poll;
        } else if (std.mem.eql(u8, backend_name, "kqueue")) {
            break :blk BackendType.kqueue;
        } else {
            @compileError("Unknown backend: " ++ backend_name);
        }
    }

    switch (builtin.os.tag) {
        .linux => break :blk BackendType.epoll,
        .macos, .ios, .tvos, .visionos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => break :blk BackendType.kqueue,
        else => break :blk BackendType.poll,
    }
};

pub const Backend = switch (backend) {
    .poll => @import("backends/poll.zig"),
    .epoll => @import("backends/epoll.zig"),
    .kqueue => @import("backends/kqueue.zig"),
};
