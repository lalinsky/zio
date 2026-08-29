const builtin = @import("builtin");
const std = @import("std");
const zio_options = @import("../options.zig").options;

pub const BackendType = @import("../options.zig").BackendType;

pub const backend: BackendType = zio_options.backend orelse switch (builtin.os.tag) {
    .linux => .linux,
    .macos, .ios, .tvos, .visionos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => .kqueue,
    .windows => .iocp,
    else => .poll,
};

pub const Backend = switch (backend) {
    .poll => @import("backends/poll.zig"),
    .linux => @import("backends/linux.zig").Backend(.auto),
    .epoll => @import("backends/linux.zig").Backend(.epoll),
    .kqueue => @import("backends/kqueue.zig"),
    .io_uring => @import("backends/linux.zig").Backend(.io_uring),
    .iocp => @import("backends/iocp.zig"),
};
