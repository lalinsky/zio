const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w = @import("windows.zig");

const unexpectedError = @import("base.zig").unexpectedError;

pub const fd_t = switch (builtin.os.tag) {
    .windows => w.HANDLE,
    else => posix.system.fd_t,
};

/// Returns a file descriptor for the current working directory.
/// Used with *at() functions like openat(), unlinkat(), etc.
pub fn cwd() fd_t {
    if (builtin.os.tag == .windows) {
        return w.FDCWD;
    } else {
        return posix.AT.FDCWD;
    }
}

/// Returns file descriptor for stdin.
pub fn stdin() fd_t {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.peb().ProcessParameters.hStdInput,
        else => std.posix.STDIN_FILENO,
    };
}

/// Returns file descriptor for stdout.
pub fn stdout() fd_t {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.peb().ProcessParameters.hStdOutput,
        else => std.posix.STDOUT_FILENO,
    };
}

/// Returns file descriptor for stderr.
pub fn stderr() fd_t {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.peb().ProcessParameters.hStdError,
        else => std.posix.STDERR_FILENO,
    };
}

pub const PipeError = if (builtin.os.tag == .windows)
    error{Unexpected}
else
    posix.PipeError;

/// Create a pipe for inter-process communication.
/// Returns a pair of file descriptors [read_fd, write_fd].
pub fn pipe() PipeError![2]fd_t {
    return switch (builtin.os.tag) {
        .windows => w.pipe(),
        else => posix.pipe(.{ .nonblocking = true, .cloexec = true }),
    };
}

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

pub const DirOpenFlags = struct {
    /// Whether to follow symlinks when opening the directory
    follow_symlinks: bool = true,
    /// Whether the directory will be iterated (affects O_PATH optimization on Linux)
    iterate: bool = false,
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

pub const DirOpenError = error{
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    NameTooLong,
    SystemResources,
    NotDir,
    BadPathName,
    NetworkNotFound,
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
    AccessDenied,
    Canceled,
    Unexpected,
};

pub const DirRenameError = error{
    AccessDenied,
    PermissionDenied,
    BadPathName,
    FileBusy,
    DiskQuota,
    IsDir,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    CrossDevice,
    DirNotEmpty,
    Canceled,
    Unexpected,
};

pub const DirDeleteFileError = error{
    AccessDenied,
    FileBusy,
    FileNotFound,
    IsDir,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,
    Canceled,
    Unexpected,
};

pub const DirDeleteDirError = error{
    AccessDenied,
    FileBusy,
    FileNotFound,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    ReadOnlyFileSystem,
    DirNotEmpty,
    Canceled,
    Unexpected,
};

pub const DirCreateDirError = error{
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    LinkQuotaExceeded,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NoSpaceLeft,
    NotDir,
    ReadOnlyFileSystem,
    Canceled,
    Unexpected,
};

pub const DirReadError = error{
    AccessDenied,
    PermissionDenied,
    SystemResources,
    Canceled,
    Unexpected,
};

/// Parsed directory entry
pub const DirEntry = struct {
    name: []const u8,
    kind: FileKind,
    inode: ino_t,
};

/// Iterator over directory entries in a buffer filled by dirRead.
/// Handles platform-specific parsing and UTF-16 to UTF-8 conversion on Windows.
pub const DirEntryIterator = struct {
    buffer: []u8,
    /// Current position in raw entries (user-facing, relative to unreserved buffer).
    index: usize,
    /// End position of raw entries (user-facing, relative to unreserved buffer).
    end: usize,
    /// Position for writing UTF-8 names (Windows only).
    name_index: usize,

    pub const RawEntry = switch (builtin.os.tag) {
        .linux => std.os.linux.dirent64,
        .windows => w.FILE_BOTH_DIR_INFORMATION,
        .macos, .ios, .tvos, .watchos, .visionos => std.c.dirent,
        .freebsd, .netbsd, .openbsd, .dragonfly => std.c.dirent,
        else => @compileError("DirEntryIterator not supported on this OS"),
    };

    /// On Windows, reserve space at start of buffer for UTF-8 name conversion.
    /// Raw entries go in the unreserved portion. Names can overwrite processed entries.
    pub const reserved_len = switch (builtin.os.tag) {
        .windows => blk: {
            const max_name_bytes = w.NAME_MAX * 3; // Worst-case UTF-8 expansion
            const max_info_len = @sizeOf(w.FILE_BOTH_DIR_INFORMATION) + w.NAME_MAX * 2;
            const info_align = @alignOf(w.FILE_BOTH_DIR_INFORMATION);
            const reserve_needed = std.mem.alignForward(usize, max_name_bytes, info_align) - max_info_len;
            break :blk std.mem.alignForward(usize, reserve_needed, info_align);
        },
        else => 0,
    };

    /// Initialize iterator over raw entries in the unreserved portion of buffer.
    /// `start` is the starting index, `end` is the number of bytes filled by the syscall.
    pub fn init(buffer: []u8, start: usize, end: usize) DirEntryIterator {
        return .{
            .buffer = buffer,
            .index = start,
            .end = end,
            .name_index = 0,
        };
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *DirEntryIterator) void {
        self.index = 0;
        self.name_index = 0;
    }

    /// Get the unreserved portion of the buffer (where raw entries should be written by syscall).
    pub fn getUnreservedBuffer(buffer: []u8) []u8 {
        return buffer[reserved_len..];
    }

    /// Convert user-facing index to raw buffer index.
    inline fn rawIndex(self: *const DirEntryIterator) usize {
        return reserved_len + self.index;
    }

    /// Convert user-facing end to raw buffer end.
    inline fn rawEnd(self: *const DirEntryIterator) usize {
        return reserved_len + self.end;
    }

    /// Get next directory entry, skipping "." and "..".
    /// Returns null when no more entries, or if buffer space exhausted (Windows).
    pub fn next(self: *DirEntryIterator) ?DirEntry {
        while (self.index < self.end) {
            const entry = self.nextRaw() orelse return null;

            // Skip . and ..
            if (self.isDotOrDotDot(entry)) continue;

            const name = self.extractName(entry) orelse {
                // On Windows, null means no buffer space - backtrack and stop
                if (builtin.os.tag == .windows) {
                    self.backtrack(entry);
                }
                return null;
            };

            return .{
                .name = name,
                .kind = self.extractKind(entry),
                .inode = self.extractInode(entry),
            };
        }
        return null;
    }

    fn nextRaw(self: *DirEntryIterator) ?*align(1) const RawEntry {
        if (self.index >= self.end) return null;
        const entry: *align(1) const RawEntry = @ptrCast(&self.buffer[self.rawIndex()]);

        // Advance to next entry
        self.index += switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd => entry.reclen,
            .dragonfly => entry.reclen(),
            .windows => if (entry.NextEntryOffset != 0)
                entry.NextEntryOffset
            else
                self.end - self.index,
            else => @compileError("unsupported OS"),
        };

        return entry;
    }

    fn backtrack(self: *DirEntryIterator, entry: *align(1) const RawEntry) void {
        // Revert to where this entry started
        self.index -= switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd => entry.reclen,
            .dragonfly => entry.reclen(),
            .windows => if (entry.NextEntryOffset != 0)
                entry.NextEntryOffset
            else
                0, // Was last entry, index is already at end
            else => @compileError("unsupported OS"),
        };
    }

    fn extractName(self: *DirEntryIterator, entry: *align(1) const RawEntry) ?[]const u8 {
        return switch (builtin.os.tag) {
            .linux => blk: {
                const name_ptr: [*]const u8 = @ptrCast(&entry.name);
                const max_len = entry.reclen - @offsetOf(std.os.linux.dirent64, "name");
                break :blk std.mem.sliceTo(name_ptr[0..max_len], 0);
            },
            .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => entry.name[0..entry.namlen],
            .windows => blk: {
                const name_ptr: [*]const u16 = @alignCast(@as([*]align(1) const u16, @ptrCast(&entry.FileName)));
                const name_utf16 = name_ptr[0 .. entry.FileNameLength / 2];
                const utf8_len = std.unicode.calcWtf8Len(name_utf16);

                // Check if there's space without overwriting unprocessed entries
                if (self.name_index + utf8_len > self.rawIndex()) return null;

                const name_buf = self.buffer[self.name_index..][0..utf8_len];
                _ = std.unicode.wtf16LeToWtf8(name_buf, name_utf16);
                self.name_index += utf8_len;
                break :blk name_buf;
            },
            else => @compileError("unsupported OS"),
        };
    }

    fn extractKind(_: *DirEntryIterator, entry: *align(1) const RawEntry) FileKind {
        return switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => switch (entry.type) {
                std.posix.DT.BLK => .block_device,
                std.posix.DT.CHR => .character_device,
                std.posix.DT.DIR => .directory,
                std.posix.DT.FIFO => .named_pipe,
                std.posix.DT.LNK => .sym_link,
                std.posix.DT.REG => .file,
                std.posix.DT.SOCK => .unix_domain_socket,
                std.posix.DT.WHT => .whiteout,
                else => .unknown,
            },
            .windows => blk: {
                const attrs = entry.FileAttributes;
                if (attrs.REPARSE_POINT) break :blk .sym_link;
                if (attrs.DIRECTORY) break :blk .directory;
                break :blk .file;
            },
            else => @compileError("unsupported OS"),
        };
    }

    fn extractInode(_: *DirEntryIterator, entry: *align(1) const RawEntry) ino_t {
        return switch (builtin.os.tag) {
            .linux, .macos, .ios, .tvos, .watchos, .visionos => entry.ino,
            .freebsd, .netbsd, .openbsd, .dragonfly => entry.fileno,
            .windows => entry.FileIndex,
            else => @compileError("unsupported OS"),
        };
    }

    fn isDotOrDotDot(self: *DirEntryIterator, entry: *align(1) const RawEntry) bool {
        _ = self;
        return switch (builtin.os.tag) {
            .windows => blk: {
                const name_ptr: [*]const u16 = @alignCast(@as([*]align(1) const u16, @ptrCast(&entry.FileName)));
                const name = name_ptr[0 .. entry.FileNameLength / 2];
                break :blk std.mem.eql(u16, name, &[_]u16{'.'}) or
                    std.mem.eql(u16, name, &[_]u16{ '.', '.' });
            },
            .linux => blk: {
                const name_ptr: [*]const u8 = @ptrCast(&entry.name);
                const max_len = entry.reclen - @offsetOf(std.os.linux.dirent64, "name");
                const name = std.mem.sliceTo(name_ptr[0..max_len], 0);
                break :blk std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
            },
            .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => blk: {
                const name = entry.name[0..entry.namlen];
                break :blk std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
            },
            else => @compileError("unsupported OS"),
        };
    }
};

