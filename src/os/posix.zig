const std = @import("std");
const builtin = @import("builtin");

pub const system = switch (builtin.os.tag) {
    .linux => std.os.linux,
    else => std.c,
};

pub const O = system.O;

pub const unexpected_error_tracing = builtin.mode == .Debug and switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_x86_64 => true,
    else => false,
};

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

pub fn unexpectedErrno(err: system.E) error{Unexpected} {
    if (unexpected_error_tracing) {
        std.debug.print(
            \\unexpected errno: {d}
            \\please file a bug report: https://github.com/lalinsky/aio.zig/issues/new
            \\
        , .{@intFromEnum(err)});
        std.debug.dumpCurrentStackTrace(null);
    }
    return error.Unexpected;
}

pub fn setNonblocking(fd: std.posix.fd_t) error{Unexpected}!void {
    const fl_flags = system.fcntl(fd, system.F.GETFL, @as(c_int, 0));
    switch (errno(fl_flags)) {
        .SUCCESS => {},
        .BADF => unreachable, // Invalid fd
        .FAULT => unreachable, // Invalid address
        else => |err| return unexpectedErrno(err),
    }

    const new_flags = fl_flags | (@as(c_int, 1) << @bitOffsetOf(O, "NONBLOCK"));
    switch (errno(system.fcntl(fd, system.F.SETFL, new_flags))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn setCloexec(fd: std.posix.fd_t) error{Unexpected}!void {
    switch (errno(system.fcntl(fd, system.F.SETFD, @as(c_int, system.FD_CLOEXEC)))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
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
                else => |err| return unexpectedErrno(err),
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
                else => |err| return unexpectedErrno(err),
            }
        },
        else => @compileError("unsupported OS"),
    }
}

pub const EFD = @import("eventfd.zig").EFD;
pub const eventfd = @import("eventfd.zig").eventfd;
pub const eventfd_read = @import("eventfd.zig").eventfd_read;
pub const eventfd_write = @import("eventfd.zig").eventfd_write;
