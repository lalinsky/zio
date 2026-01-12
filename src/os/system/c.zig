//! BSD/macOS system definitions for libc wrappers.
//!
//! Values were extracted from:
//! - Zig standard library (lib/std/c.zig)
//! - System headers in Zig's bundled libc (lib/libc/include/)
//!   - any-darwin-any/sys/signal.h, sys/mman.h, sys/fcntl.h
//!   - generic-freebsd/sys/signal.h, sys/mman.h, fcntl.h
//!   - generic-netbsd/sys/signal.h, sys/mman.h, fcntl.h
//!   - generic-openbsd/sys/signal.h, sys/mman.h, fcntl.h
//!
//! Cross-checked against headers for consistency. Values vary by OS.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const c = std.c;

pub const timespec = c.timespec;

pub const E = c.E;
pub const fd_t = c.fd_t;
pub const mode_t = c.mode_t;
pub const uid_t = c.uid_t;
pub const gid_t = c.gid_t;

pub const kinfo_file = c.kinfo_file;
pub const KINFO_FILE_SIZE = c.KINFO_FILE_SIZE;

/// Alternate signal stack flags
/// Values from sys/signal.h
pub const SS = struct {
    pub const ONSTACK: u32 = 0x0001;
    pub const DISABLE: u32 = 0x0004;
};

/// Minimum and recommended alternate signal stack sizes
/// Values from sys/signal.h
pub const MINSIGSTKSZ: usize = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 32768,
    .netbsd => 8192,
    .freebsd => 2048, // x86, may vary by arch
    .openbsd => 12288, // 3 * 4096
    else => 2048,
};
pub const SIGSTKSZ: usize = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => 131072,
    .netbsd => MINSIGSTKSZ + 32768,
    .freebsd => MINSIGSTKSZ + 32768,
    .openbsd => MINSIGSTKSZ + 8192,
    else => 8192,
};

/// Alternate signal stack structure
pub const stack_t = switch (native_os) {
    .freebsd, .openbsd => extern struct {
        sp: ?[*]u8,
        size: usize,
        flags: u32,
    },
    else => extern struct {
        sp: ?[*]u8,
        flags: u32,
        size: usize,
    },
};

/// Memory mapping flags for mmap
/// Values from sys/mman.h
pub const MAP = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const FIXED: u32 = 0x0010;
        pub const NORESERVE: u32 = 0x0040;
        pub const HASSEMAPHORE: u32 = 0x0200;
        pub const NOCACHE: u32 = 0x0400;
        pub const JIT: u32 = 0x0800;
        pub const ANONYMOUS: u32 = 0x1000;
    },
    .freebsd => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const FIXED: u32 = 0x0010;
        pub const STACK: u32 = 0x0400;
        pub const NOSYNC: u32 = 0x0800;
        pub const ANONYMOUS: u32 = 0x1000;
        pub const GUARD: u32 = 0x2000;
        pub const EXCL: u32 = 0x4000;
        pub const NOCORE: u32 = 0x20000;
        pub const PREFAULT_READ: u32 = 0x40000;
    },
    .netbsd => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const REMAPDUP: u32 = 0x0004;
        pub const FIXED: u32 = 0x0010;
        pub const RENAME: u32 = 0x0020;
        pub const NORESERVE: u32 = 0x0040;
        pub const INHERIT: u32 = 0x0080;
        pub const HASSEMAPHORE: u32 = 0x0200;
        pub const TRYFIXED: u32 = 0x0400;
        pub const WIRED: u32 = 0x0800;
        pub const ANONYMOUS: u32 = 0x1000;
        pub const STACK: u32 = 0x2000;
    },
    .openbsd => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const FIXED: u32 = 0x0010;
        pub const ANONYMOUS: u32 = 0x1000;
        pub const STACK: u32 = 0x4000;
        pub const CONCEAL: u32 = 0x8000;
    },
    .dragonfly => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const FIXED: u32 = 0x0010;
        pub const RENAME: u32 = 0x0020;
        pub const NORESERVE: u32 = 0x0040;
        pub const INHERIT: u32 = 0x0080;
        pub const NOEXTEND: u32 = 0x0100;
        pub const HASSEMAPHORE: u32 = 0x0200;
        pub const STACK: u32 = 0x0400;
        pub const NOSYNC: u32 = 0x0800;
        pub const ANONYMOUS: u32 = 0x1000;
        pub const VPAGETABLE: u32 = 0x2000;
        pub const TRYFIXED: u32 = 0x10000;
        pub const NOCORE: u32 = 0x20000;
        pub const SIZEALIGN: u32 = 0x40000;
    },
    else => struct {
        pub const SHARED: u32 = 0x0001;
        pub const PRIVATE: u32 = 0x0002;
        pub const FIXED: u32 = 0x0010;
        pub const ANONYMOUS: u32 = 0x1000;
    },
};

