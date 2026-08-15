const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const log = @import("../log.zig");

pub const iovec = switch (builtin.os.tag) {
    .windows => windows.WSABUF,
    else => std.c.iovec,
};

pub const iovec_const = switch (builtin.os.tag) {
    .windows => windows.WSABUF,
    else => std.c.iovec_const,
};

pub const unexpected_error_tracing = builtin.mode == .Debug and switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_x86_64 => true,
    else => false,
};

/// Error returned by the OS secure-entropy primitive (`getrandom`). Mirrors
/// the failure mode of `std.Io.RandomSecureError` minus cancellation, which is
/// layered on by the async wrapper.
pub const GetRandomError = error{EntropyUnavailable};

pub fn unexpectedError(err: anytype) error{Unexpected} {
    if (unexpected_error_tracing) {
        // Reachable from the loop and from pool workers, so it must not take
        // the stderr lock a parked task can hold. Covers the stack dump too,
        // which writes to stderr as well.
        const region = log.enterSchedulerContext();
        defer log.exitSchedulerContext(region);
        std.debug.print(
            \\unexpected error: {}
            \\please file a bug report: https://github.com/lalinsky/zio/issues/new
            \\
        , .{err});
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
            std.debug.dumpCurrentStackTrace(null);
        } else {
            std.debug.dumpCurrentStackTrace(.{});
        }
    }
    return error.Unexpected;
}
