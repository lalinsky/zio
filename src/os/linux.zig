const std = @import("std");
const posix = @import("posix.zig");

const unexpectedError = @import("base.zig").unexpectedError;

const linux = std.os.linux;

/// Futex operation flags
pub const FUTEX_WAIT: u32 = 0;
pub const FUTEX_WAKE: u32 = 1;
pub const FUTEX_PRIVATE_FLAG: u32 = 128;

/// Fast userspace mutex (futex) system call.
///
/// Provides low-level thread synchronization primitives for blocking threads
/// until a condition is met or waking blocked threads.
///
/// Parameters:
/// - `uaddr`: Address of the futex word (must be 32-bit aligned)
/// - `futex_op`: Operation to perform (FUTEX_WAIT, FUTEX_WAKE, etc.)
/// - `val`: Operation-specific value (expected value for WAIT, wake count for WAKE)
/// - `timeout`: Optional timeout for WAIT operations (null for infinite wait)
/// - `uaddr2`: Optional second futex address (used by some operations)
/// - `val3`: Operation-specific value (used by some operations)
///
/// Returns the raw syscall result. Errors are indicated by values > -4096.
/// Caller is responsible for checking and handling errors.
///
/// Common patterns:
/// - FUTEX_WAIT: Block if *uaddr == val, wake on FUTEX_WAKE
/// - FUTEX_WAKE: Wake up to val waiters on uaddr
/// - FUTEX_PRIVATE_FLAG: Optimize for process-private futex (no cross-process wake)
///
/// Note: On newer architectures (e.g., RISC-V 32-bit), the old futex syscall
/// doesn't exist and futex_time64 is used instead.
pub fn futex(uaddr: *const u32, futex_op: u32, val: u32, timeout: ?*const std.posix.timespec, uaddr2: ?*const u32, val3: u32) usize {
    return linux.syscall6(
        if (@hasField(linux.SYS, "futex")) .futex else .futex_time64,
        @intFromPtr(uaddr),
        futex_op,
        val,
        @intFromPtr(timeout),
        @intFromPtr(uaddr2),
        val3,
    );
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

    return switch (posix.errno(rc)) {
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
