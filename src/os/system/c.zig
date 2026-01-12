const std = @import("std");
const c = std.c;

pub const E = c.E;
pub const fd_t = c.fd_t;
pub const mode_t = c.mode_t;
pub const uid_t = c.uid_t;
pub const gid_t = c.gid_t;

pub const kinfo_file = c.kinfo_file;
pub const KINFO_FILE_SIZE = c.KINFO_FILE_SIZE;

pub fn errno(rc: anytype) E {
    return if (rc == -1) @enumFromInt(c._errno().*) else .SUCCESS;
}

const libc = struct {
    extern "c" fn fchmodat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t, flags: c_uint) c_int;
    extern "c" fn fchownat(dirfd: fd_t, path: [*:0]const u8, owner: uid_t, group: gid_t, flags: c_uint) c_int;
    extern "c" fn faccessat(dirfd: fd_t, path: [*:0]const u8, mode: c_uint, flags: c_uint) c_int;
};

pub fn fchmodat(dirfd: fd_t, path: [*:0]const u8, mode: mode_t) c_int {
    return libc.fchmodat(dirfd, path, mode, 0);
}

pub fn fchownat(dirfd: fd_t, path: [*:0]const u8, owner: uid_t, group: gid_t, flags: u32) c_int {
    return libc.fchownat(dirfd, path, owner, group, @intCast(flags));
}

pub fn faccessat(dirfd: fd_t, path: [*:0]const u8, mode: u32, flags: u32) c_int {
    return libc.faccessat(dirfd, path, @intCast(mode), @intCast(flags));
}
