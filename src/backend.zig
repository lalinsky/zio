const builtin = @import("builtin");
const std = @import("std");
const options = @import("aio_options");

pub const BackendType = enum {
    poll,
    epoll,
    kqueue,
    io_uring,
    iocp,
};

pub const backend = blk: {
    if (options.backend) |backend_name| {
        if (std.mem.eql(u8, backend_name, "epoll")) {
            break :blk BackendType.epoll;
        } else if (std.mem.eql(u8, backend_name, "poll")) {
            break :blk BackendType.poll;
        } else if (std.mem.eql(u8, backend_name, "kqueue")) {
            break :blk BackendType.kqueue;
        } else if (std.mem.eql(u8, backend_name, "io_uring")) {
            break :blk BackendType.io_uring;
        } else if (std.mem.eql(u8, backend_name, "iocp")) {
            break :blk BackendType.iocp;
        } else {
            @compileError("Unknown backend: " ++ backend_name);
        }
    }

    switch (builtin.os.tag) {
        .linux => break :blk BackendType.io_uring,
        .macos, .ios, .tvos, .visionos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => break :blk BackendType.kqueue,
        .windows => break :blk BackendType.iocp,
        else => break :blk BackendType.poll,
    }
};

pub const Backend = switch (backend) {
    .poll => @import("backends/poll.zig"),
    .epoll => @import("backends/epoll.zig"),
    .kqueue => @import("backends/kqueue.zig"),
    .io_uring => @import("backends/io_uring.zig"),
    .iocp => @import("backends/iocp.zig"),
};
