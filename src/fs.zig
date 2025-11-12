// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const File = @import("io/file.zig").File;
const Runtime = @import("runtime.zig").Runtime;

const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

/// Open a file for async I/O operations.
///
/// Opens an existing file for reading and/or writing.
/// TODO: Use aio.zig's openat() function instead of manual CreateFileW calls.
/// The returned File handle supports async read, write, pread, pwrite, and close operations.
///
/// ## Parameters
/// - `runtime`: The ZIO runtime instance for async operations
/// - `path`: Path to the file (supports both relative and absolute paths)
/// - `flags`: std.fs.File.OpenFlags specifying access mode
///
/// ## Returns
/// A File instance that must be closed with `close()` and freed with `deinit()`
///
/// ## Errors
/// - `FileNotFound`: File doesn't exist
/// - `AccessDenied`: Insufficient permissions to access the file
/// - Platform-specific file system errors
pub fn openFile(runtime: *Runtime, path: []const u8, flags: std.fs.File.OpenFlags) !File {
    _ = runtime;
    if (builtin.os.tag == .windows) {
        return openFileWindows(path, flags);
    } else {
        return openFileUnix(path, flags);
    }
}

/// Create a file for async I/O operations.
///
/// TODO: Use aio.zig's createat() function instead of manual CreateFileW calls.
/// Creates a new file with the specified creation flags.
///
/// ## Parameters
/// - `runtime`: The ZIO runtime instance for async operations
/// - `path`: Path to the file (supports both relative and absolute paths)
/// - `flags`: std.fs.File.CreateFlags specifying creation behavior
///
/// ## Returns
/// A File instance that must be closed with `close()` and freed with `deinit()`
///
/// ## Errors
/// - `AccessDenied`: Insufficient permissions to create the file
/// - Platform-specific file system errors
pub fn createFile(runtime: *Runtime, path: []const u8, flags: std.fs.File.CreateFlags) !File {
    _ = runtime;
    if (builtin.os.tag == .windows) {
        return createFileWindows(path, flags);
    } else {
        return createFileUnix(path, flags);
    }
}

fn openFileWindows(path: []const u8, flags: std.fs.File.OpenFlags) !File {
    // File locking is not supported in async I/O context
    if (flags.lock != .none) {
        return error.Unsupported;
    }

    // Convert path to UTF-16
    const path_w = try windows.sliceToPrefixedFileW(null, path);

    // Set desired access based on mode
    const desired_access: windows.DWORD = switch (flags.mode) {
        .read_only => windows.GENERIC_READ,
        .write_only => windows.GENERIC_WRITE,
        .read_write => windows.GENERIC_READ | windows.GENERIC_WRITE,
    };

    // Open existing file only
    const creation_disposition: windows.DWORD = windows.OPEN_EXISTING;

    // Use same sharing mode as std.fs for consistency
    const share_mode: windows.DWORD = windows.FILE_SHARE_WRITE | windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE;

    // Create file with FILE_FLAG_OVERLAPPED for IOCP compatibility
    const handle = windows.kernel32.CreateFileW(
        path_w.span().ptr,
        desired_access,
        share_mode,
        null,
        creation_disposition,
        //windows.FILE_FLAG_OVERLAPPED,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (handle == windows.INVALID_HANDLE_VALUE) {
        const err = windows.kernel32.GetLastError();
        return switch (err) {
            windows.Win32Error.FILE_NOT_FOUND => error.FileNotFound,
            windows.Win32Error.ACCESS_DENIED => error.AccessDenied,
            else => windows.unexpectedError(err),
        };
    }

    // Create File instance using the handle
    return File.initFd(handle);
}

fn createFileWindows(path: []const u8, flags: std.fs.File.CreateFlags) !File {
    // File locking is not supported in async I/O context
    if (flags.lock != .none) {
        return error.Unsupported;
    }

    // Convert path to UTF-16
    const path_w = try windows.sliceToPrefixedFileW(null, path);

    // Set desired access based on flags
    // CreateFlags always allows writing, read is optional
    const desired_access: windows.DWORD = if (flags.read)
        (windows.GENERIC_READ | windows.GENERIC_WRITE)
    else
        windows.GENERIC_WRITE;

    // Set creation disposition based on flags
    const creation_disposition: windows.DWORD = if (flags.exclusive)
        windows.CREATE_NEW
    else if (flags.truncate)
        windows.CREATE_ALWAYS
    else
        windows.OPEN_ALWAYS;

    // Use same sharing mode as std.fs for consistency
    const share_mode: windows.DWORD = windows.FILE_SHARE_WRITE | windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE;

    // Create file with FILE_FLAG_OVERLAPPED for IOCP compatibility
    const handle = windows.kernel32.CreateFileW(
        path_w.span().ptr,
        desired_access,
        share_mode,
        null,
        creation_disposition,
//        windows.FILE_FLAG_OVERLAPPED,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (handle == windows.INVALID_HANDLE_VALUE) {
        const err = windows.kernel32.GetLastError();
        return switch (err) {
            windows.Win32Error.FILE_NOT_FOUND => error.FileNotFound,
            windows.Win32Error.ACCESS_DENIED => error.AccessDenied,
            windows.Win32Error.FILE_EXISTS => error.PathAlreadyExists,
            else => windows.unexpectedError(err),
        };
    }

    // Create File instance using the handle
    return File.initFd(handle);
}

fn openFileUnix(path: []const u8, flags: std.fs.File.OpenFlags) !File {
    // File locking is not supported in async I/O context
    if (flags.lock != .none) {
        return error.Unsupported;
    }

    const std_file = try std.fs.cwd().openFile(path, flags);
    return File.init(std_file);
}

fn createFileUnix(path: []const u8, flags: std.fs.File.CreateFlags) !File {
    // File locking is not supported in async I/O context
    if (flags.lock != .none) {
        return error.Unsupported;
    }

    const std_file = try std.fs.cwd().createFile(path, flags);
    return File.init(std_file);
}

test "fs: openFile and createFile with different modes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            // Test creating a new file using the fs module
            const file_path = "test_fs_demo.txt";

            var file = try createFile(rt, file_path, .{});

            // Write some data
            const write_data = "Hello, zio fs!";
            _ = try file.write(rt, write_data);
            file.close(rt);

            // Test opening the file for reading
            var read_file = try openFile(rt, file_path, .{ .mode = .read_only });

            // Read back the data
            var buffer: [100]u8 = undefined;
            const bytes_read = try read_file.read(rt, &buffer);
            try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            read_file.close(rt);

            // Clean up the test file
            std.fs.cwd().deleteFile(file_path) catch {};
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}
