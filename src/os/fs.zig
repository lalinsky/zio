const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w2 = @import("windows.zig");

const unexpectedError = @import("base.zig").unexpectedError;

pub const fd_t = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    else => posix.system.fd_t,
};

pub const iovec = @import("base.zig").iovec;
pub const iovec_const = @import("base.zig").iovec_const;

pub const mode_t = std.posix.mode_t;
pub const ino_t = std.posix.ino_t;

pub const FileKind = enum {
    block_device,
    character_device,
    directory,
    named_pipe,
    sym_link,
    file,
    unix_domain_socket,
    whiteout,
    door,
    event_port,
    unknown,
};

pub const FileStatInfo = struct {
    inode: ino_t,
    size: u64,
    mode: mode_t,
    kind: FileKind,
    /// Access time in nanoseconds since Unix epoch
    atime: i64,
    /// Modification time in nanoseconds since Unix epoch
    mtime: i64,
    /// Change time (POSIX) / Creation time (Windows) in nanoseconds since Unix epoch
    ctime: i64,
};

pub const FileOpenMode = enum {
    read_only,
    write_only,
    read_write,
};

pub const FileOpenFlags = struct {
    mode: FileOpenMode = .read_only,
    nonblocking: bool = false,
};

pub const FileCreateFlags = struct {
    read: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    mode: mode_t = 0o664,
    nonblocking: bool = false,
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

pub const FileSizeError = error{
    AccessDenied,
    InvalidFileDescriptor,
    Canceled,
    Unexpected,
};

pub const FileStatError = error{
    AccessDenied,
    InvalidFileDescriptor,
    FileNotFound,
    NameTooLong,
    NotDir,
    SymLinkLoop,
    SystemResources,
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

        const file_flags: w.DWORD = if (flags.nonblocking)
            w.FILE_ATTRIBUTE_NORMAL | w.FILE_FLAG_OVERLAPPED
        else
            w.FILE_ATTRIBUTE_NORMAL;

        const handle = w2.CreateFileW(
            path_w.span().ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            file_flags,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w2.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| return unexpectedError(err),
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

        const file_flags: w.DWORD = if (flags.nonblocking)
            w.FILE_ATTRIBUTE_NORMAL | w.FILE_FLAG_OVERLAPPED
        else
            w.FILE_ATTRIBUTE_NORMAL;

        const handle = w2.CreateFileW(
            path_w.span().ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            creation,
            file_flags,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w2.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .ALREADY_EXISTS => error.PathAlreadyExists,
                .FILE_EXISTS => error.PathAlreadyExists,
                else => |err| return unexpectedError(err),
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

            const success = w2.ReadFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_read,
                &overlapped,
            );

            if (success == w.FALSE) {
                const err = w2.GetLastError();
                switch (err) {
                    .HANDLE_EOF => return if (total_read == 0) 0 else total_read,
                    else => return errnoToFileReadError(err),
                }
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

            const success = w2.WriteFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_written,
                &overlapped,
            );

            if (success == w.FALSE) {
                return errnoToFileWriteError(w2.GetLastError());
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

        const success = w2.FlushFileBuffers(fd);
        if (success == w.FALSE) {
            switch (w2.GetLastError()) {
                .ACCESS_DENIED => return error.NotOpenForWriting,
                .INVALID_HANDLE => return error.InvalidFileDescriptor,
                else => |err| return unexpectedError(err),
            }
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

        const success = w2.MoveFileExW(
            old_path_w.span().ptr,
            new_path_w.span().ptr,
            w2.MOVEFILE_REPLACE_EXISTING,
        );

        if (success == w.FALSE) {
            switch (w2.GetLastError()) {
                .FILE_NOT_FOUND => return error.FileNotFound,
                .PATH_NOT_FOUND => return error.FileNotFound,
                .ACCESS_DENIED => return error.AccessDenied,
                .ALREADY_EXISTS => return error.PathAlreadyExists,
                .SHARING_VIOLATION => return error.FileBusy,
                else => |err| return unexpectedError(err),
            }
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

        w.DeleteFile(path_w.span(), .{ .dir = dir, .remove_dir = false }) catch |e| {
            return switch (e) {
                error.FileNotFound => error.FileNotFound,
                error.AccessDenied => error.AccessDenied,
                error.FileBusy => error.FileBusy,
                error.IsDir => error.IsDir,
                error.NameTooLong => error.NameTooLong,
                error.NotDir => error.NotDir,
                error.NetworkNotFound => error.FileNotFound,
                error.DirNotEmpty => error.DirNotEmpty,
                error.Unexpected => error.Unexpected,
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
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const E = if (builtin.os.tag == .windows) std.os.windows.Win32Error else posix.system.E;

pub fn errnoToFileReadError(err: E) FileReadError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .SUCCESS => unreachable,
                .INVALID_HANDLE => error.NotOpenForReading,
                .ACCESS_DENIED => error.AccessDenied,
                .BROKEN_PIPE => error.BrokenPipe,
                .IO_INCOMPLETE, .IO_PENDING => error.WouldBlock,
                .HANDLE_EOF => error.InputOutput,
                .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
        else => {
            return switch (err) {
                .SUCCESS => unreachable,
                .ACCES => error.AccessDenied,
                .AGAIN => error.WouldBlock,
                .IO => error.InputOutput,
                .CANCELED => error.Canceled,
                .PIPE => error.BrokenPipe,
                .NOMEM => error.SystemResources,
                .BADF => error.NotOpenForReading,
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
    }
}

pub fn errnoToFileWriteError(err: E) FileWriteError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (err) {
                .SUCCESS => unreachable,
                .INVALID_HANDLE => error.NotOpenForWriting,
                .ACCESS_DENIED => error.AccessDenied,
                .BROKEN_PIPE => error.BrokenPipe,
                .IO_INCOMPLETE, .IO_PENDING => error.WouldBlock,
                .DISK_FULL, .HANDLE_DISK_FULL => error.NoSpaceLeft,
                .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
        else => {
            return switch (err) {
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
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
    }
}

pub fn errnoToFileCloseError(errno: posix.system.E) FileCloseError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
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
        else => |e| unexpectedError(e) catch error.Unexpected,
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
        else => |e| unexpectedError(e) catch error.Unexpected,
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
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Get the size of a file
pub fn fsize(fd: fd_t) FileSizeError!u64 {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        var file_size: w.LARGE_INTEGER = undefined;
        const success = w2.GetFileSizeEx(fd, &file_size);

        if (success == w.FALSE) {
            switch (w2.GetLastError()) {
                .INVALID_HANDLE => return error.InvalidFileDescriptor,
                .ACCESS_DENIED => return error.AccessDenied,
                else => |err| return unexpectedError(err) catch error.Unexpected,
            }
        }

        return @intCast(file_size);
    }

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        while (true) {
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX_SIZE, &statx_buf);
            switch (posix.errno(rc)) {
                .SUCCESS => return statx_buf.size,
                .INTR => continue,
                else => |err| return errnoToFileSizeError(err),
            }
        }
    }

    while (true) {
        var stat_buf: posix.system.Stat = undefined;
        const rc = posix.system.fstat(fd, &stat_buf);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(stat_buf.size),
            .INTR => continue,
            else => |err| return errnoToFileSizeError(err),
        }
    }
}

pub fn errnoToFileSizeError(errno: posix.system.E) FileSizeError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .BADF => error.InvalidFileDescriptor,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Get file metadata by file descriptor
pub fn fstat(fd: fd_t) FileStatError!FileStatInfo {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        var info: w2.BY_HANDLE_FILE_INFORMATION = undefined;
        const success = w2.GetFileInformationByHandle(fd, &info);

        if (success == w.FALSE) {
            switch (w2.GetLastError()) {
                .INVALID_HANDLE => return error.InvalidFileDescriptor,
                .ACCESS_DENIED => return error.AccessDenied,
                else => |err| return unexpectedError(err) catch error.Unexpected,
            }
        }

        const size: u64 = (@as(u64, info.nFileSizeHigh) << 32) | info.nFileSizeLow;
        const inode: ino_t = @bitCast((@as(u64, info.nFileIndexHigh) << 32) | info.nFileIndexLow);

        const kind: FileKind = if (info.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY != 0)
            .directory
        else if (info.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0)
            .sym_link
        else
            .file;

        return .{
            .inode = inode,
            .size = size,
            .mode = 0, // Windows doesn't have POSIX modes
            .kind = kind,
            .atime = w2.fileTimeToNanos(info.ftLastAccessTime),
            .mtime = w2.fileTimeToNanos(info.ftLastWriteTime),
            .ctime = w2.fileTimeToNanos(info.ftCreationTime),
        };
    }

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO |
            linux.STATX_SIZE | linux.STATX_ATIME | linux.STATX_MTIME |
            linux.STATX_CTIME;
        var statx_buf: linux.Statx = undefined;
        while (true) {
            const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &statx_buf);
            switch (posix.errno(rc)) {
                .SUCCESS => return statxToFileStat(statx_buf),
                .INTR => continue,
                else => |err| return errnoToFileStatError(err),
            }
        }
    }

    while (true) {
        var stat_buf: posix.system.Stat = undefined;
        const rc = posix.system.fstat(fd, &stat_buf);
        switch (posix.errno(rc)) {
            .SUCCESS => return statToFileStat(stat_buf),
            .INTR => continue,
            else => |err| return errnoToFileStatError(err),
        }
    }
}

/// Get file metadata by path relative to directory
pub fn fstatat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8) FileStatError!FileStatInfo {
    if (builtin.os.tag == .windows) {
        // On Windows, we need to open the file first, then stat it
        const w = std.os.windows;

        const path_w = w.sliceToPrefixedFileW(dir, path) catch |err| return switch (err) {
            error.InvalidWtf8 => error.Unexpected,
            error.AccessDenied => error.AccessDenied,
            error.BadPathName => error.FileNotFound,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.Unexpected => error.Unexpected,
        };

        // Open with minimal access just to query attributes
        const handle = w2.CreateFileW(
            path_w.span().ptr,
            0, // No access needed, just want to query attributes
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            w.FILE_FLAG_BACKUP_SEMANTICS, // Required to open directories
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w2.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| return unexpectedError(err) catch error.Unexpected,
            };
        }
        defer _ = w.CloseHandle(handle);

        return fstat(handle);
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const mask = linux.STATX_TYPE | linux.STATX_MODE | linux.STATX_INO |
            linux.STATX_SIZE | linux.STATX_ATIME | linux.STATX_MTIME |
            linux.STATX_CTIME;
        var statx_buf: linux.Statx = undefined;
        while (true) {
            const rc = linux.statx(dir, path_z.ptr, 0, mask, &statx_buf);
            switch (posix.errno(rc)) {
                .SUCCESS => return statxToFileStat(statx_buf),
                .INTR => continue,
                else => |err| return errnoToFileStatError(err),
            }
        }
    }

    while (true) {
        var stat_buf: posix.system.Stat = undefined;
        const rc = posix.system.fstatat(dir, path_z.ptr, &stat_buf, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return statToFileStat(stat_buf),
            .INTR => continue,
            else => |err| return errnoToFileStatError(err),
        }
    }
}