pub const FileSizeError = error{
    AccessDenied,
    PermissionDenied,
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

pub const FileSetSizeError = error{
    AccessDenied,
    FileTooBig,
    InputOutput,
    FileBusy,
    PermissionDenied,
    Canceled,
    Unexpected,
};

pub const FileSetPermissionsError = error{
    AccessDenied,
    PermissionDenied,
    ReadOnlyFileSystem,
    Canceled,
    Unexpected,
};

pub const FileSetOwnerError = error{
    AccessDenied,
    PermissionDenied,
    ReadOnlyFileSystem,
    Canceled,
    Unexpected,
};

pub const FileSetTimestampsError = error{
    AccessDenied,
    PermissionDenied,
    ReadOnlyFileSystem,
    Canceled,
    Unexpected,
};

/// Open an existing file using openat() syscall
pub fn openat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: FileOpenFlags) FileOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        const access_mask: w.DWORD = switch (flags.mode) {
            .read_only => w.GENERIC_READ,
            .write_only => w.GENERIC_WRITE,
            .read_write => w.GENERIC_READ | w.GENERIC_WRITE,
        };

        const file_flags: w.DWORD = if (flags.nonblocking)
            w.FILE_ATTRIBUTE_NORMAL | w.FILE_FLAG_OVERLAPPED
        else
            w.FILE_ATTRIBUTE_NORMAL;

        const handle = w.CreateFileW(
            path_w.ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            file_flags,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.GetLastError()) {
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

/// Open a directory using openat() syscall
pub fn dirOpen(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: DirOpenFlags) DirOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        const access_mask: w.DWORD = w.GENERIC_READ;

        // FILE_FLAG_BACKUP_SEMANTICS is required to open directory handles
        const file_flags: w.DWORD = w.FILE_ATTRIBUTE_NORMAL | w.FILE_FLAG_BACKUP_SEMANTICS;

        const handle = w.CreateFileW(
            path_w.ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            file_flags,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| return unexpectedError(err),
            };
        }

        return handle;
    }

    var open_flags: posix.system.O = .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = !flags.follow_symlinks,
    };

    // On Linux, O_PATH can be used to open a directory descriptor without read permission
    // but only if we don't plan to iterate it
    if (@hasField(posix.system.O, "PATH") and !flags.iterate) {
        open_flags.PATH = true;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.openat(dir, path_z.ptr, open_flags, @as(mode_t, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToDirOpenError(err),
        }
    }
}

