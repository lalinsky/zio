const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const linux = @import("linux.zig");

const unexpectedError = @import("base.zig").unexpectedError;

pub const EFD = switch (builtin.os.tag) {
    .linux => std.os.linux.EFD,
    .freebsd => struct {
        // from generic-freebsd/sys/eventfd.h
        pub const SEMAPHORE = 0x00000001;
        pub const CLOEXEC = 0x00000004;
        pub const NONBLOCK = 0x00100000;
    },
    .netbsd => struct {
        // from generic-netbsd/sys/eventfd.h
        pub const SEMAPHORE = 1 << @bitOffsetOf(std.c.O, "RDWR");
        pub const CLOEXEC = 1 << @bitOffsetOf(std.c.O, "CLOEXEC");
        pub const NONBLOCK = 1 << @bitOffsetOf(std.c.O, "NONBLOCK");
    },
    else => {},
};

const c = switch (builtin.os.tag) {
    .freebsd, .netbsd => struct {
        extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
        extern "c" fn eventfd_read(fd: c_int, value: *c_ulonglong) c_int;
        extern "c" fn eventfd_write(fd: c_int, value: c_ulonglong) c_int;
    },
    else => {},
};

/// Create an eventfd for async notifications.
///
/// Supported on Linux, FreeBSD, and NetBSD.
pub fn eventfd(initval: u32, flags: u32) !i32 {
    switch (builtin.os.tag) {
        .linux => {
            while (true) {
                const rc = std.os.linux.eventfd(initval, flags);
                switch (linux.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .INVAL => return error.InvalidFlags,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    else => |err| return unexpectedError(err),
                }
            }
        },
        .freebsd, .netbsd => {
            while (true) {
                const rc = c.eventfd(initval, @intCast(flags));
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .INVAL => return error.InvalidFlags,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    else => |err| return unexpectedError(err),
                }
            }
        },
        else => @panic("Unsupported OS"),
    }
}

/// Read the eventfd counter (8 bytes)
pub fn eventfd_read(fd: i32) !u64 {
    var value: u64 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const bytes = std.mem.asBytes(&value);
            while (true) {
                const rc = std.os.linux.read(fd, bytes.ptr, bytes.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        std.debug.assert(rc == 8);
                        return value;
                    },
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    else => |err| std.debug.panic("eventfd_read: read failed: {}", .{err}),
                }
            }
        },
        .freebsd, .netbsd => {
            while (true) {
                const rc = c.eventfd_read(fd, &value);
                switch (posix.errno(rc)) {
                    .SUCCESS => return value,
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    else => |err| std.debug.panic("eventfd_read: read failed: {}", .{err}),
                }
            }
        },
        else => @panic("Unsupported OS"),
    }
}

/// Write to the eventfd counter (8 bytes)
pub fn eventfd_write(fd: i32, value: u64) !void {
    const bytes = std.mem.asBytes(&value);
    switch (builtin.os.tag) {
        .linux => {
            while (true) {
                const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        std.debug.assert(rc == 8);
                        break;
                    },
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    else => |err| std.debug.panic("eventfd_write: write failed: {}", .{err}),
                }
            }
        },
        .freebsd, .netbsd => {
            while (true) {
                const rc = c.eventfd_write(fd, value);
                switch (posix.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    else => |err| std.debug.panic("eventfd_write: write failed: {}", .{err}),
                }
            }
        },
        else => @panic("Unsupported OS"),
    }
}

test "eventfd: create/read/write" {
    switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd => {},
        else => return error.SkipZigTest,
    }

    const fd = try eventfd(0, EFD.CLOEXEC | EFD.NONBLOCK);
    defer _ = posix.system.close(fd);

    try eventfd_write(fd, 1);
    try eventfd_write(fd, 1);
    try eventfd_write(fd, 1);

    const val = try eventfd_read(fd);
    try std.testing.expectEqual(3, val);

    try std.testing.expectError(error.WouldBlock, eventfd_read(fd));

    try eventfd_write(fd, 1);

    const val2 = try eventfd_read(fd);
    try std.testing.expectEqual(1, val2);
}
