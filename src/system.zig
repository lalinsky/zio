pub const time = @import("os/time.zig");
pub const net = @import("os/net.zig");
pub const fs = @import("os/fs.zig");

pub const posix = @import("os/posix.zig");

pub const iovec = fs.iovec;
pub const iovec_const = fs.iovec_const;
pub const iovecFromSlice = net.iovecFromSlice;
pub const iovecConstFromSlice = net.iovecConstFromSlice;