pub const FileCreateError = FileOpenError;

/// Create a file using openat() syscall
pub fn createat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: FileCreateFlags) FileCreateError!fd_t {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

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

        const handle = w.CreateFileW(
            path_w.ptr,
            access_mask,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            creation,
            file_flags,
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.GetLastError()) {
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
        var total_read: usize = 0;
        for (buffers) |buffer| {
            var bytes_read: w.DWORD = undefined;
            var overlapped: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(offset + total_read);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate((offset + total_read) >> 32);

            const success = w.ReadFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_read,
                &overlapped,
            );

            if (success == w.FALSE) {
                const err = w.GetLastError();
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
        var total_written: usize = 0;
        for (buffers) |buffer| {
            var bytes_written: w.DWORD = undefined;
            var overlapped: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(offset + total_written);
            overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate((offset + total_written) >> 32);

            const success = w.WriteFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_written,
                &overlapped,
            );

            if (success == w.FALSE) {
                return errnoToFileWriteError(w.GetLastError());
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

/// Read from file descriptor - for pipes and stream-like fds
pub fn read(fd: fd_t, buffer: []u8) FileReadError!usize {
    if (builtin.os.tag == .windows) {
        var bytes_read: w.DWORD = undefined;
        const success = w.ReadFile(
            fd,
            buffer.ptr,
            @intCast(buffer.len),
            &bytes_read,
            null,
        );
        if (success == w.FALSE) {
            const err = w.GetLastError();
            switch (err) {
                .HANDLE_EOF => return 0,
                else => return errnoToFileReadError(err),
            }
        }
        return bytes_read;
    }

    while (true) {
        const rc = posix.system.read(fd, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileReadError(err),
        }
    }
}

/// Read from file descriptor using readv() - for pipes and stream-like fds
pub fn readv(fd: fd_t, buffers: []iovec) FileReadError!usize {
    if (builtin.os.tag == .windows) {
        var total_read: usize = 0;
        for (buffers) |buffer| {
            var bytes_read: w.DWORD = undefined;

            const success = w.ReadFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_read,
                null,
            );

            if (success == w.FALSE) {
                const err = w.GetLastError();
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
        const rc = posix.system.readv(fd, buffers.ptr, @intCast(buffers.len));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileReadError(err),
        }
    }
}

/// Write to file descriptor - for pipes and stream-like fds
pub fn write(fd: fd_t, buffer: []const u8) FileWriteError!usize {
    if (builtin.os.tag == .windows) {
        var bytes_written: w.DWORD = undefined;
        const success = w.WriteFile(
            fd,
            buffer.ptr,
            @intCast(buffer.len),
            &bytes_written,
            null,
        );
        if (success == w.FALSE) {
            return errnoToFileWriteError(w.GetLastError());
        }
        return bytes_written;
    }

    while (true) {
        const rc = posix.system.write(fd, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileWriteError(err),
        }
    }
}

/// Write to file descriptor using writev() - for pipes and stream-like fds
pub fn writev(fd: fd_t, buffers: []const iovec_const) FileWriteError!usize {
    if (builtin.os.tag == .windows) {
        var total_written: usize = 0;
        for (buffers) |buffer| {
            var bytes_written: w.DWORD = undefined;

            const success = w.WriteFile(
                fd,
                buffer.buf,
                @intCast(buffer.len),
                &bytes_written,
                null,
            );

            if (success == w.FALSE) {
                return errnoToFileWriteError(w.GetLastError());
            }

            total_written += bytes_written;
            if (bytes_written < buffer.len) break;
        }

        return total_written;
    }

    while (true) {
        const rc = posix.system.writev(fd, buffers.ptr, @intCast(buffers.len));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToFileWriteError(err),
        }
    }
}

/// Sync file data to disk
pub fn fileSync(fd: fd_t, flags: FileSyncFlags) FileSyncError!void {
    if (builtin.os.tag == .windows) {
        const success = w.FlushFileBuffers(fd);
        if (success == w.FALSE) {
            switch (w.GetLastError()) {
                .ACCESS_DENIED => return error.AccessDenied,
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
pub fn renameat(allocator: std.mem.Allocator, old_dir: fd_t, old_path: []const u8, new_dir: fd_t, new_path: []const u8) DirRenameError!void {
    if (builtin.os.tag == .windows) {
        const old_path_w = try w.pathToWide(allocator, old_dir, old_path);
        defer allocator.free(old_path_w);
        const new_path_w = try w.pathToWide(allocator, new_dir, new_path);
        defer allocator.free(new_path_w);

        const success = w.MoveFileExW(
            old_path_w.ptr,
            new_path_w.ptr,
            w.MOVEFILE_REPLACE_EXISTING,
        );

        if (success == w.FALSE) {
            switch (w.GetLastError()) {
                .FILE_NOT_FOUND => return error.FileNotFound,
                .PATH_NOT_FOUND => return error.FileNotFound,
                .ACCESS_DENIED => return error.AccessDenied,
                .ALREADY_EXISTS => return error.Unexpected,
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
        const rc = posix.renameat(old_dir, old_path_z.ptr, new_dir, new_path_z.ptr);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToDirRenameError(err),
        }
    }
}

/// Delete a file using unlinkat() syscall
pub fn dirDeleteFile(allocator: std.mem.Allocator, dir: fd_t, path: []const u8) DirDeleteFileError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        if (w.DeleteFileW(path_w.ptr) == w.FALSE) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .SHARING_VIOLATION => error.FileBusy,
                else => |err| return unexpectedError(err),
            };
        }
        return;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.unlinkat(dir, path_z.ptr, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToDirDeleteFileError(err),
        }
    }
}

/// Delete a directory using unlinkat() syscall with AT_REMOVEDIR
pub fn dirDeleteDir(allocator: std.mem.Allocator, dir: fd_t, path: []const u8) DirDeleteDirError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        if (w.RemoveDirectoryW(path_w.ptr) == w.FALSE) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .SHARING_VIOLATION => error.FileBusy,
                .DIR_NOT_EMPTY => error.DirNotEmpty,
                else => |err| return unexpectedError(err),
            };
        }
        return;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.unlinkat(dir, path_z.ptr, posix.AT.REMOVEDIR);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToDirDeleteDirError(err),
        }
    }
}

