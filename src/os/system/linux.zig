//! Linux system definitions for syscall wrappers.
//!
//! Values were extracted from:
//! - Zig standard library (lib/std/os/linux.zig, lib/std/os/linux/syscalls.zig)
//! - Linux kernel headers in Zig's bundled libc (lib/libc/include/any-linux-any/)
//!   - asm-generic/signal-defs.h (SS_*, MINSIGSTKSZ, SIGSTKSZ)
//!   - asm-generic/mman-common.h (MAP_*, MADV_*, PROT_*)
//!   - linux/fcntl.h (AT_*)
//!
//! Cross-checked against headers for consistency.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const E = linux.E;
pub const fd_t = linux.fd_t;
pub const mode_t = linux.mode_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;
pub const timespec = linux.timespec;
pub const off_t = linux.off_t;

/// Alternate signal stack flags
/// Values from asm-generic/signal-defs.h
pub const SS = struct {
    pub const ONSTACK: u32 = 1;
    pub const DISABLE: u32 = 2;
    pub const AUTODISARM: u32 = 1 << 31;
};

/// Minimum alternate signal stack size
pub const MINSIGSTKSZ: usize = 2048;
/// Recommended alternate signal stack size
pub const SIGSTKSZ: usize = 8192;

/// Alternate signal stack structure
pub const stack_t = extern struct {
    sp: ?[*]u8,
    flags: u32,
    size: usize,
};

/// Memory mapping flags for mmap
/// Values from asm-generic/mman-common.h
pub const MAP = struct {
    pub const SHARED: u32 = 0x01;
    pub const PRIVATE: u32 = 0x02;
    pub const SHARED_VALIDATE: u32 = 0x03;
    pub const FIXED: u32 = 0x10;
    pub const ANONYMOUS: u32 = 0x20;
    pub const GROWSDOWN: u32 = 0x0100;
    pub const DENYWRITE: u32 = 0x0800;
    pub const EXECUTABLE: u32 = 0x1000;
    pub const LOCKED: u32 = 0x2000;
    pub const NORESERVE: u32 = 0x4000;
    pub const POPULATE: u32 = 0x8000;
    pub const NONBLOCK: u32 = 0x10000;
    pub const STACK: u32 = 0x20000;
    pub const HUGETLB: u32 = 0x40000;
    pub const SYNC: u32 = 0x80000;
    pub const FIXED_NOREPLACE: u32 = 0x100000;
};

/// Memory advice flags for madvise
/// Values from asm-generic/mman-common.h
pub const MADV = struct {
    pub const NORMAL: u32 = 0;
    pub const RANDOM: u32 = 1;
    pub const SEQUENTIAL: u32 = 2;
    pub const WILLNEED: u32 = 3;
    pub const DONTNEED: u32 = 4;
    pub const FREE: u32 = 8;
    pub const REMOVE: u32 = 9;
    pub const DONTFORK: u32 = 10;
    pub const DOFORK: u32 = 11;
    pub const MERGEABLE: u32 = 12;
    pub const UNMERGEABLE: u32 = 13;
    pub const HUGEPAGE: u32 = 14;
    pub const NOHUGEPAGE: u32 = 15;
    pub const DONTDUMP: u32 = 16;
    pub const DODUMP: u32 = 17;
    pub const WIPEONFORK: u32 = 18;
    pub const KEEPONFORK: u32 = 19;
    pub const COLD: u32 = 20;
    pub const PAGEOUT: u32 = 21;
    pub const POPULATE_READ: u32 = 22;
    pub const POPULATE_WRITE: u32 = 23;
};

