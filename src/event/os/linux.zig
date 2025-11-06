const std = @import("std");
const posix = std.posix;

/// Create an eventfd for async notifications
pub fn eventfd(initval: u32, flags: u32) !i32 {
    const rc = std.os.linux.eventfd(initval, flags);
    if (rc < 0) {
        return switch (std.os.linux.getErrno(@intCast(-rc))) {
            .INVAL => error.InvalidFlags,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOMEM => error.SystemResources,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    return @intCast(rc);
}

/// Read the eventfd counter (8 bytes)
pub fn eventfd_read(fd: i32) !u64 {
    var value: u64 = undefined;
    const bytes = std.mem.asBytes(&value);
    const n = try posix.read(fd, bytes);
    if (n != 8) return error.UnexpectedReadSize;
    return value;
}

/// Write to the eventfd counter (8 bytes)
pub fn eventfd_write(fd: i32, value: u64) !void {
    const bytes = std.mem.asBytes(&value);
    _ = try posix.write(fd, bytes);
}

/// Eventfd flags
pub const EFD = struct {
    pub const CLOEXEC = std.os.linux.EFD.CLOEXEC;
    pub const NONBLOCK = std.os.linux.EFD.NONBLOCK;
    pub const SEMAPHORE = std.os.linux.EFD.SEMAPHORE;
};
