const std = @import("std");
const builtin = @import("builtin");

pub const iovec = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.WSABUF,
    else => std.posix.iovec,
};

pub const iovec_const = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.WSABUF,
    else => std.posix.iovec_const,
};
