// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Blocking std.Io implementation for use in spawnBlocking tasks.
//!
//! This implementation directly calls blocking OS functions without going
//! through the async I/O submission path. It's simpler and more efficient
//! when running on a dedicated blocking thread pool thread.
//!
//! Note: Cancellation is not supported for blocking I/O operations.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const os = @import("../os/root.zig");
const Runtime = @import("../runtime.zig").Runtime;
const zio_net = @import("../net.zig");

// -----------------------------------------------------------------------------
// Async/Concurrent - Not supported in blocking mode
// -----------------------------------------------------------------------------

fn asyncImpl(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*Io.AnyFuture {
    _ = userdata;
    _ = result_alignment;
    _ = context_alignment;
    // In blocking mode, just execute synchronously
    start(context.ptr, result.ptr);
    return null;
}

fn concurrentImpl(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    _ = userdata;
    _ = result_len;
    _ = result_alignment;
    _ = context;
    _ = context_alignment;
    _ = start;
    return error.ConcurrencyUnavailable;
}

fn awaitImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    unreachable; // Should never be called since async returns null
}

fn cancelImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    _ = userdata;
    _ = any_future;
    _ = result;
    _ = result_alignment;
    unreachable; // Should never be called since async returns null
}

fn groupAsyncImpl(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Io.Cancelable!void) void {
    _ = userdata;
    _ = group;
    _ = context_alignment;
    // Execute synchronously in blocking mode
    start(context.ptr) catch {};
}

fn groupConcurrentImpl(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Io.Cancelable!void) Io.ConcurrentError!void {
    _ = userdata;
    _ = group;
    _ = context;
    _ = context_alignment;
    _ = start;
    return error.ConcurrencyUnavailable;
}

fn groupAwaitImpl(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) Io.Cancelable!void {
    _ = userdata;
    _ = group;
    _ = initial_token;
    // Nothing to wait for in blocking mode - all executed synchronously
}

fn groupCancelImpl(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    _ = userdata;
    _ = group;
    _ = initial_token;
    // Nothing to cancel in blocking mode
}

fn selectImpl(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Io.Cancelable!usize {
    _ = userdata;
    _ = futures;
    unreachable; // No futures in blocking mode
}

fn recancelImpl(userdata: ?*anyopaque) void {
    _ = userdata;
    // No cancellation support in blocking mode
}

fn swapCancelProtectionImpl(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    _ = new;
    // No cancellation support - always "unblocked"
    return .unblocked;
}

fn checkCancelImpl(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata;
    // No cancellation support in blocking mode
}

fn futexWaitImpl(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    _ = timeout;
    // Use std library's blocking futex
    std.Thread.Futex.wait(@as(*const std.atomic.Value(u32), @ptrCast(ptr)), expected);
}

fn futexWaitUncancelableImpl(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    std.Thread.Futex.wait(@as(*const std.atomic.Value(u32), @ptrCast(ptr)), expected);
}

fn futexWakeImpl(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    _ = userdata;
    std.Thread.Futex.wake(@as(*const std.atomic.Value(u32), @ptrCast(ptr)), max_waiters);
}

// -----------------------------------------------------------------------------
// Directory operations
// -----------------------------------------------------------------------------

fn getAllocator(userdata: ?*anyopaque) Allocator {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return rt.allocator;
}

fn dirCreateDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    const mode = if (@hasDecl(Io.Dir.Permissions, "toMode")) permissions.toMode() else 0;
    os.fs.mkdirat(getAllocator(userdata), dir.handle, sub_path, mode) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.SymLinkLoop => error.SymLinkLoop,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.NotDir => error.NotDir,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.PathAlreadyExists => error.PathAlreadyExists,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.SystemResources => error.SystemResources,
            error.DiskQuota => error.DiskQuota,
            else => error.Unexpected,
        };
    };
}

fn dirCreateDirPathImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    @panic("TODO: dirCreateDirPath");
}

fn dirCreateDirPathOpenImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
    @panic("TODO: dirCreateDirPathOpen");
}

fn dirStatImpl(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    _ = userdata;
    const aio_stat = os.fs.fstat(dir.handle) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
    return aioFileStatToStdIo(aio_stat);
}

fn dirStatFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    if (!options.follow_symlinks) {
        return error.Unexpected;
    }
    const aio_stat = os.fs.fstatat(getAllocator(userdata), dir.handle, sub_path) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.SymLinkLoop => error.SymLinkLoop,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.NotDir => error.NotDir,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
    return aioFileStatToStdIo(aio_stat);
}