/// Create a directory using mkdirat() syscall
pub fn mkdirat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, mode: mode_t) DirCreateDirError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        if (w.CreateDirectoryW(path_w.ptr, null) == w.FALSE) {
            return switch (w.GetLastError()) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .ACCESS_DENIED => error.AccessDenied,
                .ALREADY_EXISTS => error.PathAlreadyExists,
                .FILE_EXISTS => error.PathAlreadyExists,
                else => |err| return unexpectedError(err),
            };
        }

        return;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.mkdirat(dir, path_z.ptr, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToDirCreateDirError(err),
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

pub fn errnoToDirOpenError(errno: posix.system.E) DirOpenError {
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
        .NOTDIR => error.NotDir,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const E = if (builtin.os.tag == .windows) w.Win32Error else posix.system.E;

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

pub fn errnoToFileCloseError(errno: E) FileCloseError {
    switch (builtin.os.tag) {
        .windows => {
            return switch (errno) {
                .SUCCESS => unreachable,
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
        else => {
            return switch (errno) {
                .SUCCESS => unreachable,
                .CANCELED => error.Canceled,
                else => |e| unexpectedError(e) catch error.Unexpected,
            };
        },
    }
}

pub fn errnoToFileSyncError(errno: posix.system.E) FileSyncError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub fn errnoToDirRenameError(errno: posix.system.E) DirRenameError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .BUSY => error.FileBusy,
        .DQUOT => error.DiskQuota,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .EXIST => error.Unexpected, // PathAlreadyExists mapped to Unexpected for RenameError (use RenamePreserve for non-overwriting)
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        .XDEV => error.CrossDevice,
        .NOTEMPTY => error.DirNotEmpty,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub fn errnoToDirDeleteFileError(errno: posix.system.E) DirDeleteFileError {
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
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub fn errnoToDirDeleteDirError(errno: posix.system.E) DirDeleteDirError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.AccessDenied,
        .BUSY => error.FileBusy,
        .NOENT => error.FileNotFound,
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

pub fn errnoToDirCreateDirError(errno: posix.system.E) DirCreateDirError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .DQUOT => error.DiskQuota,
        .EXIST => error.PathAlreadyExists,
        .LOOP => error.SymLinkLoop,
        .MLINK => error.LinkQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Get the size of a file
pub fn fileSize(fd: fd_t) FileSizeError!u64 {
    if (builtin.os.tag == .windows) {
        var file_size: w.LARGE_INTEGER = undefined;
        const success = w.GetFileSizeEx(fd, &file_size);

        if (success == w.FALSE) {
            switch (w.GetLastError()) {
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
        .PERM => error.PermissionDenied,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Get file metadata by file descriptor
pub fn fstat(fd: fd_t) FileStatError!FileStatInfo {
    if (builtin.os.tag == .windows) {
        var info: w.BY_HANDLE_FILE_INFORMATION = undefined;
        const success = w.GetFileInformationByHandle(fd, &info);

        if (success == w.FALSE) {
            switch (w.GetLastError()) {
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
            .atime = w.fileTimeToNanos(info.ftLastAccessTime),
            .mtime = w.fileTimeToNanos(info.ftLastWriteTime),
            .ctime = w.fileTimeToNanos(info.ftCreationTime),
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
        const path_w = try w.pathToWide(allocator, dir, path);
        defer allocator.free(path_w);

        // Open with minimal access just to query attributes
        const handle = w.CreateFileW(
            path_w.ptr,
            0, // No access needed, just want to query attributes
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            w.FILE_FLAG_BACKUP_SEMANTICS, // Required to open directories
            null,
        );

        if (handle == w.INVALID_HANDLE_VALUE) {
            return switch (w.GetLastError()) {
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

/// Set file size (truncate or extend)
pub fn fileSetSize(fd: fd_t, length: u64) FileSetSizeError!void {
    if (builtin.os.tag == .windows) {
        // Save current position
        var current_pos: w.LARGE_INTEGER = undefined;
        if (w.SetFilePointerEx(fd, 0, &current_pos, w.FILE_CURRENT) == w.FALSE) {
            return switch (w.GetLastError()) {
                .INVALID_HANDLE => error.Unexpected,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| unexpectedError(err) catch error.Unexpected,
            };
        }

        // Check for overflow - LARGE_INTEGER is signed, so length must fit in i64
        if (length >= (1 << 63)) {
            return error.FileTooBig;
        }

        // Seek to desired length
        const len_signed: w.LARGE_INTEGER = @bitCast(length);
        if (w.SetFilePointerEx(fd, len_signed, null, w.FILE_BEGIN) == w.FALSE) {
            return switch (w.GetLastError()) {
                .INVALID_HANDLE => error.Unexpected,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| unexpectedError(err) catch error.Unexpected,
            };
        }

        // Set end of file at current position
        if (w.SetEndOfFile(fd) == w.FALSE) {
            // Try to restore position before returning error
            _ = w.SetFilePointerEx(fd, current_pos, null, w.FILE_BEGIN);
            return switch (w.GetLastError()) {
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| unexpectedError(err) catch error.Unexpected,
            };
        }

        // Restore original position
        _ = w.SetFilePointerEx(fd, current_pos, null, w.FILE_BEGIN);
        return;
    }

    while (true) {
        const rc = posix.system.ftruncate(fd, @intCast(length));
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetSizeError(err),
        }
    }
}

pub fn errnoToFileSetSizeError(errno: posix.system.E) FileSetSizeError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .FBIG => error.FileTooBig,
        .IO => error.InputOutput,
        .TXTBSY => error.FileBusy,
        .PERM => error.PermissionDenied,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const uid_t = if (builtin.os.tag == .windows) u32 else posix.system.uid_t;
pub const gid_t = if (builtin.os.tag == .windows) u32 else posix.system.gid_t;

/// Set file permissions (mode)
pub fn fileSetPermissions(fd: fd_t, mode: mode_t) FileSetPermissionsError!void {
    // Windows doesn't have POSIX-style permissions
    if (builtin.os.tag == .windows) return;

    while (true) {
        const rc = posix.system.fchmod(fd, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetPermissionsError(err),
        }
    }
}

pub fn errnoToFileSetPermissionsError(errno: posix.system.E) FileSetPermissionsError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Set file owner (uid/gid)
pub fn fileSetOwner(fd: fd_t, uid: ?uid_t, gid: ?gid_t) FileSetOwnerError!void {
    // Windows doesn't have POSIX-style ownership
    if (builtin.os.tag == .windows) return;

    // -1 means "don't change"
    const uid_arg: uid_t = uid orelse @bitCast(@as(i32, -1));
    const gid_arg: gid_t = gid orelse @bitCast(@as(i32, -1));

    while (true) {
        const rc = posix.system.fchown(fd, uid_arg, gid_arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetOwnerError(err),
        }
    }
}

pub fn errnoToFileSetOwnerError(errno: posix.system.E) FileSetOwnerError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Timestamps for fileSetTimestamps
pub const FileTimestamps = struct {
    /// Access time in nanoseconds since Unix epoch, or null to keep unchanged
    atime: ?i96 = null,
    /// Modification time in nanoseconds since Unix epoch, or null to keep unchanged
    mtime: ?i96 = null,
};

/// Set file timestamps
pub fn fileSetTimestamps(fd: fd_t, timestamps: FileTimestamps) FileSetTimestampsError!void {
    if (builtin.os.tag == .windows) {
        const atime: ?w.FILETIME = if (timestamps.atime) |ns| w.nanosToFileTime(ns) else null;
        const mtime: ?w.FILETIME = if (timestamps.mtime) |ns| w.nanosToFileTime(ns) else null;

        if (w.SetFileTime(
            fd,
            null, // creation time - don't change
            if (atime) |*a| a else null,
            if (mtime) |*m| m else null,
        ) == w.FALSE) {
            return switch (w.GetLastError()) {
                .INVALID_HANDLE => error.Unexpected,
                .ACCESS_DENIED => error.AccessDenied,
                else => |err| unexpectedError(err) catch error.Unexpected,
            };
        }
        return;
    }

    const UTIME_OMIT = 0x3ffffffe;

    const times: [2]posix.system.timespec = .{
        if (timestamps.atime) |ns|
            .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) }
        else
            .{ .sec = 0, .nsec = UTIME_OMIT },
        if (timestamps.mtime) |ns|
            .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) }
        else
            .{ .sec = 0, .nsec = UTIME_OMIT },
    };

    while (true) {
        const rc = posix.system.futimens(fd, &times);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetTimestampsError(err),
        }
    }
}

pub fn errnoToFileSetTimestampsError(errno: posix.system.E) FileSetTimestampsError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .ROFS => error.ReadOnlyFileSystem,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

/// Options for path-based permission/owner operations
pub const PathSetFlags = struct {
    follow_symlinks: bool = true,
};

/// Set permissions of a file relative to a directory (fchmodat)
pub fn dirSetFilePermissions(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, mode: mode_t, flags: PathSetFlags) FileSetPermissionsError!void {
    // Windows doesn't have POSIX-style permissions
    if (builtin.os.tag == .windows) return;

    const path_z = allocator.dupeZ(u8, path) catch return error.Unexpected;
    defer allocator.free(path_z);

    // Note: AT_SYMLINK_NOFOLLOW for fchmodat requires Linux 6.6+ (fchmodat2)
    const at_flags: u32 = if (flags.follow_symlinks) 0 else posix.AT.SYMLINK_NOFOLLOW;

    while (true) {
        const rc = posix.fchmodat(dir, path_z.ptr, mode, at_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetPermissionsError(err),
        }
    }
}

/// Set owner of a file relative to a directory (fchownat)
pub fn dirSetFileOwner(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, uid: ?uid_t, gid: ?gid_t, flags: PathSetFlags) FileSetOwnerError!void {
    // Windows doesn't have POSIX-style ownership
    if (builtin.os.tag == .windows) return;

    const path_z = allocator.dupeZ(u8, path) catch return error.Unexpected;
    defer allocator.free(path_z);

    // -1 means "don't change"
    const uid_arg: uid_t = uid orelse @bitCast(@as(i32, -1));
    const gid_arg: gid_t = gid orelse @bitCast(@as(i32, -1));

    const at_flags: u32 = if (!flags.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    while (true) {
        const rc = posix.fchownat(dir, path_z.ptr, uid_arg, gid_arg, at_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetOwnerError(err),
        }
    }
}

/// Set timestamps of a file relative to a directory (utimensat)
pub fn dirSetFileTimestamps(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, timestamps: FileTimestamps, flags: PathSetFlags) FileSetTimestampsError!void {
    if (builtin.os.tag == .windows) {
        // On Windows, we need to open the file first, set timestamps, then close
        // For now, return success (no-op like other Windows permission functions)
        return;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.Unexpected;
    defer allocator.free(path_z);

    const UTIME_OMIT = 0x3ffffffe;

    const times: [2]posix.system.timespec = .{
        if (timestamps.atime) |ns|
            .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) }
        else
            .{ .sec = 0, .nsec = UTIME_OMIT },
        if (timestamps.mtime) |ns|
            .{ .sec = @intCast(@divFloor(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) }
        else
            .{ .sec = 0, .nsec = UTIME_OMIT },
    };

    const at_flags: u32 = if (!flags.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    while (true) {
        const rc = posix.utimensat(dir, path_z.ptr, &times, at_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToFileSetTimestampsError(err),
        }
    }
}

pub const SymLinkError = error{
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    FileNotFound,
    ReadOnlyFileSystem,
    NotDir,
    NameTooLong,
    NoSpaceLeft,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const SymLinkFlags = struct {
    is_directory: bool = false,
};

/// Create a symbolic link using symlinkat() syscall
pub fn dirSymLink(allocator: std.mem.Allocator, dir: fd_t, target: []const u8, link_path: []const u8, flags: SymLinkFlags) SymLinkError!void {
    _ = flags;

    if (builtin.os.tag == .windows) {
        // TODO: Implement Windows symlink creation via CreateSymbolicLinkW
        return error.Unexpected;
    }

    const target_z = allocator.dupeZ(u8, target) catch return error.SystemResources;
    defer allocator.free(target_z);

    const link_path_z = allocator.dupeZ(u8, link_path) catch return error.SystemResources;
    defer allocator.free(link_path_z);

    while (true) {
        const rc = posix.system.symlinkat(target_z.ptr, dir, link_path_z.ptr);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToSymLinkError(err),
        }
    }
}

pub fn errnoToSymLinkError(errno: posix.system.E) SymLinkError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .DQUOT => error.DiskQuota,
        .EXIST => error.PathAlreadyExists,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .ROFS => error.ReadOnlyFileSystem,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const ReadLinkError = error{
    AccessDenied,
    PermissionDenied,
    FileNotFound,
    NotLink,
    SymLinkLoop,
    NameTooLong,
    NotDir,
    SystemResources,
    Canceled,
    Unexpected,
};

/// Read a symbolic link using readlinkat() syscall
pub fn dirReadLink(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, buffer: []u8) ReadLinkError!usize {
    if (builtin.os.tag == .windows) {
        // TODO: Implement Windows readlink via DeviceIoControl with FSCTL_GET_REPARSE_POINT
        return error.Unexpected;
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    while (true) {
        const rc = posix.system.readlinkat(dir, path_z.ptr, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToReadLinkError(err),
        }
    }
}

pub fn errnoToReadLinkError(errno: posix.system.E) ReadLinkError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .INVAL => error.NotLink,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const HardLinkError = error{
    AccessDenied,
    PermissionDenied,
    DiskQuota,
    PathAlreadyExists,
    SymLinkLoop,
    FileNotFound,
    ReadOnlyFileSystem,
    NotDir,
    NameTooLong,
    NoSpaceLeft,
    SystemResources,
    CrossDevice,
    Canceled,
    Unexpected,
};

pub const HardLinkFlags = struct {
    follow_symlinks: bool = false,
};

/// Create a hard link using linkat() syscall
pub fn dirHardLink(allocator: std.mem.Allocator, old_dir: fd_t, old_path: []const u8, new_dir: fd_t, new_path: []const u8, flags: HardLinkFlags) HardLinkError!void {
    if (builtin.os.tag == .windows) {
        // TODO: Implement Windows hardlink via CreateHardLinkW
        return error.Unexpected;
    }

    const old_path_z = allocator.dupeZ(u8, old_path) catch return error.SystemResources;
    defer allocator.free(old_path_z);

    const new_path_z = allocator.dupeZ(u8, new_path) catch return error.SystemResources;
    defer allocator.free(new_path_z);

    const at_flags: u32 = if (flags.follow_symlinks) posix.AT.SYMLINK_FOLLOW else 0;

    while (true) {
        const rc = posix.linkat(old_dir, old_path_z.ptr, new_dir, new_path_z.ptr, at_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToHardLinkError(err),
        }
    }
}

pub fn errnoToHardLinkError(errno: posix.system.E) HardLinkError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .DQUOT => error.DiskQuota,
        .EXIST => error.PathAlreadyExists,
        .LOOP => error.SymLinkLoop,
        .NOENT => error.FileNotFound,
        .ROFS => error.ReadOnlyFileSystem,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        .NOMEM => error.SystemResources,
        .XDEV => error.CrossDevice,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub const FileHardLinkError = HardLinkError || error{
    OperationUnsupported,
};

/// Create a hard link from an open file descriptor using linkat() with AT_EMPTY_PATH
pub fn fileHardLink(allocator: std.mem.Allocator, fd: fd_t, new_dir: fd_t, new_path: []const u8, flags: HardLinkFlags) FileHardLinkError!void {
    if (builtin.os.tag == .windows) {
        return error.OperationUnsupported;
    }

    const new_path_z = allocator.dupeZ(u8, new_path) catch return error.SystemResources;
    defer allocator.free(new_path_z);

    const at_flags: u32 = if (flags.follow_symlinks) posix.AT.SYMLINK_FOLLOW else 0;

    if (@hasDecl(posix.AT, "EMPTY_PATH")) {
        // Linux: try AT_EMPTY_PATH first, fall back to /proc/self/fd/{fd}
        while (true) {
            const rc = posix.linkat(fd, "", new_dir, new_path_z.ptr, at_flags | posix.AT.EMPTY_PATH);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
                .NOENT => {
                    // AT_EMPTY_PATH requires CAP_DAC_READ_SEARCH, fall back to /proc/self/fd
                    var proc_buf: ["/proc/self/fd/-2147483648\x00".len]u8 = undefined;
                    const proc_path = std.fmt.bufPrintZ(&proc_buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
                    while (true) {
                        const rc2 = posix.linkat(posix.AT.FDCWD, proc_path.ptr, new_dir, new_path_z.ptr, posix.AT.SYMLINK_FOLLOW);
                        switch (posix.errno(rc2)) {
                            .SUCCESS => return,
                            .INTR => continue,
                            else => |err2| return errnoToHardLinkError(err2),
                        }
                    }
                },
                else => |err| return errnoToHardLinkError(err),
            }
        }
    } else {
        // macOS/BSD: get real path from fd, then use dirHardLink
        var path_buf: [posix.PATH_MAX]u8 = undefined;
        const len = dirRealPath(fd, &path_buf) catch return error.OperationUnsupported;

        const old_path_z = allocator.dupeZ(u8, path_buf[0..len]) catch return error.SystemResources;
        defer allocator.free(old_path_z);

        while (true) {
            const rc = posix.linkat(posix.AT.FDCWD, old_path_z.ptr, new_dir, new_path_z.ptr, at_flags);
            switch (posix.errno(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
                else => |err| return errnoToHardLinkError(err),
            }
        }
    }
}

pub const DirAccessError = error{
    AccessDenied,
    PermissionDenied,
    FileNotFound,
    InputOutput,
    SystemResources,
    FileBusy,
    SymLinkLoop,
    ReadOnlyFileSystem,
    NameTooLong,
    BadPathName,
    Canceled,
    Unexpected,
};

pub const AccessFlags = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    follow_symlinks: bool = true,
};

/// Check file accessibility using faccessat() syscall
pub fn dirAccess(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: AccessFlags) DirAccessError!void {
    if (builtin.os.tag == .windows) {
        return dirAccessWindows(allocator, dir, path, flags);
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    var mode: u32 = posix.system.F_OK;
    if (flags.read) mode |= posix.system.R_OK;
    if (flags.write) mode |= posix.system.W_OK;
    if (flags.execute) mode |= posix.system.X_OK;

    const at_flags: u32 = if (flags.follow_symlinks) 0 else posix.AT.SYMLINK_NOFOLLOW;

    while (true) {
        const rc = posix.faccessat(dir, path_z.ptr, mode, at_flags);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return errnoToDirAccessError(err),
        }
    }
}

pub fn errnoToDirAccessError(errno: posix.system.E) DirAccessError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        .TXTBSY => error.FileBusy,
        .LOOP => error.SymLinkLoop,
        .ROFS => error.ReadOnlyFileSystem,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.FileNotFound,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

fn dirAccessWindows(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, flags: AccessFlags) DirAccessError!void {
    _ = flags; // Windows access check doesn't distinguish read/write/execute

    // Handle "." and ".." specially
    if (path.len == 1 and path[0] == '.') return;
    if (path.len == 2 and path[0] == '.' and path[1] == '.') return;

    const path_w = try w.pathToWide(allocator, dir, path);
    defer allocator.free(path_w);

    if (w.GetFileAttributesW(path_w) != w.INVALID_FILE_ATTRIBUTES) {
        return;
    }

    switch (w.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED => return error.AccessDenied,
        .INVALID_NAME => return error.BadPathName,
        else => return error.Unexpected,
    }
}

/// Read directory entries into buffer.
/// Returns number of bytes read, 0 when no more entries.
/// If restart is true, seeks to beginning first (POSIX) or passes RestartScan (Windows).
pub fn dirRead(handle: fd_t, buffer: []u8, restart: bool) DirReadError!usize {
    if (builtin.os.tag == .windows) {
        return dirReadWindows(handle, buffer, restart);
    } else {
        return dirReadPosix(handle, buffer, restart);
    }
}

fn dirReadPosix(handle: fd_t, buffer: []u8, restart: bool) DirReadError!usize {
    // Seek to beginning if restart requested
    if (restart) {
        const rc = posix.sys.lseek(handle, 0, posix.system.SEEK.SET);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .BADF => return error.Unexpected,
            else => |err| return unexpectedError(err) catch error.Unexpected,
        }
    }

    // Call getdents64 (Linux) or getdirentries (BSD)
    while (true) {
        const rc = switch (builtin.os.tag) {
            .linux => std.os.linux.getdents64(handle, buffer.ptr, buffer.len),
            .macos, .ios, .tvos, .watchos, .visionos => blk: {
                var basep: i64 = 0;
                break :blk @as(usize, @bitCast(std.c.__getdirentries64(handle, buffer.ptr, buffer.len, &basep)));
            },
            .freebsd, .netbsd, .openbsd, .dragonfly => blk: {
                var basep: c_long = 0;
                break :blk posix.system.getdirentries(handle, buffer.ptr, buffer.len, &basep);
            },
            else => @compileError("dirRead not implemented for this OS"),
        };

        switch (posix.errno(rc)) {
            .SUCCESS => return if (builtin.os.tag == .linux) rc else @intCast(rc),
            .INTR => continue,
            .BADF, .FAULT, .NOTDIR => return error.Unexpected,
            .NOENT => return 0, // Directory deleted during iteration
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .NOMEM => return error.SystemResources,
            else => |err| return unexpectedError(err) catch error.Unexpected,
        }
    }
}

fn dirReadWindows(handle: fd_t, buffer: []u8, restart: bool) DirReadError!usize {
    var io_status_block: w.IO_STATUS_BLOCK = undefined;

    while (true) {
        const rc = w.NtQueryDirectoryFile(
            handle,
            null, // Event
            null, // ApcRoutine
            null, // ApcContext
            &io_status_block,
            buffer.ptr,
            @intCast(buffer.len),
            .FileBothDirectoryInformation,
            0, // ReturnSingleEntry
            null, // FileName filter
            @intFromBool(restart),
        );

        switch (rc) {
            .SUCCESS => return io_status_block.Information,
            .NO_MORE_FILES => return 0,
            .CANCELLED => continue,
            .ACCESS_DENIED => return error.AccessDenied,
            .NOT_A_DIRECTORY => return error.Unexpected,
            else => return error.Unexpected,
        }
    }
}

pub const DirRealPathError = error{
    OperationUnsupported,
    NameTooLong,
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    NotDir,
    SymLinkLoop,
    InputOutput,
    FileSystem,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const DirRealPathFileError = DirRealPathError || error{
    FileTooBig,
    IsDir,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    NoSpaceLeft,
    DeviceBusy,
    BadPathName,
    PathAlreadyExists,
};

/// Get the real path of a directory fd using /proc/self/fd on Linux or F_GETPATH on macOS
pub fn dirRealPath(fd: fd_t, buffer: []u8) DirRealPathError!usize {
    if (builtin.os.tag == .windows) {
        return dirRealPathWindows(fd, buffer);
    }

    // Handle AT_FDCWD specially - it's not a real fd
    const actual_fd: std.posix.fd_t = if (fd == posix.AT.FDCWD) blk: {
        // Open "." to get a real fd for cwd
        const rc = posix.system.openat(fd, ".", .{ .CLOEXEC = true }, @as(mode_t, 0));
        if (posix.errno(rc) != .SUCCESS) return error.FileNotFound;
        break :blk @intCast(rc);
    } else fd;
    defer if (fd == posix.AT.FDCWD) std.posix.close(actual_fd);

    if (builtin.os.tag == .linux) {
        // Use /proc/self/fd/{fd} with readlink
        var proc_path_buf: [32:0]u8 = undefined;
        const proc_path = std.fmt.bufPrintZ(&proc_path_buf, "/proc/self/fd/{d}", .{actual_fd}) catch unreachable;

        while (true) {
            const rc = posix.system.readlink(proc_path, buffer.ptr, buffer.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                else => |err| return errnoToDirRealPathError(err),
            }
        }
    } else if (comptime builtin.os.tag.isDarwin() or builtin.os.tag == .netbsd) {
        // macOS/iOS/NetBSD: use fcntl F_GETPATH
        var sufficient_buffer: [posix.PATH_MAX]u8 = undefined;
        @memset(&sufficient_buffer, 0);

        while (true) {
            const rc = posix.system.fcntl(actual_fd, posix.system.F.GETPATH, &sufficient_buffer);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const n = std.mem.indexOfScalar(u8, &sufficient_buffer, 0) orelse sufficient_buffer.len;
                    if (n > buffer.len) return error.NameTooLong;
                    @memcpy(buffer[0..n], sufficient_buffer[0..n]);
                    return n;
                },
                .INTR => continue,
                else => |err| return errnoToDirRealPathError(err),
            }
        }
    } else if (comptime builtin.os.tag == .freebsd) {
        // FreeBSD: use fcntl F_KINFO
        var kf: posix.sys.kinfo_file = undefined;
        kf.structsize = @sizeOf(posix.sys.kinfo_file);

        while (true) {
            const rc = posix.system.fcntl(actual_fd, posix.system.F.KINFO, &kf);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const n = std.mem.indexOfScalar(u8, &kf.path, 0) orelse kf.path.len;
                    if (n == 0) return error.Unexpected; // F_KINFO cache miss
                    if (n > buffer.len) return error.NameTooLong;
                    @memcpy(buffer[0..n], kf.path[0..n]);
                    return n;
                },
                .INTR => continue,
                else => |err| return errnoToDirRealPathError(err),
            }
        }
    } else {
        // Other BSDs: not supported
        return error.Unexpected;
    }
}

/// Get the real path of a file relative to a directory
pub fn dirRealPathFile(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, buffer: []u8) DirRealPathFileError!usize {
    if (builtin.os.tag == .windows) {
        return dirRealPathFileWindows(allocator, dir, path, buffer);
    }

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    // On non-Linux with libc, we can use realpath() directly for AT_FDCWD
    if (builtin.os.tag != .linux and builtin.link_libc and dir == posix.AT.FDCWD) {
        if (buffer.len < posix.PATH_MAX) return error.NameTooLong;
        while (true) {
            if (std.c.realpath(path_z, buffer.ptr)) |_| {
                return std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
            }
            const err: posix.system.E = @enumFromInt(std.c._errno().*);
            if (err == .INTR) continue;
            return errnoToDirRealPathFileError(err);
        }
    }

    // Open the file with O_PATH to get its fd without actually opening it
    var open_flags: posix.system.O = .{ .CLOEXEC = true };
    if (@hasField(posix.system.O, "PATH")) open_flags.PATH = true;

    const file_fd: std.posix.fd_t = while (true) {
        const rc = posix.system.openat(dir, path_z.ptr, open_flags, @as(mode_t, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            else => |err| return errnoToDirRealPathFileError(err),
        }
    };
    defer std.posix.close(file_fd);

    // Now get the real path of the opened fd
    return dirRealPath(file_fd, buffer);
}

fn errnoToDirRealPathFileError(errno: posix.system.E) DirRealPathFileError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .BADF => error.FileNotFound,
        .NOSPC, .RANGE => error.NameTooLong,
        .CANCELED => error.Canceled,
        .FBIG, .OVERFLOW => error.FileTooBig,
        .ISDIR => error.IsDir,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV, .NXIO => error.NoDevice,
        .EXIST => error.PathAlreadyExists,
        .BUSY, .TXTBSY => error.DeviceBusy,
        .ILSEQ, .INVAL => error.BadPathName,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

pub fn errnoToDirRealPathError(errno: posix.system.E) DirRealPathError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .BADF => error.FileNotFound,
        .NOSPC, .RANGE => error.NameTooLong,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e) catch error.Unexpected,
    };
}

fn dirRealPathWindows(handle: fd_t, buffer: []u8) DirRealPathError!usize {
    // For cwd handle, we need to get a real handle first
    const is_cwd = (handle == cwd());
    const actual_handle = if (is_cwd) blk: {
        // Open "." to get a real handle
        const h = w.CreateFileW(
            &[_:0]u16{ '.', 0 },
            0, // No access needed, just query
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
            null,
            w.OPEN_EXISTING,
            w.FILE_FLAG_BACKUP_SEMANTICS, // Required for directories
            null,
        );
        if (h == w.INVALID_HANDLE_VALUE) return error.FileNotFound;
        break :blk h;
    } else handle;
    defer if (is_cwd) {
        _ = w.CloseHandle(actual_handle);
    };

    // Use a wide char buffer for the Windows API
    var wide_buf: [std.os.windows.PATH_MAX_WIDE]w.WCHAR = undefined;

    const result = w.GetFinalPathNameByHandleW(
        actual_handle,
        &wide_buf,
        wide_buf.len,
        w.FILE_NAME_NORMALIZED | w.VOLUME_NAME_DOS,
    );

    if (result == 0) {
        return switch (w.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .NOT_ENOUGH_MEMORY => error.SystemResources,
            else => error.Unexpected,
        };
    }

    if (result > wide_buf.len) return error.NameTooLong;

    // Convert UTF-16 to UTF-8
    const wide_slice = wide_buf[0..result];

    // Skip the \\?\ prefix if present
    const skip: usize = if (result >= 4 and wide_slice[0] == '\\' and wide_slice[1] == '\\' and wide_slice[2] == '?' and wide_slice[3] == '\\') 4 else 0;

    const len = std.unicode.calcWtf8Len(wide_slice[skip..]);
    if (len > buffer.len) return error.NameTooLong;

    return std.unicode.wtf16LeToWtf8(buffer, wide_slice[skip..]);
}

fn dirRealPathFileWindows(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, buffer: []u8) DirRealPathFileError!usize {
    const path_w = try w.pathToWide(allocator, dir, path);
    defer allocator.free(path_w);

    const handle = w.CreateFileW(
        path_w.ptr,
        0, // No access needed, just query
        w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
        null,
        w.OPEN_EXISTING,
        w.FILE_FLAG_BACKUP_SEMANTICS, // Required for directories
        null,
    );

    if (handle == w.INVALID_HANDLE_VALUE) {
        return switch (w.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .NOT_ENOUGH_MEMORY => error.SystemResources,
            else => error.Unexpected,
        };
    }
    defer _ = w.CloseHandle(handle);

    return dirRealPathWindows(handle, buffer);
}
