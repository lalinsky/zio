const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const c = std.c;

pub const E = c.E;
pub const fd_t = c.fd_t;
pub const mode_t = c.mode_t;
pub const uid_t = c.uid_t;
pub const gid_t = c.gid_t;

pub const kinfo_file = c.kinfo_file;
pub const KINFO_FILE_SIZE = c.KINFO_FILE_SIZE;

/// Flags for *at syscalls (openat, fstatat, linkat, etc.)
/// Values are OS-specific, from system fcntl.h headers
pub const AT = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        /// Special value for dirfd: use current working directory
        pub const FDCWD = -2;
        /// Test access using effective user/group ID
        pub const EACCESS: u32 = 0x0010;
        /// Do not follow symbolic links
        pub const SYMLINK_NOFOLLOW: u32 = 0x0020;
        /// Follow symbolic links
        pub const SYMLINK_FOLLOW: u32 = 0x0040;
        /// Remove directory instead of file
        pub const REMOVEDIR: u32 = 0x0080;
    },
    .freebsd => struct {
        /// Special value for dirfd: use current working directory
        pub const FDCWD = -100;
        /// Test access using effective user/group ID
        pub const EACCESS: u32 = 0x0100;
        /// Do not follow symbolic links
        pub const SYMLINK_NOFOLLOW: u32 = 0x0200;
        /// Follow symbolic links
        pub const SYMLINK_FOLLOW: u32 = 0x0400;
        /// Remove directory instead of file
        pub const REMOVEDIR: u32 = 0x0800;
        /// Fail if not under dirfd
        pub const RESOLVE_BENEATH: u32 = 0x2000;
        /// Allow empty relative pathname (operate on dirfd itself)
        pub const EMPTY_PATH: u32 = 0x4000;
    },
    .netbsd => struct {
        /// Special value for dirfd: use current working directory
        pub const FDCWD = -100;
        /// Test access using effective user/group ID
        pub const EACCESS: u32 = 0x100;
        /// Do not follow symbolic links
        pub const SYMLINK_NOFOLLOW: u32 = 0x200;
        /// Follow symbolic links
        pub const SYMLINK_FOLLOW: u32 = 0x400;
        /// Remove directory instead of file
        pub const REMOVEDIR: u32 = 0x800;
    },
    .openbsd => struct {
        /// Special value for dirfd: use current working directory
        pub const FDCWD = -100;
        /// Test access using effective user/group ID
        pub const EACCESS: u32 = 0x01;
        /// Do not follow symbolic links
        pub const SYMLINK_NOFOLLOW: u32 = 0x02;
        /// Follow symbolic links
        pub const SYMLINK_FOLLOW: u32 = 0x04;
        /// Remove directory instead of file
        pub const REMOVEDIR: u32 = 0x08;
    },
    .dragonfly => struct {
        /// Special value for dirfd: use current working directory
        pub const FDCWD = -328243;
        /// Do not follow symbolic links
        pub const SYMLINK_NOFOLLOW: u32 = 1;
        /// Remove directory instead of file
        pub const REMOVEDIR: u32 = 2;
        /// Test access using effective user/group ID
        pub const EACCESS: u32 = 4;
        /// Follow symbolic links
        pub const SYMLINK_FOLLOW: u32 = 8;
    },
    else => struct {},
};

pub fn errno(rc: anytype) E {
    return if (rc == -1) @enumFromInt(c._errno().*) else .SUCCESS;
}

const libc = struct {
    extern "c" fn fchmodat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t, flags: u32) c_int;
    extern "c" fn fchownat(dirfd: fd_t, path: [*:0]const u8, owner: uid_t, group: gid_t, flags: u32) c_int;
    extern "c" fn faccessat(dirfd: fd_t, path: [*:0]const u8, mode: u32, flags: u32) c_int;
    extern "c" fn linkat(oldfd: fd_t, oldpath: [*:0]const u8, newfd: fd_t, newpath: [*:0]const u8, flags: u32) c_int;
};

pub const fchmodat = libc.fchmodat;
pub const fchownat = libc.fchownat;
pub const faccessat = libc.faccessat;
pub const linkat = libc.linkat;