fn dirAccessImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    os.fs.dirAccess(getAllocator(userdata), dir.handle, sub_path, .{
        .read = options.read,
        .write = options.write,
        .execute = options.execute,
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.PermissionDenied => error.PermissionDenied,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.AccessDenied => error.AccessDenied,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirCreateFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.CreateFlags) Io.File.OpenError!Io.File {
    if (flags.lock != .none or flags.lock_nonblocking) return error.Unexpected;

    const fd = os.fs.createat(getAllocator(userdata), dir.handle, sub_path, .{
        .read = flags.read,
        .truncate = flags.truncate,
        .exclusive = flags.exclusive,
    }) catch |err| return mapFileOpenError(err);

    return .{ .handle = fd };
}

fn dirOpenFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.OpenFlags) Io.File.OpenError!Io.File {
    if (flags.lock != .none or flags.lock_nonblocking or flags.allow_ctty or !flags.follow_symlinks) {
        return error.Unexpected;
    }

    const fd = os.fs.openat(getAllocator(userdata), dir.handle, sub_path, .{
        .mode = switch (flags.mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        },
    }) catch |err| return mapFileOpenError(err);

    return .{ .handle = fd };
}

fn dirOpenDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    const fd = os.fs.dirOpen(getAllocator(userdata), dir.handle, sub_path, .{
        .follow_symlinks = options.follow_symlinks,
        .iterate = options.iterate,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.SymLinkLoop => error.SymLinkLoop,
            error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
            error.NoDevice => error.NoDevice,
            error.FileNotFound => error.FileNotFound,
            error.NameTooLong => error.NameTooLong,
            error.SystemResources => error.SystemResources,
            error.NotDir => error.NotDir,
            error.BadPathName => error.BadPathName,
            error.NetworkNotFound => error.NetworkNotFound,
            else => error.Unexpected,
        };
    };

    return .{ .handle = fd };
}

fn dirCloseImpl(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
    _ = userdata;
    for (dirs) |dir| {
        os.fs.close(dir.handle) catch {};
    }
}

fn dirReadImpl(userdata: ?*anyopaque, reader: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    _ = userdata;
    _ = reader;
    _ = entries;
    @panic("TODO: dirRead");
}

