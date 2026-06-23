const std = @import("std");
const builtin = @import("builtin");

pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const fs = @import("fs.zig");
pub const path = std.fs.path;

pub const posix = @import("posix.zig");
pub const windows = @import("windows.zig");
pub const thread = @import("thread.zig");

pub const Mutex = thread.Mutex;
pub const Condition = thread.Condition;
pub const ResetEvent = thread.ResetEvent;

/// Fill `buffer` with cryptographically secure random bytes from the OS.
/// Blocking primitive (raw syscall on the calling thread).
pub const getrandom = if (builtin.os.tag == .windows) windows.getrandom else posix.getrandom;
pub const GetRandomError = @import("base.zig").GetRandomError;

pub const iovec = fs.iovec;
pub const iovec_const = fs.iovec_const;
pub const iovecFromSlice = net.iovecFromSlice;
pub const iovecConstFromSlice = net.iovecConstFromSlice;
pub const timespec = posix.timespec;
