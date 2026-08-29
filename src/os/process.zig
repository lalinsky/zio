const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w = @import("windows.zig");
const fs = @import("fs.zig");

const unexpectedError = @import("base.zig").unexpectedError;
const syscall_cancel = @import("syscall_cancel.zig");

pub const CurrentPathError = error{
    /// The path does not fit in the buffer the caller provided.
    NameTooLong,
    /// The working directory was removed while the process was in it. Cannot
    /// happen on Windows, which holds a handle to it.
    CurrentDirUnlinked,
    AccessDenied,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const SetCurrentPathError = error{
    AccessDenied,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    /// The path is not valid for the platform. Windows only.
    BadPathName,
    InputOutput,
    SystemResources,
    Canceled,
    Unexpected,
};

pub const SetCurrentDirError = error{
    AccessDenied,
    NotDir,
    InputOutput,
    /// The directory has no path to name it by. Windows only.
    BadPathName,
    SystemResources,
    Canceled,
    Unexpected,
};

/// Write the path of the current working directory into `buffer`, returning its
/// length. On Windows the result is WTF-8; elsewhere it is whatever bytes the
/// system stores, with no particular encoding.
pub fn getCurrentPath(allocator: std.mem.Allocator, buffer: []u8) CurrentPathError!usize {
    if (builtin.os.tag == .windows) {
        // Asking for a zero-length buffer returns the size that would be
        // needed, counting the terminating null.
        const needed = w.GetCurrentDirectoryW(0, null);
        if (needed == 0) return unexpectedError(w.GetLastError());

        const wide = allocator.alloc(w.WCHAR, needed) catch return error.SystemResources;
        defer allocator.free(wide);

        // The second call reports the length without the terminating null, so
        // it is one short of `needed` unless the directory changed underneath.
        const len = w.GetCurrentDirectoryW(needed, wide.ptr);
        if (len == 0) return unexpectedError(w.GetLastError());
        if (len >= needed) return error.Unexpected;

        if (std.unicode.calcWtf8Len(wide[0..len]) > buffer.len) return error.NameTooLong;
        return std.unicode.wtf16LeToWtf8(buffer, wide[0..len]);
    }

    if (buffer.len == 0) return error.NameTooLong;

    const sc = try syscall_cancel.Syscall.begin();
    defer sc.finish();
    while (true) {
        // libc returns null on failure, the raw syscall a negative errno.
        const err = if (builtin.os.tag == .linux)
            posix.errno(posix.system.getcwd(buffer.ptr, buffer.len))
        else if (posix.system.getcwd(buffer.ptr, buffer.len) != null)
            posix.system.E.SUCCESS
        else
            posix.errno(@as(c_int, -1));

        switch (err) {
            // The path is written null terminated, and the terminator is not
            // part of the length we report.
            .SUCCESS => return std.mem.indexOfScalar(u8, buffer, 0) orelse return error.Unexpected,
            .INTR => {
                try sc.checkCancel();
                continue;
            },
            else => return errnoToCurrentPathError(err),
        }
    }
}

pub fn errnoToCurrentPathError(errno: posix.system.E) CurrentPathError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .RANGE => error.NameTooLong,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.CurrentDirUnlinked,
        .ACCES, .PERM => error.AccessDenied,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e),
    };
}

/// Change the working directory to `path`.
pub fn setCurrentPath(allocator: std.mem.Allocator, path: []const u8) SetCurrentPathError!void {
    if (builtin.os.tag == .windows) {
        const path_w = try w.pathToWide(allocator, w.FDCWD, path);
        defer allocator.free(path_w);

        if (w.SetCurrentDirectoryW(path_w.ptr) == w.FALSE) {
            return win32ErrorToSetCurrentPathError(w.GetLastError());
        }
        return;
    }

    const path_z = allocator.dupeSentinel(u8, path, 0) catch return error.SystemResources;
    defer allocator.free(path_z);

    const sc = try syscall_cancel.Syscall.begin();
    defer sc.finish();
    while (true) {
        switch (posix.errno(posix.system.chdir(path_z.ptr))) {
            .SUCCESS => return,
            .INTR => {
                try sc.checkCancel();
                continue;
            },
            else => |err| return errnoToSetCurrentPathError(err),
        }
    }
}

pub fn errnoToSetCurrentPathError(errno: posix.system.E) SetCurrentPathError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e),
    };
}

