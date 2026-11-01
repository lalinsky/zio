const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const compat = @import("../compat.zig");
const log = @import("../common.zig").log;

pub const iovec = switch (builtin.os.tag) {
    .windows => windows.WSABUF,
    else => std.c.iovec,
};

pub const iovec_const = switch (builtin.os.tag) {
    .windows => windows.WSABUF,
    else => std.c.iovec_const,
};

pub const unexpected_error_tracing = compat.is_debug and switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_x86_64 => true,
    else => false,
};

/// Error returned by the OS secure-entropy primitive (`getrandom`). Mirrors
/// the failure mode of `std.Io.RandomSecureError` minus cancellation, which is
/// layered on by the async wrapper.
pub const GetRandomError = error{EntropyUnavailable};

/// Report an errno, an NTSTATUS or an error value that a caller's switch could
/// not map, and return `error.Unexpected` for it.
///
/// The value is logged in every build mode, so a release build still says which
/// code reached us instead of surfacing a bare `error.Unexpected`. The stack
/// trace stays debug-only: it is what `unexpected_error_tracing` now gates, and
/// it is opt-in because the dump is large.
///
/// A Windows primitive hands us an enum rather than an integer
/// (`WSAGetLastError` returns `WinsockError`, `GetLastError` returns
/// `Win32Error`), and `{}` prints the tag without the raw code it stands for.
/// Those are logged with their backing value as well, so a report says
/// `.EINVAL (10022)` rather than `.EINVAL` alone.
pub fn unexpectedError(err: anytype) error{Unexpected} {
    switch (@typeInfo(@TypeOf(err))) {
        .@"enum" => log.warn("unexpected error: {} ({d}) - please file a bug report: https://github.com/lalinsky/zio/issues/new", .{ err, @backingInt(err) }),
        // An errno already prints as its number; an error value carries no raw
        // code of its own, so its name is all there is to report.
        else => log.warn("unexpected error: {} - please file a bug report: https://github.com/lalinsky/zio/issues/new", .{err}),
    }
    if (unexpected_error_tracing) {
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
            std.debug.dumpCurrentStackTrace(null);
        } else {
            std.debug.dumpCurrentStackTrace(.{});
        }
    }
    return error.Unexpected;
}
