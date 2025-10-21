const std = @import("std");
const builtin = @import("builtin");

const is_zig_0_15 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) == .lt;

pub const Io = if (is_zig_0_15) struct { userdata: ?*anyopaque } else std.Io;
