const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const File = @import("file.zig").File;
const Runtime = @import("runtime.zig").Runtime;

const windows = if (builtin.os.tag == .windows) std.os.windows else struct {};

/// File access mode for reading and/or writing
pub const OpenMode = enum {
    /// Open file for reading only
    read_only,
    /// Open file for writing only
    write_only,
    /// Open file for both reading and writing
    read_write,
};

/// File creation behavior when opening files
pub const CreateMode = enum {
    /// Create new file, fail if it already exists
    create_new,
    /// Always create file, overwrite if it exists
    create_always,
    /// Open existing file or create if it doesn't exist
    open_always,
    /// Open existing file, fail if it doesn't exist
    open_existing,
};

/// File sharing permissions for concurrent access (Windows-specific, ignored on Unix)
pub const SharingMode = enum {
    /// Exclusive access - no other processes can access the file
    none,
    /// Allow other processes to read the file
    read,
    /// Allow other processes to write to the file
    write,
    /// Allow other processes to read and write the file
    read_write,
};

/// Options for opening existing files or creating new ones
pub const OpenOptions = struct {
    /// Access mode for the file
    mode: OpenMode = .read_only,
    /// File creation behavior
    create: CreateMode = .open_existing,
    /// Sharing permissions (Windows only)
    sharing: SharingMode = .read_write,
};

/// Options for creating new files
pub const CreateOptions = struct {
    /// Access mode for the new file
    mode: OpenMode = .read_write,
    /// Whether to truncate existing files
    truncate: bool = true,
};

/// Open a file for async I/O operations.
///
/// Opens an existing file or creates a new one based on the provided options.
/// On Windows, files are created with FILE_FLAG_OVERLAPPED for IOCP compatibility.
/// The returned File handle supports async read, write, pread, pwrite, and close operations.
///
/// ## Parameters
/// - `runtime`: The ZIO runtime instance for async operations
/// - `path`: Path to the file (supports both relative and absolute paths)
/// - `options`: Configuration for file access mode, creation behavior, and sharing permissions
///
/// ## Returns
/// A File instance that must be closed with `close()` and freed with `deinit()`
///
/// ## Errors
/// - `FileNotFound`: File doesn't exist when using `open_existing` mode
/// - `PathAlreadyExists`: File exists when using `create_new` mode
/// - `AccessDenied`: Insufficient permissions to access the file
/// - Platform-specific file system errors
pub fn openFile(runtime: *Runtime, path: []const u8, options: OpenOptions) !File {
    if (builtin.os.tag == .windows) {
        return openFileWindows(runtime, path, options);
    } else {
        return openFileUnix(runtime, path, options);
    }
}

/// Create a file for async I/O operations.
///
/// Creates a new file with the specified access mode. This is a convenience function
/// that wraps `openFile` with appropriate creation options.
///
/// ## Parameters
/// - `runtime`: The ZIO runtime instance for async operations
/// - `path`: Path to the file (supports both relative and absolute paths)
/// - `options`: Configuration for file access mode and truncation behavior
///
/// ## Returns
/// A File instance that must be closed with `close()` and freed with `deinit()`
///
/// ## Errors
/// - `AccessDenied`: Insufficient permissions to create the file
/// - Platform-specific file system errors
pub fn createFile(runtime: *Runtime, path: []const u8, options: CreateOptions) !File {
    if (builtin.os.tag == .windows) {
        return createFileWindows(runtime, path, options);
    } else {
        return createFileUnix(runtime, path, options);
    }
}

fn openFileWindows(runtime: *Runtime, path: []const u8, options: OpenOptions) !File {
    const allocator = runtime.allocator;

    // Convert path to UTF-16
    const path_w = try windows.sliceToPrefixedFileW(allocator, path);
    defer allocator.free(path_w.span());

    // Set desired access based on mode
    const desired_access: windows.DWORD = switch (options.mode) {
        .read_only => windows.GENERIC_READ,
        .write_only => windows.GENERIC_WRITE,
        .read_write => windows.GENERIC_READ | windows.GENERIC_WRITE,
    };

    // Set creation disposition based on create mode
    const creation_disposition: windows.DWORD = switch (options.create) {
        .create_new => windows.CREATE_NEW,
        .create_always => windows.CREATE_ALWAYS,
        .open_always => windows.OPEN_ALWAYS,
        .open_existing => windows.OPEN_EXISTING,
    };

    // Set sharing mode based on options
    const share_mode: windows.DWORD = switch (options.sharing) {
        .none => 0,
        .read => windows.FILE_SHARE_READ,
        .write => windows.FILE_SHARE_WRITE,
        .read_write => windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
    };

    // Create file with FILE_FLAG_OVERLAPPED for IOCP compatibility
    const handle = windows.kernel32.CreateFileW(
        path_w.span().ptr,
        desired_access,
        share_mode,
        null,
        creation_disposition,
        windows.FILE_FLAG_OVERLAPPED,
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
    return File.initFd(runtime, handle);
}

fn createFileWindows(runtime: *Runtime, path: []const u8, options: CreateOptions) !File {
    const open_options = OpenOptions{
        .mode = options.mode,
        .create = if (options.truncate) .create_always else .open_always,
    };
    return openFileWindows(runtime, path, open_options);
}

fn openFileUnix(runtime: *Runtime, path: []const u8, options: OpenOptions) !File {
    // Convert OpenOptions to std.fs.File.OpenFlags
    var flags: std.fs.File.OpenFlags = .{};

    switch (options.mode) {
        .read_only => flags.mode = .read_only,
        .write_only => flags.mode = .write_only,
        .read_write => flags.mode = .read_write,
    }

    const std_file = switch (options.create) {
        .create_new => blk: {
            const file = std.fs.cwd().createFile(path, .{ .read = options.mode != .write_only, .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => return error.PathAlreadyExists,
                else => return err,
            };
            break :blk file;
        },
        .create_always => try std.fs.cwd().createFile(path, .{ .read = options.mode != .write_only }),
        .open_always => std.fs.cwd().createFile(path, .{ .read = options.mode != .write_only }) catch |err| switch (err) {
            error.PathAlreadyExists => try std.fs.cwd().openFile(path, flags),
            else => return err,
        },
        .open_existing => try std.fs.cwd().openFile(path, flags),
    };

    return File.init(runtime, std_file);
}

fn createFileUnix(runtime: *Runtime, path: []const u8, options: CreateOptions) !File {
    const create_flags: std.fs.File.CreateFlags = .{
        .read = options.mode != .write_only,
        .truncate = options.truncate,
    };

    const std_file = try std.fs.cwd().createFile(path, create_flags);
    return File.init(runtime, std_file);
}

test "fs: openFile and createFile with different modes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            // Test creating a new file using the fs module
            const file_path = "test_fs_demo.txt";

            var file = try createFile(rt, file_path, .{});
            defer file.deinit();

            // Write some data
            const write_data = "Hello, zio fs!";
            _ = try file.write(write_data);
            try file.close();

            // Test opening the file for reading
            var read_file = try openFile(rt, file_path, .{ .mode = .read_only });
            defer read_file.deinit();

            // Read back the data
            var buffer: [100]u8 = undefined;
            const bytes_read = try read_file.read(&buffer);
            try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            try read_file.close();

            // Clean up the test file
            std.fs.cwd().deleteFile(file_path) catch {};
        }
    };

    var task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();
    try task.result();
}