/// Memory protection flags for mmap/mprotect
/// Values from asm-generic/mman-common.h
pub const PROT = struct {
    /// Page cannot be accessed
    pub const NONE: u32 = 0x0;
    /// Page can be read
    pub const READ: u32 = 0x1;
    /// Page can be written
    pub const WRITE: u32 = 0x2;
    /// Page can be executed
    pub const EXEC: u32 = 0x4;
    /// Page may be used for atomic ops
    pub const SEM: u32 = 0x8;
    /// Extend change to start of growsdown vma (mprotect only)
    pub const GROWSDOWN: u32 = 0x01000000;
    /// Extend change to end of growsup vma (mprotect only)
    pub const GROWSUP: u32 = 0x02000000;
    /// Declare future mprotect permissions (no-op on Linux)
    pub fn MAX(_: u32) u32 {
        return 0;
    }
};

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
    if (flags == 0) {
        return linux.syscall3(
            .faccessat,
            @as(usize, @bitCast(@as(isize, dirfd))),
            @intFromPtr(path),
            mode,
        );
    }
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

pub fn mprotect(addr: [*]const u8, len: usize, prot: u32) usize {
    return linux.syscall3(.mprotect, @intFromPtr(addr), len, prot);
}

pub fn madvise(addr: [*]const u8, len: usize, advice: u32) usize {
    return linux.syscall3(.madvise, @intFromPtr(addr), len, advice);
}

pub fn munmap(addr: [*]const u8, len: usize) usize {
    return linux.syscall2(.munmap, @intFromPtr(addr), len);
}

pub fn mmap(addr: ?[*]u8, len: usize, prot: u32, flags: u32, fd: i32, offset: i64) usize {
    if (@hasField(linux.SYS, "mmap2")) {
        return linux.syscall6(
            .mmap2,
            @intFromPtr(addr),
            len,
            prot,
            flags,
            @bitCast(@as(isize, fd)),
            @truncate(@as(u64, @bitCast(offset)) / std.heap.pageSize()),
        );
    } else {
        return linux.syscall6(
            .mmap,
            @intFromPtr(addr),
            len,
            prot,
            flags,
            @bitCast(@as(isize, fd)),
            @as(u64, @bitCast(offset)),
        );
    }
}

pub fn lseek(fd: i32, offset: off_t, whence: u32) usize {
    if (@sizeOf(usize) == 4) {
        // 32-bit platforms use llseek which returns result via pointer
        var result: u64 = undefined;
        const rc = linux.syscall5(
            .llseek,
            @as(usize, @bitCast(@as(isize, fd))),
            @as(usize, @intCast(@as(u64, @bitCast(offset)) >> 32)), // offset_high
            @as(usize, @intCast(@as(u64, @bitCast(offset)) & 0xFFFFFFFF)), // offset_low
            @intFromPtr(&result),
            whence,
        );
        if (rc == 0) {
            return @truncate(result); // TODO: do not truncate
        } else {
            return @bitCast(@as(isize, -1));
        }
    } else {
        const rc = linux.syscall3(
            .lseek,
            @as(usize, @bitCast(@as(isize, fd))),
            @as(usize, @bitCast(offset)),
            whence,
        );
        return rc;
    }
}

pub fn sigaltstack(ss: ?*const stack_t, old_ss: ?*stack_t) usize {
    return linux.syscall2(.sigaltstack, @intFromPtr(ss), @intFromPtr(old_ss));
}

pub fn utimensat(dirfd: fd_t, path: ?[*:0]const u8, times: ?*const [2]timespec, flags: u32) usize {
    return linux.syscall4(
        .utimensat,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        @intFromPtr(times),
        flags,
    );
}

pub fn unlinkat(dirfd: fd_t, path: [*:0]const u8, flags: u32) usize {
    return linux.syscall3(
        .unlinkat,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        flags,
    );
}

pub fn renameat(oldfd: fd_t, oldpath: [*:0]const u8, newfd: fd_t, newpath: [*:0]const u8) usize {
    return linux.syscall4(
        .renameat,
        @as(usize, @bitCast(@as(isize, oldfd))),
        @intFromPtr(oldpath),
        @as(usize, @bitCast(@as(isize, newfd))),
        @intFromPtr(newpath),
    );
}

pub fn mkdirat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t) usize {
    return linux.syscall3(
        .mkdirat,
        @as(usize, @bitCast(@as(isize, dirfd))),
        @intFromPtr(path),
        mode,
    );
}