fn win32ErrorToSetCurrentPathError(err: w.Win32Error) SetCurrentPathError {
    return switch (err) {
        .SUCCESS => unreachable,
        .ACCESS_DENIED => error.AccessDenied,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
        .DIRECTORY => error.NotDir,
        .INVALID_NAME, .BAD_PATHNAME => error.BadPathName,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
        else => |e| unexpectedError(e),
    };
}

/// Change the working directory to an already open directory.
pub fn setCurrentDir(allocator: std.mem.Allocator, fd: fs.fd_t) SetCurrentDirError!void {
    // The cwd sentinel is not a descriptor fchdir can take, and asking for the
    // directory we are already in is a no-op anyway.
    if (fd == fs.cwd()) return;

    if (builtin.os.tag == .windows) {
        // Windows has no fchdir: the directory has to be named, and the only
        // name we have for an open handle is the one we can query back out of
        // it.
        const path_buf = allocator.alloc(u8, std.os.windows.PATH_MAX_WIDE) catch return error.SystemResources;
        defer allocator.free(path_buf);

        const len = fs.dirRealPath(fd, path_buf) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            error.NotDir => return error.NotDir,
            error.InputOutput, error.FileSystem => return error.InputOutput,
            error.SystemResources => return error.SystemResources,
            error.Canceled => return error.Canceled,
            // A handle we cannot name is one we cannot chdir to.
            error.NameTooLong, error.FileNotFound, error.SymLinkLoop, error.OperationUnsupported => return error.BadPathName,
            error.Unexpected => return error.Unexpected,
        };

        return setCurrentPath(allocator, path_buf[0..len]) catch |err| switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.NotDir => error.NotDir,
            error.InputOutput => error.InputOutput,
            error.SystemResources => error.SystemResources,
            error.Canceled => error.Canceled,
            error.BadPathName, error.FileNotFound, error.NameTooLong, error.SymLinkLoop => error.BadPathName,
            error.Unexpected => error.Unexpected,
        };
    }

    const sc = try syscall_cancel.Syscall.begin();
    defer sc.finish();
    while (true) {
        switch (posix.errno(posix.system.fchdir(fd))) {
            .SUCCESS => return,
            .INTR => {
                try sc.checkCancel();
                continue;
            },
            else => |err| return errnoToSetCurrentDirError(err),
        }
    }
}

pub fn errnoToSetCurrentDirError(errno: posix.system.E) SetCurrentDirError {
    return switch (errno) {
        .SUCCESS => unreachable,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        .CANCELED => error.Canceled,
        else => |e| unexpectedError(e),
    };
}

/// Write the path of the running executable into `buffer`, returning its
/// length. Follows symlinks so the result names the real image. Windows, the
/// BSDs, and the argv0-only systems (OpenBSD, Haiku) are not handled here yet
/// and are still served by std's implementation from the vtable.
///
/// The zio error sets returned below are deliberately subsets of
/// `std.process.ExecutablePathError`, so they coerce on return without an
/// explicit remap.
pub fn getExecutablePath(allocator: std.mem.Allocator, buffer: []u8) std.process.ExecutablePathError!usize {
    switch (builtin.os.tag) {
        .linux => {
            // procfs exposes the executable image as a symlink at /proc/self/exe.
            return fs.dirReadLink(allocator, fs.cwd(), "/proc/self/exe", buffer);
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // _NSGetExecutablePath can hand back a path that is itself a symlink
            // (and not necessarily absolute), so resolve it afterward.
            var symlink_buf: [posix.PATH_MAX + 1]u8 = undefined;
            var symlink_len: u32 = symlink_buf.len;
            if (std.c._NSGetExecutablePath(&symlink_buf, &symlink_len) != 0) return error.NameTooLong;
            const symlink_path = std.mem.sliceTo(&symlink_buf, 0);
            return fs.dirRealPathFile(allocator, fs.cwd(), symlink_path, buffer);
        },
        else => return error.OperationUnsupported,
    }
}

test "getExecutablePath returns an absolute path to the test binary" {
    switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => {},
        else => return error.SkipZigTest,
    }

    var buf: [posix.PATH_MAX]u8 = undefined;
    const len = try getExecutablePath(std.testing.allocator, &buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(buf[0] == '/');
}