fn statToFileStat(stat_buf: posix.system.Stat) FileStatInfo {
    const S = posix.system.S;
    const kind: FileKind = switch (stat_buf.mode & S.IFMT) {
        S.IFBLK => .block_device,
        S.IFCHR => .character_device,
        S.IFDIR => .directory,
        S.IFIFO => .named_pipe,
        S.IFLNK => .sym_link,
        S.IFREG => .file,
        S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };

    return .{
        .inode = stat_buf.ino,
        .size = @intCast(stat_buf.size),
        .mode = stat_buf.mode,
        .kind = kind,
        .atime = timespecToNanos(stat_buf.atime()),
        .mtime = timespecToNanos(stat_buf.mtime()),
        .ctime = timespecToNanos(stat_buf.ctime()),
    };
}

fn timespecToNanos(ts: posix.system.timespec) i64 {
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn statxToFileStat(statx_buf: std.os.linux.Statx) FileStatInfo {
    const S = std.os.linux.S;
    const kind: FileKind = switch (statx_buf.mode & S.IFMT) {
        S.IFBLK => .block_device,
        S.IFCHR => .character_device,
        S.IFDIR => .directory,
        S.IFIFO => .named_pipe,
        S.IFLNK => .sym_link,
        S.IFREG => .file,
        S.IFSOCK => .unix_domain_socket,
        else => .unknown,
    };

    return .{
        .inode = statx_buf.ino,
        .size = statx_buf.size,
        .mode = statx_buf.mode,
        .kind = kind,
        .atime = statxTimeToNanos(statx_buf.atime),
        .mtime = statxTimeToNanos(statx_buf.mtime),
        .ctime = statxTimeToNanos(statx_buf.ctime),
    };
}

fn statxTimeToNanos(ts: std.os.linux.statx_timestamp) i64 {
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn errnoToFileStatError(errno: posix.system.E) FileStatError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .BADF => error.InvalidFileDescriptor,
        .NOENT => error.FileNotFound,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}
