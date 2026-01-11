const std = @import("std");
const builtin = @import("builtin");

const unexpectedError = @import("base.zig").unexpectedError;

pub const system = switch (builtin.os.tag) {
    .linux => std.os.linux,
    .windows => @import("windows.zig"),
    else => std.c,
};

pub const O = system.O;
pub const AT = system.AT;

pub fn errno(rc: anytype) system.E {
    switch (system) {
        std.c => {
            return if (rc == -1) @enumFromInt(system._errno().*) else .SUCCESS;
        },
        std.os.linux => {
            const signed: isize = @bitCast(rc);
            const int = if (signed > -4096 and signed < 0) -signed else 0;
            return @enumFromInt(int);
        },
        else => @compileError("unsupported OS"),
    }
}

pub fn setNonblocking(fd: std.posix.fd_t) error{Unexpected}!void {
    const fl_flags = system.fcntl(fd, system.F.GETFL, @as(c_int, 0));
    switch (errno(fl_flags)) {
        .SUCCESS => {},
        .BADF => unreachable, // Invalid fd
        .FAULT => unreachable, // Invalid address
        else => |err| return unexpectedError(err),
    }

    const new_flags = fl_flags | (@as(c_int, 1) << @bitOffsetOf(O, "NONBLOCK"));
    switch (errno(system.fcntl(fd, system.F.SETFL, new_flags))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        else => |err| return unexpectedError(err),
    }
}

pub fn setCloexec(fd: std.posix.fd_t) error{Unexpected}!void {
    switch (errno(system.fcntl(fd, system.F.SETFD, @as(c_int, system.FD_CLOEXEC)))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        else => |err| return unexpectedError(err),
    }
}

pub const PipeFlags = packed struct {
    nonblocking: bool = false,
    cloexec: bool = true,
};

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    Unexpected,
};

pub fn pipe(flags: PipeFlags) PipeError![2]std.posix.fd_t {
    switch (system) {
        std.c => {
            // BSD/non-Linux: use pipe() + fcntl()
            var fds: [2]std.posix.fd_t = undefined;

            switch (errno(system.pipe(&fds))) {
                .SUCCESS => {},
                .FAULT => unreachable,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => |err| return unexpectedError(err),
            }
            errdefer {
                std.posix.close(fds[0]);
                std.posix.close(fds[1]);
            }

            // Set flags using fcntl
            if (flags.nonblocking) {
                try setNonblocking(fds[0]);
                try setNonblocking(fds[1]);
            }
            if (flags.cloexec) {
                try setCloexec(fds[0]);
                try setCloexec(fds[1]);
            }

            return fds;
        },
        std.os.linux => {
            var fds: [2]std.posix.fd_t = undefined;
            const pipe_flags: std.os.linux.O = .{
                .NONBLOCK = flags.nonblocking,
                .CLOEXEC = flags.cloexec,
            };

            switch (errno(system.pipe2(&fds, pipe_flags))) {
                .SUCCESS => return fds,
                .FAULT => unreachable,
                .INVAL => unreachable, // Invalid flags - would be a bug
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => |err| return unexpectedError(err),
            }
        },
        else => @compileError("unsupported OS"),
    }
}

pub fn fchownat(dirfd: std.posix.fd_t, path: [*:0]const u8, owner: std.posix.uid_t, group: std.posix.gid_t, flags: u32) usize {
    if (builtin.os.tag == .linux) {
        return std.os.linux.syscall5(
            .fchownat,
            @as(usize, @bitCast(@as(isize, dirfd))),
            @intFromPtr(path),
            owner,
            group,
            flags,
        );
    }
    const libc_fchownat = struct {
        extern "c" fn fchownat(fd: system.fd_t, path: [*:0]const u8, owner: system.uid_t, group: system.gid_t, flag: c_int) c_int;
    }.fchownat;
    const rc = libc_fchownat(dirfd, path, owner, group, @intCast(flags));
    return @bitCast(@as(isize, rc));
}

pub fn fchmodat(dirfd: std.posix.fd_t, path: [*:0]const u8, mode: std.posix.mode_t) usize {
    if (builtin.os.tag == .linux) {
        return system.fchmodat(dirfd, path, mode);
    } else {
        // BSD/macOS: fchmodat takes 4 arguments, pass 0 for flags
        const rc = system.fchmodat(dirfd, path, mode, 0);
        return @bitCast(@as(isize, rc));
    }
}

pub fn faccessat(dirfd: std.posix.fd_t, path: [*:0]const u8, mode: u32, flags: u32) usize {
    if (builtin.os.tag == .linux) {
        return std.os.linux.syscall4(
            .faccessat2,
            @as(usize, @bitCast(@as(isize, dirfd))),
            @intFromPtr(path),
            mode,
            flags,
        );
    }
    const libc_faccessat = struct {
        extern "c" fn faccessat(fd: system.fd_t, path: [*:0]const u8, mode: c_int, flag: c_int) c_int;
    }.faccessat;
    const rc = libc_faccessat(dirfd, path, @intCast(mode), @intCast(flags));
    return @bitCast(@as(isize, rc));
}

pub const EFD = @import("eventfd.zig").EFD;
pub const eventfd = @import("eventfd.zig").eventfd;
pub const eventfd_read = @import("eventfd.zig").eventfd_read;
pub const eventfd_write = @import("eventfd.zig").eventfd_write;
