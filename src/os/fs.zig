const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");

pub const fd_t = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    else => posix.system.fd_t,
};

pub const iovec = @import("base.zig").iovec;
pub const iovec_const = @import("base.zig").iovec_const;

pub const mode_t = std.posix.mode_t;

pub const FileOpenFlags = struct {
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
};

pub const FileOpenError = error{
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    NameTooLong,
    SystemResources,
    FileTooBig,
    IsDir,
    NoSpaceLeft,
    NotDir,
    PathAlreadyExists,
    DeviceBusy,
    FileLocksNotSupported,
    BadPathName,
    InvalidUtf8,
    InvalidWtf8,
    NetworkNotFound,
    ProcessNotFound,
    FileBusy,
    Canceled,
    Unexpected,
};

pub const FileReadError = error{
    AccessDenied,
    WouldBlock,
    InputOutput,
    IsDir,
    BrokenPipe,
    SystemResources,
    NotOpenForReading,
    Canceled,
    Unexpected,
};

pub const FileWriteError = error{
    AccessDenied,
    WouldBlock,
    InputOutput,
    NoSpaceLeft,
    BrokenPipe,
    SystemResources,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    LockViolation,
    Canceled,
    Unexpected,
};

pub const FileCloseError = error{
    Canceled,
    Unexpected,
};

/// Open a file using openat() syscall
pub fn openat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, mode: mode_t, flags: FileOpenFlags) FileOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        // Allocate buffer for UTF-16 conversion
        const path_w = allocator.allocSentinel(u16, path.len, 0) catch return error.SystemResources;
        defer allocator.free(path_w);

        const len = std.unicode.utf8ToUtf16Le(path_w, path) catch return error.InvalidUtf8;
        path_w[len] = 0;

        const access_mask: w.DWORD = w.GENERIC_READ | w.GENERIC_WRITE;
        const creation: w.DWORD = if (flags.create)
            if (flags.exclusive)
                w.CREATE_NEW
            else if (flags.truncate)
                w.CREATE_ALWAYS
            else
                w.OPEN_ALWAYS
        else if (flags.truncate)
            w.TRUNCATE_EXISTING
        else
            w.OPEN_EXISTING;

        const handle = w.kernel32.CreateFileW(
            path_w.ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            creation,
            w.FILE_ATTRIBUTE_NORMAL,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.kernel32.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .ALREADY_EXISTS => error.PathAlreadyExists,
                .FILE_EXISTS => error.PathAlreadyExists,
                else => error.Unexpected,
            };
        }

        return handle;
    }

    var open_flags: posix.system.O = .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    };
    if (flags.create) open_flags.CREAT = true;
    if (flags.truncate) open_flags.TRUNC = true;
    if (flags.append) open_flags.APPEND = true;
    if (flags.exclusive) open_flags.EXCL = true;

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.openat(dir, path_z.ptr, open_flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileOpenError(err),
        }
    }
}

/// Close a file descriptor
pub fn close(fd: fd_t) FileCloseError!void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        _ = w.CloseHandle(fd);
        return;
    }

    while (true) {
        const rc = posix.system.close(fd);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileCloseError(err),
        }
    }
}

/// Read from file at offset using preadv()
pub fn preadv(fd: fd_t, buffers: []iovec, offset: u64) FileReadError!usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        var total_read: usize = 0;
        for (buffers) |buffer| {
            var bytes_read: w.DWORD = undefined;
            var overlapped: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(offset + total_read);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate((offset + total_read) >> 32);

            const success = w.kernel32.ReadFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_read,
                &overlapped,
            );

            if (success == w.FALSE) {
                return switch (w.kernel32.GetLastError()) {
                    .HANDLE_EOF => if (total_read == 0) return 0 else return total_read,
                    .BROKEN_PIPE => error.BrokenPipe,
                    else => error.Unexpected,
                };
            }

            total_read += bytes_read;
            if (bytes_read < buffer.len) break;
        }

        return total_read;
    }

    while (true) {
        const rc = posix.system.preadv(fd, buffers.ptr, @intCast(buffers.len), @intCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileReadError(err),
        }
    }
}

/// Write to file at offset using pwritev()
pub fn pwritev(fd: fd_t, buffers: []const iovec_const, offset: u64) FileWriteError!usize {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        var total_written: usize = 0;
        for (buffers) |buffer| {
            var bytes_written: w.DWORD = undefined;
            var overlapped: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(offset + total_written);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate((offset + total_written) >> 32);

            const success = w.kernel32.WriteFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_written,
                &overlapped,
            );

            if (success == w.FALSE) {
                return switch (w.kernel32.GetLastError()) {
                    .BROKEN_PIPE => error.BrokenPipe,
                    .DISK_FULL => error.NoSpaceLeft,
                    else => error.Unexpected,
                };
            }

            total_written += bytes_written;
            if (bytes_written < buffer.len) break;
        }

        return total_written;
    }

    while (true) {
        const rc = posix.system.pwritev(fd, buffers.ptr, @intCast(buffers.len), @intCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileWriteError(err),
        }
    }
}

pub fn errnoToFileOpenError(errno: posix.system.E) FileOpenError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .FBIG => error.FileTooBig,
        .ISDIR => error.IsDir,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .EXIST => error.PathAlreadyExists,
        .BUSY => error.DeviceBusy,
        .TXTBSY => error.FileBusy,
        .CANCELED => error.Canceled,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

pub fn errnoToFileReadError(errno: posix.system.E) FileReadError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .IO => error.InputOutput,
        .CANCELED => error.Canceled,
        .PIPE => error.BrokenPipe,
        .NOMEM => error.SystemResources,
        .BADF => error.NotOpenForReading,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

pub fn errnoToFileWriteError(errno: posix.system.E) FileWriteError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .CANCELED => error.Canceled,
        .PIPE => error.BrokenPipe,
        .NOMEM => error.SystemResources,
        .BADF => error.NotOpenForWriting,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

pub fn errnoToFileCloseError(errno: posix.system.E) FileCloseError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .CANCELED => error.Canceled,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}
