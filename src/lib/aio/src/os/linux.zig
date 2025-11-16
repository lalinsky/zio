const std = @import("std");
const posix = std.posix;

const unexpectedError = @import("base.zig").unexpectedError;

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
    const linux = std.os.linux;
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

    return switch (linux.E.init(rc)) {
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
