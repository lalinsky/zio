const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const unexpectedError = @import("base.zig").unexpectedError;

const linux = std.os.linux;

/// Compatibility wrapper for errno that works on both Zig 0.15 and 0.16.
/// In 0.15, this is `E.init(rc)`. In 0.16+, this is `errno(rc)`.
pub fn errno(rc: usize) linux.E {
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
        return linux.E.init(rc);
    } else {
        return linux.errno(rc);
    }
}

/// Extended arguments for io_uring_enter2 with IORING_ENTER_EXT_ARG
pub const io_uring_getevents_arg = extern struct {
    sigmask: u64 = 0,
    sigmask_sz: u32 = 0,
    pad: u32 = 0,
    ts: u64 = 0,
};

/// io_uring_enter2 syscall (kernel 5.11+)
/// This version supports extended arguments including timeout
pub fn io_uring_enter2(
    fd: i32,
    to_submit: u32,
    min_complete: u32,
    flags: u32,
    arg: ?*const io_uring_getevents_arg,
    argsz: usize,
) !u32 {
    const SYS_io_uring_enter = 426; // syscall number for io_uring_enter2

    const rc = linux.syscall6(
        @enumFromInt(SYS_io_uring_enter),
        @as(usize, @bitCast(@as(isize, fd))),
        to_submit,
        min_complete,
        flags,
        @intFromPtr(arg),
        argsz,
    );

    return switch (errno(rc)) {
        .SUCCESS => @intCast(rc),
        .TIME => 0, // Timeout expired - this is normal, return 0 completions
        .AGAIN => error.WouldBlock,
        .BADF => error.FileDescriptorInvalid,
        .BUSY => error.DeviceBusy,
        .FAULT => error.InvalidAddress,
        .INTR => error.SignalInterrupt,
        .INVAL => error.SubmissionQueueEntryInvalid,
        .OPNOTSUPP => error.OpcodeNotSupported,
        .NOMEM => error.SystemResources,
        else => |err| unexpectedError(err),
    };
}
