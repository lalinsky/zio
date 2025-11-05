const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../posix.zig");
const time = @import("../../time.zig");

fn unexpectedWSAError(err: std.os.windows.ws2_32.WinsockError) error{Unexpected} {
    if (posix.unexpected_error_tracing) {
        std.debug.print(
            \\unexpected WSA error: {}
            \\please file a bug report: https://github.com/lalinsky/zio/issues/new
        , .{err});
        std.debug.dumpCurrentStackTrace(null);
    }
    return error.Unexpected;
}

pub const pollfd = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.pollfd,
    else => posix.system.pollfd,
};

pub const nfds_t = switch (builtin.os.tag) {
    .windows => u32,
    else => posix.system.nfds_t,
};

pub const POLL = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.POLL,
    else => posix.system.POLL,
};

pub fn poll(fds: [*]pollfd, nfds: nfds_t, timeout: i32) !usize {
    switch (builtin.os.tag) {
        .windows => {
            // WSAPoll doesn't accept 0 fds, just sleep instead
            if (nfds == 0) {
                time.sleep(timeout);
                return 0;
            }
            while (true) {
                const rc = std.os.windows.ws2_32.WSAPoll(fds, nfds, timeout);
                if (rc >= 0) {
                    return @intCast(rc);
                }
                const err = std.os.windows.ws2_32.WSAGetLastError();
                switch (err) {
                    .WSAEINTR => continue,
                    .WSAEINVAL => return error.SystemResources,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAEFAULT => unreachable,
                    else => return unexpectedWSAError(err),
                }
            }
        },
        else => {
            while (true) {
                const rc = posix.system.poll(fds, nfds, timeout);
                switch (posix.errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .FAULT => unreachable,
                    .INTR => continue,
                    .INVAL => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        },
    }
}
