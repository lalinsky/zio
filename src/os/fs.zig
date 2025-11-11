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

pub const FileOpenMode = enum {
    read_only,
    write_only,
    read_write,
};

pub const FileOpenFlags = struct {
    mode: FileOpenMode = .read_only,
};

pub const FileCreateFlags = struct {
    read: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    mode: mode_t = 0o664,
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

pub const FileSyncFlags = struct {
    only_data: bool = false,
};

pub const FileSyncError = error{
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    ReadOnlyFileSystem,
    InvalidFileDescriptor,
    NotOpenForWriting,
    Canceled,
    Unexpected,
};

pub const FileRenameError = error{
    AccessDenied,
    FileBusy,
    DiskQuota,
    IsDir,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    PathAlreadyExists,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NotSameFileSystem,
    DirNotEmpty,
    InvalidUtf8,
    Canceled,
    Unexpected,
};

pub const FileDeleteError = error{
    AccessDenied,
    FileBusy,
    FileNotFound,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,
    DirNotEmpty,
    InvalidUtf8,
    Canceled,
    Unexpected,
};

/// Open an existing file using openat() syscall
pub fn openat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: FileOpenFlags) FileOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        // Convert path to UTF-16 with proper prefixing and directory handling
        const path_w = w.sliceToPrefixedFileW(dir, path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.InvalidUtf8,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.BadPathName,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };

        const access_mask: w.DWORD = switch (flags.mode) {
            .read_only => w.GENERIC_READ,
            .write_only => w.GENERIC_WRITE,
            .read_write => w.GENERIC_READ | w.GENERIC_WRITE,
        };

        const handle = w.kernel32.CreateFileW(
            path_w.span().ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            w.FILE_ATTRIBUTE_NORMAL,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.kernel32.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                else => error.Unexpected,
            };
        }

        return handle;
    }

    const open_flags: posix.system.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .CLOEXEC = true,
    };

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.openat(dir, path_z.ptr, open_flags, @as(mode_t, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileOpenError(err),
        }
    }
}

/// Create a file using openat() syscall
pub fn createat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: FileCreateFlags) FileOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        // Convert path to UTF-16 with proper prefixing and directory handling
        const path_w = w.sliceToPrefixedFileW(dir, path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.InvalidUtf8,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.BadPathName,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };

        const access_mask: w.DWORD = if (flags.read)
            w.GENERIC_READ | w.GENERIC_WRITE
        else
            w.GENERIC_WRITE;

        const creation: w.DWORD = if (flags.exclusive)
            w.CREATE_NEW
        else if (flags.truncate)
            w.CREATE_ALWAYS
        else
            w.OPEN_ALWAYS;

        const handle = w.kernel32.CreateFileW(
            path_w.span().ptr,
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
        .ACCMODE = if (flags.read) .RDWR else .WRONLY,
        .CLOEXEC = true,
        .CREAT = true,
    };
    if (flags.truncate) open_flags.TRUNC = true;
    if (flags.exclusive) open_flags.EXCL = true;

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.openat(dir, path_z.ptr, open_flags, flags.mode);
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

/// Sync file data to disk
pub fn sync(fd: fd_t, flags: FileSyncFlags) FileSyncError!void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        const success = w.kernel32.FlushFileBuffers(fd);
        if (success == w.FALSE) {
            return switch (w.kernel32.GetLastError()) {
                .ACCESS_DENIED => error.NotOpenForWriting,
                .INVALID_HANDLE => error.InvalidFileDescriptor,
                else => error.Unexpected,
            };
        }
        return;
    }

    while (true) {
        const rc = if (flags.only_data)
            posix.system.fdatasync(fd)
        else
            posix.system.fsync(fd);

        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSyncError(err),
        }
    }
}

/// Rename a file using renameat() syscall
pub fn renameat(allocator: std.mem.Allocator, old_dir: fd_t, old_path: []const u8, new_dir: fd_t, new_path: []const u8) FileRenameError!void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        // Convert paths to UTF-16 with proper prefixing and directory handling
        const old_path_w = w.sliceToPrefixedFileW(old_dir, old_path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.InvalidUtf8,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.FileNotFound,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };
        const new_path_w = w.sliceToPrefixedFileW(new_dir, new_path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.InvalidUtf8,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.FileNotFound,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };

        const success = w.kernel32.MoveFileExW(
            old_path_w.span().ptr,
            new_path_w.span().ptr,
            w.MOVEFILE_REPLACE_EXISTING,
        );

        if (success == w.FALSE) {
            return switch (w.kernel32.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .ALREADY_EXISTS => error.PathAlreadyExists,
                .SHARING_VIOLATION => error.FileBusy,
                else => error.Unexpected,
            };
        }

        return;
    }

    const old_path_z = allocator.dupeZ(u8, old_path) catch return error.SystemResources;
    defer allocator.free(old_path_z);
    const new_path_z = allocator.dupeZ(u8, new_path) catch return error.SystemResources;
    defer allocator.free(new_path_z);

    while (true) {
        const rc = posix.system.renameat(old_dir, old_path_z.ptr, new_dir, new_path_z.ptr);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileRenameError(err),
        }
    }
}

/// Delete a file using unlinkat() syscall
pub fn unlinkat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8) FileDeleteError!void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        // Convert path to UTF-16 with proper prefixing and directory handling
        const path_w = w.sliceToPrefixedFileW(dir, path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.InvalidUtf8,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.FileNotFound,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };

        w.DeleteFile(path_w.span(), .{ .dir = dir, .remove_dir = false }) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.AccessDenied,
                error.FileBusy => error.FileBusy,
                error.IsDir => error.IsDir,
                error.NameTooLong => error.NameTooLong,
                error.NotDir => error.NotDir,
                error.NetworkNotFound => error.FileNotFound,
                error.DirNotEmpty => error.DirNotEmpty,
                else => error.Unexpected,
            };
        };

        return;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.unlinkat(dir, path_z.ptr, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileDeleteError(err),
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

pub fn errnoToFileSyncError(errno: posix.system.E) FileSyncError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .ROFS => error.ReadOnlyFileSystem,
        .BADF => error.InvalidFileDescriptor,
        .INVAL => error.NotOpenForWriting,
        .CANCELED => error.Canceled,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

pub fn errnoToFileRenameError(errno: posix.system.E) FileRenameError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.AccessDenied,
        .BUSY => error.FileBusy,
        .DQUOT => error.DiskQuota,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .EXIST => error.PathAlreadyExists,
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .XDEV => error.NotSameFileSystem,
        .NOTEMPTY => error.DirNotEmpty,
        .CANCELED => error.Canceled,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

pub fn errnoToFileDeleteError(errno: posix.system.E) FileDeleteError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.AccessDenied,
        .BUSY => error.FileBusy,
        .NOENT => error.FileNotFound,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        .NOTEMPTY => error.DirNotEmpty,
        .CANCELED => error.Canceled,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}