/// Memory advice flags for madvise
/// Values from sys/mman.h
pub const MADV = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const NORMAL: u32 = 0;
        pub const RANDOM: u32 = 1;
        pub const SEQUENTIAL: u32 = 2;
        pub const WILLNEED: u32 = 3;
        pub const DONTNEED: u32 = 4;
        pub const FREE: u32 = 5;
        pub const ZERO_WIRED_PAGES: u32 = 6;
        pub const FREE_REUSABLE: u32 = 7;
        pub const FREE_REUSE: u32 = 8;
        pub const CAN_REUSE: u32 = 9;
        pub const PAGEOUT: u32 = 10;
    },
    .freebsd => struct {
        pub const NORMAL: u32 = 0;
        pub const RANDOM: u32 = 1;
        pub const SEQUENTIAL: u32 = 2;
        pub const WILLNEED: u32 = 3;
        pub const DONTNEED: u32 = 4;
        pub const FREE: u32 = 5;
        pub const NOSYNC: u32 = 6;
        pub const AUTOSYNC: u32 = 7;
        pub const NOCORE: u32 = 8;
        pub const CORE: u32 = 9;
        pub const PROTECT: u32 = 10;
    },
    .netbsd, .openbsd => struct {
        pub const NORMAL: u32 = 0;
        pub const RANDOM: u32 = 1;
        pub const SEQUENTIAL: u32 = 2;
        pub const WILLNEED: u32 = 3;
        pub const DONTNEED: u32 = 4;
        pub const SPACEAVAIL: u32 = 5;
        pub const FREE: u32 = 6;
    },
    else => struct {
        pub const NORMAL: u32 = 0;
        pub const RANDOM: u32 = 1;
        pub const SEQUENTIAL: u32 = 2;
        pub const WILLNEED: u32 = 3;
        pub const DONTNEED: u32 = 4;
    },
};

/// Memory protection flags for mmap/mprotect
/// Values from sys/mman.h (consistent across BSD/macOS)
pub const PROT = switch (native_os) {
    .netbsd => struct {
        /// Page cannot be accessed
        pub const NONE: u32 = 0x0;
        /// Page can be read
        pub const READ: u32 = 0x1;
        /// Page can be written
        pub const WRITE: u32 = 0x2;
        /// Page can be executed
        pub const EXEC: u32 = 0x4;
        /// Declare future mprotect permissions (PaX MPROTECT)
        pub fn MPROTECT(prot: u32) u32 {
            return prot << 3;
        }
        pub const MAX = MPROTECT;
    },
    .freebsd => struct {
        /// Page cannot be accessed
        pub const NONE: u32 = 0x0;
        /// Page can be read
        pub const READ: u32 = 0x1;
        /// Page can be written
        pub const WRITE: u32 = 0x2;
        /// Page can be executed
        pub const EXEC: u32 = 0x4;
        /// Declare maximum allowed permissions
        pub fn MAX(prot: u32) u32 {
            return prot << 16;
        }
    },
    else => struct {
        /// Page cannot be accessed
        pub const NONE: u32 = 0x0;
        /// Page can be read
        pub const READ: u32 = 0x1;
        /// Page can be written
        pub const WRITE: u32 = 0x2;
        /// Page can be executed
        pub const EXEC: u32 = 0x4;
        /// Declare future mprotect permissions (no-op on this platform)
        pub fn MAX(_: u32) u32 {
            return 0;
        }
    },
};

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
    extern "c" fn mprotect(addr: [*]const u8, len: usize, prot: u32) c_int;
    extern "c" fn madvise(addr: [*]const u8, len: usize, advice: u32) c_int;
    extern "c" fn munmap(addr: [*]const u8, len: usize) c_int;
    extern "c" fn mmap(addr: ?[*]u8, len: usize, prot: u32, flags: u32, fd: fd_t, offset: c.off_t) ?[*]u8;
    extern "c" fn sigaltstack(ss: ?*const stack_t, old_ss: ?*stack_t) c_int;
    extern "c" fn utimensat(dirfd: fd_t, path: ?[*:0]const u8, times: ?*const [2]timespec, flags: u32) c_int;
};

pub const fchmodat = libc.fchmodat;
pub const fchownat = libc.fchownat;
pub const faccessat = libc.faccessat;
pub const linkat = libc.linkat;
pub const mprotect = libc.mprotect;
pub const madvise = libc.madvise;
pub const munmap = libc.munmap;
pub const mmap = libc.mmap;
pub const sigaltstack = libc.sigaltstack;
pub const utimensat = libc.utimensat;
