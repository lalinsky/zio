pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const fs = @import("fs.zig");

pub const posix = @import("posix.zig");
pub const windows = @import("windows.zig");

pub const iovec = fs.iovec;
pub const iovec_const = fs.iovec_const;
pub const iovecFromSlice = net.iovecFromSlice;
pub const iovecConstFromSlice = net.iovecConstFromSlice;