fn dirRealPathImpl(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
    _ = userdata;
    return os.fs.dirRealPath(dir.handle, out_buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            error.NameTooLong => error.NameTooLong,
            error.SymLinkLoop => error.SymLinkLoop,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirRealPathFileImpl(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
    return os.fs.dirRealPathFile(getAllocator(userdata), dir.handle, path_name, out_buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            error.NameTooLong => error.NameTooLong,
            error.SymLinkLoop => error.SymLinkLoop,
            error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirDeleteFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    os.fs.dirDeleteFile(getAllocator(userdata), dir.handle, sub_path) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileBusy => error.FileBusy,
            error.FileNotFound => error.FileNotFound,
            error.IsDir => error.IsDir,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NotDir => error.NotDir,
            error.SystemResources => error.SystemResources,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirDeleteDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    os.fs.dirDeleteDir(getAllocator(userdata), dir.handle, sub_path) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileNotFound => error.FileNotFound,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NotDir => error.NotDir,
            error.DirNotEmpty => error.DirNotEmpty,
            error.SystemResources => error.SystemResources,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirRenameImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
    os.fs.renameat(getAllocator(userdata), old_dir.handle, old_sub_path, new_dir.handle, new_sub_path) catch |err| {
        return switch (err) {
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            error.BadPathName => error.BadPathName,
            error.FileBusy => error.FileBusy,
            error.DiskQuota => error.DiskQuota,
            error.IsDir => error.IsDir,
            error.SymLinkLoop => error.SymLinkLoop,
            error.LinkQuotaExceeded => error.LinkQuotaExceeded,
            error.NameTooLong => error.NameTooLong,
            error.FileNotFound => error.FileNotFound,
            error.SystemResources => error.SystemResources,
            error.NotDir => error.NotDir,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirRenamePreserveImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    @panic("TODO: dirRenamePreserve");
}

fn dirSymLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    os.fs.dirSymLink(getAllocator(userdata), dir.handle, target_path, sym_link_path, .{
        .is_directory = flags.is_directory,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.DiskQuota => error.DiskQuota,
            error.PathAlreadyExists => error.PathAlreadyExists,
            error.FileNotFound => error.FileNotFound,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.NotDir => error.NotDir,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirReadLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    return os.fs.dirReadLink(getAllocator(userdata), dir.handle, sub_path, buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileNotFound => error.FileNotFound,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NotDir => error.NotDir,
            error.NotLink => error.NotLink,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirSetOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    _ = userdata;
    os.fs.fileSetOwner(dir.handle, uid, gid) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirSetFileOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    os.fs.dirSetFileOwner(getAllocator(userdata), dir.handle, sub_path, uid, gid, .{
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirSetPermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    _ = userdata;
    const mode = if (@hasDecl(Io.Dir.Permissions, "toMode")) permissions.toMode() else 0;
    os.fs.fileSetPermissions(dir.handle, mode) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirSetFilePermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    const mode = if (@hasDecl(Io.File.Permissions, "toMode")) permissions.toMode() else 0;
    os.fs.dirSetFilePermissions(getAllocator(userdata), dir.handle, sub_path, mode, .{
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirSetTimestampsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    os.fs.dirSetFileTimestamps(getAllocator(userdata), dir.handle, sub_path, .{
        .atime = timestampToNanos(options.access_timestamp),
        .mtime = timestampToNanos(options.modify_timestamp),
    }, .{
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn dirHardLinkImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    os.fs.dirHardLink(getAllocator(userdata), old_dir.handle, old_sub_path, new_dir.handle, new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.DiskQuota => error.DiskQuota,
            error.PathAlreadyExists => error.PathAlreadyExists,
            error.FileNotFound => error.FileNotFound,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.NotDir => error.NotDir,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn dirCreateFileAtomicImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO: dirCreateFileAtomic");
}

// -----------------------------------------------------------------------------
// File operations
// -----------------------------------------------------------------------------

fn fileStatImpl(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    _ = userdata;
    const aio_stat = os.fs.fstat(file.handle) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
    return aioFileStatToStdIo(aio_stat);
}

fn fileCloseImpl(userdata: ?*anyopaque, files: []const Io.File) void {
    _ = userdata;
    for (files) |file| {
        os.fs.close(file.handle) catch {};
    }
}

fn fileWriteStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = data;
    _ = splat;
    return error.BrokenPipe;
}

fn fileWritePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    _ = userdata;

    // Build iovec array
    var bufs: [17][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    const zio_io = @import("../io.zig");
    const buf_count = zio_io.fillBuf(&bufs, header, data, splat, &splat_buf);

    // Convert to os.fs.iovec_const
    var iovecs: [17]os.fs.iovec_const = undefined;
    for (bufs[0..buf_count], 0..) |buf, i| {
        iovecs[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    const written = os.fs.pwritev(file.handle, iovecs[0..buf_count], offset) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.InputOutput => error.InputOutput,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.BrokenPipe => error.BrokenPipe,
            error.SystemResources => error.SystemResources,
            error.NotOpenForWriting => error.NotOpenForWriting,
            error.DiskQuota => error.DiskQuota,
            error.FileTooBig => error.FileTooBig,
            error.LockViolation => error.LockViolation,
            else => error.Unexpected,
        };
    };

    return written;
}

fn fileReadStreamingImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8) Io.File.Reader.Error!usize {
    _ = userdata;
    _ = file;
    _ = data;
    return error.BrokenPipe;
}

fn fileReadPositionalImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    _ = userdata;

    // Convert to os.fs.iovec
    var iovecs: [16]os.fs.iovec = undefined;
    const iovec_count = @min(data.len, iovecs.len);
    for (data[0..iovec_count], 0..) |buf, i| {
        iovecs[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    const bytes_read = os.fs.preadv(file.handle, iovecs[0..iovec_count], offset) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.InputOutput => error.InputOutput,
            error.IsDir => error.IsDir,
            error.BrokenPipe => error.BrokenPipe,
            error.SystemResources => error.SystemResources,
            error.NotOpenForReading => error.NotOpenForReading,
            else => error.Unexpected,
        };
    };

    return bytes_read;
}

fn fileSeekByImpl(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = relative_offset;
    return error.Unseekable;
}

fn fileSeekToImpl(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = absolute_offset;
    return error.Unseekable;
}

fn fileLengthImpl(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    _ = userdata;
    return os.fs.fileSize(file.handle) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            else => error.Unexpected,
        };
    };
}

fn fileWriteFileStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.File.Writer.WriteFileError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    return error.Unimplemented;
}

fn fileWriteFilePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    _ = offset;
    return error.Unimplemented;
}

fn fileSyncImpl(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    _ = userdata;
    os.fs.fileSync(file.handle, .{}) catch |err| {
        return switch (err) {
            error.InputOutput => error.InputOutput,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.DiskQuota => error.DiskQuota,
            error.AccessDenied => error.AccessDenied,
            else => error.Unexpected,
        };
    };
}

fn fileIsTtyImpl(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileIsTty(io.userdata, file);
}

fn fileEnableAnsiEscapeCodesImpl(userdata: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileEnableAnsiEscapeCodes(io.userdata, file);
}

fn fileSupportsAnsiEscapeCodesImpl(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileSupportsAnsiEscapeCodes(io.userdata, file);
}

fn fileSetLengthImpl(userdata: ?*anyopaque, file: Io.File, length: u64) Io.File.SetLengthError!void {
    _ = userdata;
    os.fs.fileSetSize(file.handle, length) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileTooBig => error.FileTooBig,
            error.InputOutput => error.InputOutput,
            else => error.Unexpected,
        };
    };
}

fn fileSetOwnerImpl(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
    _ = userdata;
    os.fs.fileSetOwner(file.handle, uid, gid) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn fileSetPermissionsImpl(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    _ = userdata;
    const mode = if (@hasDecl(Io.File.Permissions, "toMode")) permissions.toMode() else 0;
    os.fs.fileSetPermissions(file.handle, mode) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn fileSetTimestampsImpl(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    _ = userdata;
    os.fs.fileSetTimestamps(file.handle, .{
        .atime = timestampToNanos(options.access_timestamp),
        .mtime = timestampToNanos(options.modify_timestamp),
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            else => error.Unexpected,
        };
    };
}

fn fileLockImpl(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
    _ = userdata;
    _ = file;
    _ = lock;
    @panic("TODO: fileLock");
}

fn fileTryLockImpl(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
    _ = userdata;
    _ = file;
    _ = lock;
    @panic("TODO: fileTryLock");
}

fn fileUnlockImpl(userdata: ?*anyopaque, file: Io.File) void {
    _ = userdata;
    _ = file;
    @panic("TODO: fileUnlock");
}

fn fileDowngradeLockImpl(userdata: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
    _ = userdata;
    _ = file;
    @panic("TODO: fileDowngradeLock");
}

fn fileRealPathImpl(userdata: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
    _ = userdata;
    return os.fs.dirRealPath(file.handle, out_buffer) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            error.NameTooLong => error.NameTooLong,
            error.SymLinkLoop => error.SymLinkLoop,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

fn fileHardLinkImpl(userdata: ?*anyopaque, file: Io.File, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    os.fs.fileHardLink(getAllocator(userdata), file.handle, new_dir.handle, new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.DiskQuota => error.DiskQuota,
            error.PathAlreadyExists => error.PathAlreadyExists,
            error.FileNotFound => error.FileNotFound,
            error.SymLinkLoop => error.SymLinkLoop,
            error.NameTooLong => error.NameTooLong,
            error.NoSpaceLeft => error.NoSpaceLeft,
            error.NotDir => error.NotDir,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
}

// -----------------------------------------------------------------------------
// Time operations
// -----------------------------------------------------------------------------

fn nowImpl(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    _ = userdata;
    const ms = os.time.now(switch (clock) {
        .awake, .boot => .monotonic,
        .real => .realtime,
        .cpu_process, .cpu_thread => return error.UnsupportedClock,
    });
    return .{ .nanoseconds = @as(i96, ms) * 1_000_000 };
}

fn sleepImpl(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();

    // Convert timeout to duration from now
    const duration = (try timeout.toDurationFromNow(io)) orelse return;

    const ns: i96 = duration.raw.nanoseconds;
    if (ns <= 0) return;

    // Convert nanoseconds to milliseconds
    const ms: i32 = @intCast(@divTrunc(ns, std.time.ns_per_ms));
    if (ms > 0) {
        os.time.sleep(ms);
    }
}

// -----------------------------------------------------------------------------
// Network operations
// -----------------------------------------------------------------------------

fn stdIoIpToZio(addr: Io.net.IpAddress) zio_net.IpAddress {
    return switch (addr) {
        .ip4 => |ip4| zio_net.IpAddress.initIp4(ip4.bytes, ip4.port),
        .ip6 => |ip6| zio_net.IpAddress.initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index),
    };
}

fn zioIpToStdIo(addr: zio_net.IpAddress) Io.net.IpAddress {
    return switch (addr.any.family) {
        std.posix.AF.INET => .{ .ip4 = .{
            .bytes = @bitCast(addr.in.addr),
            .port = std.mem.bigToNative(u16, addr.in.port),
        } },
        std.posix.AF.INET6 => .{ .ip6 = .{
            .bytes = addr.in6.addr,
            .port = std.mem.bigToNative(u16, addr.in6.port),
            .flow = addr.in6.flowinfo,
            .interface = .{ .index = addr.in6.scope_id },
        } },
        else => unreachable,
    };
}

fn netListenIpImpl(userdata: ?*anyopaque, address: Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Server {
    _ = userdata;
    const zio_addr = stdIoIpToZio(address);

    // Create socket
    const domain: os.net.Domain = switch (zio_addr.any.family) {
        os.net.AF.INET => .ipv4,
        os.net.AF.INET6 => .ipv6,
        else => return error.Unexpected,
    };

    const fd = os.net.socket(domain, .stream, .{}) catch return error.Unexpected;
    errdefer os.net.close(fd);

    // Set SO_REUSEADDR if requested
    if (options.reuse_address) {
        // Would need setsockopt - skip for now
    }

    // Bind
    const addr_len: os.net.socklen_t = switch (zio_addr.any.family) {
        os.net.AF.INET => @sizeOf(os.net.sockaddr.in),
        os.net.AF.INET6 => @sizeOf(os.net.sockaddr.in6),
        else => return error.Unexpected,
    };
    os.net.bind(fd, &zio_addr.any, addr_len) catch return error.Unexpected;

    // Listen
    os.net.listen(fd, options.kernel_backlog) catch return error.Unexpected;

    // Get bound address
    var bound_addr: os.net.sockaddr = undefined;
    var bound_addr_len: os.net.socklen_t = @sizeOf(os.net.sockaddr);
    os.net.getsockname(fd, &bound_addr, &bound_addr_len) catch return error.Unexpected;

    return .{
        .socket = .{
            .handle = fd,
            .address = zioIpToStdIo(zio_net.IpAddress.initPosix(&bound_addr, bound_addr_len)),
        },
    };
}

fn netAcceptImpl(userdata: ?*anyopaque, server: Io.net.Socket.Handle) Io.net.Server.AcceptError!Io.net.Stream {
    _ = userdata;

    var client_addr: os.net.sockaddr = undefined;
    var addr_len: os.net.socklen_t = @sizeOf(os.net.sockaddr);

    const client_fd = os.net.accept(server, &client_addr, &addr_len, .{}) catch return error.Unexpected;

    const std_addr: Io.net.IpAddress = switch (client_addr.family) {
        os.net.AF.INET, os.net.AF.INET6 => zioIpToStdIo(zio_net.IpAddress.initPosix(&client_addr, addr_len)),
        else => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    };

    return .{
        .socket = .{
            .handle = client_fd,
            .address = std_addr,
        },
    };
}

fn netBindIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    _ = userdata;
    _ = options;

    const zio_addr = stdIoIpToZio(address.*);

    const domain: os.net.Domain = switch (zio_addr.any.family) {
        os.net.AF.INET => .ipv4,
        os.net.AF.INET6 => .ipv6,
        else => return error.Unexpected,
    };

    const fd = os.net.socket(domain, .dgram, .{}) catch return error.Unexpected;
    errdefer os.net.close(fd);

    const addr_len: os.net.socklen_t = switch (zio_addr.any.family) {
        os.net.AF.INET => @sizeOf(os.net.sockaddr.in),
        os.net.AF.INET6 => @sizeOf(os.net.sockaddr.in6),
        else => return error.Unexpected,
    };
    os.net.bind(fd, &zio_addr.any, addr_len) catch return error.Unexpected;

    var bound_addr: os.net.sockaddr = undefined;
    var bound_addr_len: os.net.socklen_t = @sizeOf(os.net.sockaddr);
    os.net.getsockname(fd, &bound_addr, &bound_addr_len) catch return error.Unexpected;

    return .{
        .handle = fd,
        .address = zioIpToStdIo(zio_net.IpAddress.initPosix(&bound_addr, bound_addr_len)),
    };
}

fn netConnectIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Stream {
    _ = userdata;
    _ = options;

    const zio_addr = stdIoIpToZio(address.*);

    const domain: os.net.Domain = switch (zio_addr.any.family) {
        os.net.AF.INET => .ipv4,
        os.net.AF.INET6 => .ipv6,
        else => return error.Unexpected,
    };

    const fd = os.net.socket(domain, .stream, .{}) catch return error.Unexpected;
    errdefer os.net.close(fd);

    const addr_len: os.net.socklen_t = switch (zio_addr.any.family) {
        os.net.AF.INET => @sizeOf(os.net.sockaddr.in),
        os.net.AF.INET6 => @sizeOf(os.net.sockaddr.in6),
        else => return error.Unexpected,
    };
    os.net.connect(fd, &zio_addr.any, addr_len) catch return error.Unexpected;

    return .{
        .socket = .{
            .handle = fd,
            .address = address.*,
        },
    };
}

fn netListenUnixImpl(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    _ = userdata;

    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const zio_addr = zio_net.UnixAddress.init(address.path) catch return error.Unexpected;

    const fd = os.net.socket(.unix, .stream, .{}) catch return error.Unexpected;
    errdefer os.net.close(fd);

    os.net.bind(fd, &zio_addr.any, @sizeOf(os.net.sockaddr.un)) catch |err| {
        return switch (err) {
            error.AddressInUse => error.AddressInUse,
            error.SymLinkLoop => error.SymLinkLoop,
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };

    os.net.listen(fd, options.kernel_backlog) catch return error.Unexpected;

    return fd;
}

fn netConnectUnixImpl(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    _ = userdata;

    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const zio_addr = zio_net.UnixAddress.init(address.path) catch return error.Unexpected;

    const fd = os.net.socket(.unix, .stream, .{}) catch |err| {
        return switch (err) {
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };
    errdefer os.net.close(fd);

    os.net.connect(fd, &zio_addr.any, @sizeOf(os.net.sockaddr.un)) catch |err| {
        return switch (err) {
            error.SystemResources => error.SystemResources,
            else => error.Unexpected,
        };
    };

    return fd;
}

fn netSendImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    _ = userdata;
    _ = handle;
    _ = messages;
    _ = flags;
    @panic("TODO: netSend");
}

fn netReceiveImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, message_buffer: []Io.net.IncomingMessage, data_buffer: []u8, flags: Io.net.ReceiveFlags, timeout: Io.Timeout) struct { ?Io.net.Socket.ReceiveTimeoutError, usize } {
    _ = userdata;
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    @panic("TODO: netReceive");
}

fn netReadImpl(userdata: ?*anyopaque, src: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    _ = userdata;

    // Convert to iovec
    var iovecs: [16]os.fs.iovec = undefined;
    const iovec_count = @min(data.len, iovecs.len);
    for (data[0..iovec_count], 0..) |buf, i| {
        iovecs[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    return os.net.recv(src, iovecs[0..iovec_count], .{}) catch return error.Unexpected;
}

fn netWriteImpl(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
    _ = userdata;

    // Build buffer array
    var bufs: [17][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    const zio_io = @import("../io.zig");
    const buf_count = zio_io.fillBuf(&bufs, header, data, splat, &splat_buf);

    // Convert to iovec
    var iovecs: [17]os.fs.iovec_const = undefined;
    for (bufs[0..buf_count], 0..) |buf, i| {
        iovecs[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    return os.net.send(dest, iovecs[0..buf_count], .{}) catch return error.Unexpected;
}

fn netCloseImpl(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
    _ = userdata;
    for (handles) |handle| {
        os.net.close(handle);
    }
}

fn netInterfaceNameResolveImpl(userdata: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    _ = userdata;
    _ = name;
    @panic("TODO: netInterfaceNameResolve");
}

fn netInterfaceNameImpl(userdata: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    _ = userdata;
    _ = interface;
    @panic("TODO: netInterfaceName");
}

fn netLookupImpl(userdata: ?*anyopaque, hostname: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    _ = userdata;
    _ = hostname;
    _ = queue;
    _ = options;
    @panic("TODO: netLookup");
}

fn netWriteFileImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    _ = userdata;
    _ = handle;
    _ = header;
    _ = reader;
    _ = count;
    return error.Unexpected;
}

fn netShutdownImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    _ = userdata;
    os.net.shutdown(handle, switch (how) {
        .recv => .receive,
        .send => .send,
        .both => .both,
    }) catch return error.Unexpected;
}

// -----------------------------------------------------------------------------
// Process operations
// -----------------------------------------------------------------------------

fn processExecutableOpenImpl(userdata: ?*anyopaque, flags: Io.File.OpenFlags) std.process.OpenExecutableError!Io.File {
    _ = userdata;
    _ = flags;
    @panic("TODO: processExecutableOpen");
}

fn processExecutablePathImpl(userdata: ?*anyopaque, out_buffer: []u8) std.process.ExecutablePathError!usize {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.processExecutablePath(io.userdata, out_buffer);
}

fn lockStderrImpl(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    _ = userdata;
    _ = mode;
    @panic("TODO: lockStderr");
}

fn tryLockStderrImpl(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    _ = userdata;
    _ = mode;
    return null;
}

fn unlockStderrImpl(userdata: ?*anyopaque) void {
    _ = userdata;
    @panic("TODO: unlockStderr");
}

fn processSetCurrentDirImpl(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
    _ = userdata;
    _ = dir;
    @panic("TODO: processSetCurrentDir");
}

fn processReplaceImpl(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
    _ = userdata;
    _ = options;
    @panic("TODO: processReplace");
}

fn processReplacePathImpl(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
    _ = userdata;
    _ = dir;
    _ = options;
    @panic("TODO: processReplacePath");
}

fn processSpawnImpl(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    _ = userdata;
    _ = options;
    @panic("TODO: processSpawn");
}

fn processSpawnPathImpl(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    _ = userdata;
    _ = dir;
    _ = options;
    @panic("TODO: processSpawnPath");
}

fn childWaitImpl(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    _ = userdata;
    _ = child;
    @panic("TODO: childWait");
}

fn childKillImpl(userdata: ?*anyopaque, child: *std.process.Child) void {
    _ = userdata;
    _ = child;
    @panic("TODO: childKill");
}

fn progressParentFileImpl(userdata: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    _ = userdata;
    @panic("TODO: progressParentFile");
}

fn randomImpl(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.random(io.userdata, buffer);
}

fn randomSecureImpl(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    _ = userdata;
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.randomSecure(io.userdata, buffer);
}

// -----------------------------------------------------------------------------
// Helper functions
// -----------------------------------------------------------------------------

fn aioFileStatToStdIo(aio_stat: os.fs.FileStatInfo) Io.File.Stat {
    const kind: Io.File.Kind = switch (aio_stat.kind) {
        .block_device => .block_device,
        .character_device => .character_device,
        .directory => .directory,
        .named_pipe => .named_pipe,
        .sym_link => .sym_link,
        .file => .file,
        .unix_domain_socket => .unix_domain_socket,
        .whiteout => .whiteout,
        .door => .door,
        .event_port => .event_port,
        .unknown => .unknown,
    };

    return .{
        .inode = aio_stat.inode,
        .nlink = if (Io.File.NLink == u0) 0 else 1,
        .size = aio_stat.size,
        .permissions = @enumFromInt(aio_stat.mode),
        .kind = kind,
        .atime = .{ .nanoseconds = aio_stat.atime },
        .mtime = .{ .nanoseconds = aio_stat.mtime },
        .ctime = .{ .nanoseconds = aio_stat.ctime },
    };
}

fn timestampToNanos(ts: Io.File.SetTimestamp) ?i96 {
    return switch (ts) {
        .unchanged => null,
        .now => @as(i96, @intCast(os.time.now(.realtime))) * std.time.ns_per_ms,
        .new => |t| t.nanoseconds,
    };
}

fn mapFileOpenError(err: os.fs.FileOpenError) Io.File.OpenError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.NoDevice => error.NoDevice,
        error.FileNotFound => error.FileNotFound,
        error.NameTooLong => error.NameTooLong,
        error.SystemResources => error.SystemResources,
        error.FileTooBig => error.FileTooBig,
        error.IsDir => error.IsDir,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.NotDir => error.NotDir,
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.DeviceBusy => error.DeviceBusy,
        error.BadPathName => error.BadPathName,
        error.NetworkNotFound => error.NetworkNotFound,
        error.FileBusy => error.FileBusy,
        else => error.Unexpected,
    };
}

// -----------------------------------------------------------------------------
// VTable
// -----------------------------------------------------------------------------

pub const vtable = Io.VTable{
    .async = asyncImpl,
    .concurrent = concurrentImpl,
    .await = awaitImpl,
    .cancel = cancelImpl,
    .groupAsync = groupAsyncImpl,
    .groupConcurrent = groupConcurrentImpl,
    .groupAwait = groupAwaitImpl,
    .groupCancel = groupCancelImpl,
    .recancel = recancelImpl,
    .swapCancelProtection = swapCancelProtectionImpl,
    .checkCancel = checkCancelImpl,
    .select = selectImpl,
    .futexWait = futexWaitImpl,
    .futexWaitUncancelable = futexWaitUncancelableImpl,
    .futexWake = futexWakeImpl,
    .dirCreateDir = dirCreateDirImpl,
    .dirCreateDirPath = dirCreateDirPathImpl,
    .dirCreateDirPathOpen = dirCreateDirPathOpenImpl,
    .dirOpenDir = dirOpenDirImpl,
    .dirStat = dirStatImpl,
    .dirStatFile = dirStatFileImpl,
    .dirAccess = dirAccessImpl,
    .dirCreateFile = dirCreateFileImpl,
    .dirCreateFileAtomic = dirCreateFileAtomicImpl,
    .dirOpenFile = dirOpenFileImpl,
    .dirClose = dirCloseImpl,
    .dirRead = dirReadImpl,
    .dirRealPath = dirRealPathImpl,
    .dirRealPathFile = dirRealPathFileImpl,
    .dirDeleteFile = dirDeleteFileImpl,
    .dirDeleteDir = dirDeleteDirImpl,
    .dirRename = dirRenameImpl,
    .dirRenamePreserve = dirRenamePreserveImpl,
    .dirSymLink = dirSymLinkImpl,
    .dirReadLink = dirReadLinkImpl,
    .dirSetOwner = dirSetOwnerImpl,
    .dirSetFileOwner = dirSetFileOwnerImpl,
    .dirSetPermissions = dirSetPermissionsImpl,
    .dirSetFilePermissions = dirSetFilePermissionsImpl,
    .dirSetTimestamps = dirSetTimestampsImpl,
    .dirHardLink = dirHardLinkImpl,
    .fileStat = fileStatImpl,
    .fileClose = fileCloseImpl,
    .fileWriteStreaming = fileWriteStreamingImpl,
    .fileWritePositional = fileWritePositionalImpl,
    .fileReadStreaming = fileReadStreamingImpl,
    .fileReadPositional = fileReadPositionalImpl,
    .fileSeekBy = fileSeekByImpl,
    .fileSeekTo = fileSeekToImpl,
    .fileLength = fileLengthImpl,
    .fileWriteFileStreaming = fileWriteFileStreamingImpl,
    .fileWriteFilePositional = fileWriteFilePositionalImpl,
    .fileSync = fileSyncImpl,
    .fileIsTty = fileIsTtyImpl,
    .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodesImpl,
    .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodesImpl,
    .fileSetLength = fileSetLengthImpl,
    .fileSetOwner = fileSetOwnerImpl,
    .fileSetPermissions = fileSetPermissionsImpl,
    .fileSetTimestamps = fileSetTimestampsImpl,
    .fileLock = fileLockImpl,
    .fileTryLock = fileTryLockImpl,
    .fileUnlock = fileUnlockImpl,
    .fileDowngradeLock = fileDowngradeLockImpl,
    .fileRealPath = fileRealPathImpl,
    .fileHardLink = fileHardLinkImpl,
    .processExecutableOpen = processExecutableOpenImpl,
    .processExecutablePath = processExecutablePathImpl,
    .lockStderr = lockStderrImpl,
    .tryLockStderr = tryLockStderrImpl,
    .unlockStderr = unlockStderrImpl,
    .processSetCurrentDir = processSetCurrentDirImpl,
    .processReplace = processReplaceImpl,
    .processReplacePath = processReplacePathImpl,
    .processSpawn = processSpawnImpl,
    .processSpawnPath = processSpawnPathImpl,
    .childWait = childWaitImpl,
    .childKill = childKillImpl,
    .progressParentFile = progressParentFileImpl,
    .random = randomImpl,
    .randomSecure = randomSecureImpl,
    .now = nowImpl,
    .sleep = sleepImpl,
    .netListenIp = netListenIpImpl,
    .netAccept = netAcceptImpl,
    .netBindIp = netBindIpImpl,
    .netConnectIp = netConnectIpImpl,
    .netListenUnix = netListenUnixImpl,
    .netConnectUnix = netConnectUnixImpl,
    .netSend = netSendImpl,
    .netReceive = netReceiveImpl,
    .netRead = netReadImpl,
    .netWrite = netWriteImpl,
    .netClose = netCloseImpl,
    .netWriteFile = netWriteFileImpl,
    .netShutdown = netShutdownImpl,
    .netInterfaceNameResolve = netInterfaceNameResolveImpl,
    .netInterfaceName = netInterfaceNameImpl,
    .netLookup = netLookupImpl,
};

pub fn fromRuntime(rt: *Runtime) Io {
    return Io{
        .userdata = @ptrCast(rt),
        .vtable = &vtable,
    };
}

pub fn toRuntime(io: Io) *Runtime {
    return @ptrCast(@alignCast(io.userdata));
}
