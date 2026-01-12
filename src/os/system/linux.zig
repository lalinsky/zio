const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const E = linux.E;
pub const fd_t = linux.fd_t;
pub const mode_t = linux.mode_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;

/// Compatibility wrapper for errno that works on both Zig 0.15 and 0.16.
/// In 0.15, this is `E.init(rc)`. In 0.16+, this is `errno(rc)`.
pub fn errno(rc: usize) E {
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
        return E.init(rc);
    } else {
        return linux.errno(rc);
    }
}

pub fn fchmodat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t) usize {
    return linux.syscall3(
        .fchmodat,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        mode,
    );
}

pub fn fchownat(dirfd: fd_t, path: [*:0]const u8, owner: uid_t, group: gid_t, flags: u32) usize {
    return linux.syscall5(
        .fchownat,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        owner,
        group,
        flags,
    );
}

pub fn faccessat(dirfd: fd_t, path: [*:0]const u8, mode: u32, flags: u32) usize {
    return linux.syscall4(
        .faccessat2,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        mode,
        flags,
    );
}
