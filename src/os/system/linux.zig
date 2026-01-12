const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const E = linux.E;
pub const fd_t = linux.fd_t;
pub const mode_t = linux.mode_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;

/// Flags for *at syscalls (openat, fstatat, linkat, etc.)
/// Values from linux/fcntl.h
pub const AT = struct {
    /// Special value for dirfd: use current working directory
    pub const FDCWD = -100;
    /// Do not follow symbolic links
    pub const SYMLINK_NOFOLLOW: u32 = 0x100;
    /// Remove directory instead of file
    pub const REMOVEDIR: u32 = 0x200;
    /// Test access using effective user/group ID
    pub const EACCESS: u32 = 0x200;
    /// Follow symbolic links
    pub const SYMLINK_FOLLOW: u32 = 0x400;
    /// Suppress terminal automount traversal
    pub const NO_AUTOMOUNT: u32 = 0x800;
    /// Allow empty relative pathname (operate on dirfd itself)
    pub const EMPTY_PATH: u32 = 0x1000;
    /// Type of synchronisation required from statx()
    pub const STATX_SYNC_TYPE: u32 = 0x6000;
    /// Do whatever stat() does
    pub const STATX_SYNC_AS_STAT: u32 = 0x0000;
    /// Force the attributes to be sync'd with the server
    pub const STATX_FORCE_SYNC: u32 = 0x2000;
    /// Don't sync attributes with the server
    pub const STATX_DONT_SYNC: u32 = 0x4000;
    /// Apply to the entire subtree
    pub const RECURSIVE: u32 = 0x8000;
};

/// Compatibility wrapper for errno that works on both Zig 0.15 and 0.16.
/// In 0.15, this is `E.init(rc)`. In 0.16+, this is `errno(rc)`.
pub fn errno(rc: usize) E {
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
        return E.init(rc);
    } else {
        return linux.errno(rc);
    }
}

pub fn fchmodat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t, flags: u32) usize {
    if (flags != 0) {
        // fchmodat2 required for flags support (Linux 6.6+)
        return linux.syscall4(
            .fchmodat2,
            @as(usize, @bitCast(@as(isize, dirfd))),
            @intFromPtr(path),
            mode,
            flags,
        );
    }
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

pub fn linkat(oldfd: fd_t, oldpath: [*:0]const u8, newfd: fd_t, newpath: [*:0]const u8, flags: u32) usize {
    return linux.syscall5(
        .linkat,
        @as(usize, @bitCast(@as(isize, oldfd))),
        @intFromPtr(oldpath),
        @as(usize, @bitCast(@as(isize, newfd))),
        @intFromPtr(newpath),
        flags,
    );
}
