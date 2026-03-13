const std = @import("std");
const builtin = @import("builtin");

const unexpectedError = @import("base.zig").unexpectedError;

pub const system = switch (builtin.os.tag) {
    .linux => std.os.linux,
    .windows => @import("windows.zig"),
    else => std.c,
};

pub const sys = switch (builtin.os.tag) {
    .linux => @import("system/linux.zig"),
    else => @import("system/c.zig"),
};

pub const O = system.O;
pub const AT = sys.AT;
pub const MAP = sys.MAP;
pub const PROT = sys.PROT;
pub const MADV = sys.MADV;
pub const SS = sys.SS;
pub const MINSIGSTKSZ = sys.MINSIGSTKSZ;
pub const SIGSTKSZ = sys.SIGSTKSZ;
pub const stack_t = sys.stack_t;
pub const fd_t = sys.fd_t;
pub const PATH_MAX = system.PATH_MAX;
pub const SO = system.SO;
pub const SOL = system.SOL;
pub const IPPROTO = struct {
    pub const IP: c_int = 0;
    pub const ICMP: c_int = 1;
    pub const TCP: c_int = 6;
    pub const UDP: c_int = 17;
    pub const IPV6: c_int = 41;
    pub const ICMPV6: c_int = 58;
    pub const RAW: c_int = 255;
};
pub const TCP = system.TCP;

pub const timespec = sys.timespec;
pub const off_t = sys.off_t;

pub const errno = sys.errno;
pub const fchmodat = sys.fchmodat;
pub const fchownat = sys.fchownat;
pub const faccessat = sys.faccessat;
pub const linkat = sys.linkat;
pub const unlinkat = sys.unlinkat;
pub const renameat = sys.renameat;
pub const mkdirat = sys.mkdirat;
pub const utimensat = sys.utimensat;

pub const MprotectError = error{
    AccessDenied,
    OutOfMemory,
    Unexpected,
};

pub fn mprotect(memory: []align(std.heap.page_size_min) u8, prot: u32) MprotectError!void {
    while (true) {
        switch (errno(sys.mprotect(memory.ptr, memory.len, prot))) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOMEM => return error.OutOfMemory,
            else => |err| return unexpectedError(err),
        }
    }
}

pub const MadviseError = error{
    OutOfMemory,
    Unexpected,
};

pub fn madvise(memory: []align(std.heap.page_size_min) u8, advice: u32) MadviseError!void {
    while (true) {
        switch (errno(sys.madvise(memory.ptr, memory.len, advice))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOMEM => return error.OutOfMemory,
            else => |err| return unexpectedError(err),
        }
    }
}

pub const MunmapError = error{
    Unexpected,
};

pub fn munmap(memory: []align(std.heap.page_size_min) u8) MunmapError!void {
    while (true) {
        switch (errno(sys.munmap(memory.ptr, memory.len))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return unexpectedError(err),
        }
    }
}

pub const MmapError = error{
    AccessDenied,
    PermissionDenied,
    LockedMemoryLimitExceeded,
    MemoryMappingNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    OutOfMemory,
    MappingAlreadyExists,
    Unexpected,
};

pub fn mmap(
    ptr: ?[*]align(std.heap.page_size_min) u8,
    len: usize,
    prot: u32,
    flags: u32,
    fd: fd_t,
    offset: u64,
) MmapError![]align(std.heap.page_size_min) u8 {
    while (true) {
        const err = if (builtin.os.tag == .linux) blk: {
            const rc = sys.mmap(ptr, len, prot, flags, fd, @bitCast(offset));
            const e = errno(rc);
            if (e == .SUCCESS) return @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(rc))[0..len];
            break :blk e;
        } else blk: {
            const result = sys.mmap(ptr, len, prot, flags, fd, @intCast(offset));
            if (result != sys.MAP_FAILED) {
                return @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(result)))[0..len];
            }
            break :blk errno(-1);
        };
        switch (err) {
            .INTR => continue,
            .TXTBSY => return error.AccessDenied,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .AGAIN => return error.LockedMemoryLimitExceeded,
            .NODEV => return error.MemoryMappingNotSupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.OutOfMemory,
            .EXIST => return error.MappingAlreadyExists,
            else => return unexpectedError(err),
        }
    }
}

pub const SigaltstackError = error{
    OutOfMemory,
    Unexpected,
};

pub fn sigaltstack(ss: ?*const stack_t, old_ss: ?*stack_t) SigaltstackError!void {
    switch (errno(sys.sigaltstack(ss, old_ss))) {
        .SUCCESS => return,
        .NOMEM => return error.OutOfMemory,
        else => |err| return unexpectedError(err),
    }
}

pub fn setNonblocking(fd: fd_t) error{Unexpected}!void {
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

pub fn setCloexec(fd: fd_t) error{Unexpected}!void {
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

pub fn pipe(flags: PipeFlags) PipeError![2]fd_t {
    switch (system) {
        std.c => {
            // BSD/non-Linux: use pipe() + fcntl()
            var fds: [2]fd_t = undefined;

            switch (errno(system.pipe(&fds))) {
                .SUCCESS => {},
                .FAULT => unreachable,
                .NFILE => return error.SystemFdQuotaExceeded,
                .MFILE => return error.ProcessFdQuotaExceeded,
                else => |err| return unexpectedError(err),
            }
            errdefer {
                close(fds[0]);
                close(fds[1]);
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
            var fds: [2]fd_t = undefined;
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

pub fn close(fd: fd_t) void {
    switch (errno(system.close(fd))) {
        .SUCCESS, .INTR => return,
        .BADF => unreachable, // Invalid fd - would be a bug
        else => return, // Ignore other errors (e.g., EIO)
    }
}

// Signal handling types and functions (non-Windows only)
// These are lazily evaluated and only accessed in non-Windows code paths.
pub const Sigaction = system.Sigaction;
pub const SIG = system.SIG;
pub const SA = system.SA;
pub const siginfo_t = system.siginfo_t;
pub const sigset_t = system.sigset_t;

pub fn sigemptyset() sigset_t {
    return std.mem.zeroes(sigset_t);
}

/// Install a signal handler. sig must be convertible to an integer (e.g. SIG enum or integer).
pub fn sigaction(sig: anytype, act: ?*const Sigaction, oact: ?*Sigaction) void {
    const sig_int: c_int = switch (@typeInfo(@TypeOf(sig))) {
        .int, .comptime_int => @intCast(sig),
        .@"enum" => @intFromEnum(sig),
        else => @compileError("sig must be an integer or enum"),
    };
    if (builtin.os.tag == .linux) {
        _ = system.sigaction(@as(u8, @intCast(sig_int)), act, oact);
    } else {
        _ = system.sigaction(sig_int, act, oact);
    }
}

/// Send a signal to the calling process. sig must be convertible to c_int.
pub fn raise(sig: anytype) !void {
    const sig_int: c_int = switch (@typeInfo(@TypeOf(sig))) {
        .int, .comptime_int => @intCast(sig),
        .@"enum" => @intFromEnum(sig),
        else => @compileError("sig must be an integer or enum"),
    };
    const rc = std.c.raise(sig_int);
    if (rc != 0) return error.Unexpected;
}

pub const EFD = @import("eventfd.zig").EFD;
pub const eventfd = @import("eventfd.zig").eventfd;
pub const eventfd_read = @import("eventfd.zig").eventfd_read;
pub const eventfd_write = @import("eventfd.zig").eventfd_write;
