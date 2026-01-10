// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const aio = @import("ev/root.zig");

pub const Io = if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) @import("stdx").Io else std.Io;

const Runtime = @import("runtime.zig").Runtime;
const getNextExecutor = @import("runtime.zig").getNextExecutor;
const AnyTask = @import("runtime/task.zig").AnyTask;
const Closure = @import("runtime/task.zig").Closure;
const CreateOptions = @import("runtime/task.zig").CreateOptions;
const Awaitable = @import("runtime/awaitable.zig").Awaitable;
const Group = @import("runtime/group.zig").Group;
const groupSpawnTask = @import("runtime/group.zig").groupSpawnTask;
const select = @import("select.zig");
const zio_net = @import("net.zig");
const zio_fs = @import("fs.zig");
const os = @import("os/root.zig");
const Futex = @import("sync/Futex.zig");
const CompactWaitQueue = @import("utils/wait_queue.zig").CompactWaitQueue;

fn asyncImpl(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*Io.AnyFuture {
    return concurrentImpl(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // If we can't schedule asynchronously, execute synchronously
        start(context.ptr, result.ptr);
        return null;
    };
}

fn concurrentImpl(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Check if runtime is shutting down
    if (rt.shutting_down.load(.acquire)) {
        return error.ConcurrencyUnavailable;
    }

    // Pick an executor (round-robin)
    const executor = getNextExecutor(rt);

    // Create the task using AnyTask.create
    const task = AnyTask.create(
        executor,
        result_len,
        result_alignment,
        context,
        context_alignment,
        .{ .regular = start },
        CreateOptions{},
    ) catch return error.ConcurrencyUnavailable;
    errdefer task.closure.free(AnyTask, executor.runtime, task);

    // Add to global awaitable registry
    rt.tasks.add(&task.awaitable);
    errdefer _ = rt.tasks.remove(&task.awaitable);

    // Increment ref count for the Future BEFORE scheduling
    // This prevents race where task completes before we create the Future
    task.awaitable.ref_count.incr();
    errdefer _ = task.awaitable.ref_count.decr();

    // Schedule the task to run (handles cross-thread notification)
    executor.scheduleTask(task, .maybe_remote);

    // Return the awaitable as AnyFuture
    return @ptrCast(&task.awaitable);
}

fn awaitOrCancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment, should_cancel: bool) void {
    _ = result_alignment;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const awaitable: *Awaitable = @ptrCast(@alignCast(any_future));

    // Request cancellation if needed
    if (should_cancel and !awaitable.done.load(.acquire)) {
        awaitable.cancel();
    }

    // Wait for completion
    _ = select.waitUntilComplete(rt, awaitable);

    // Copy result from task to result buffer
    const task = AnyTask.fromAwaitable(awaitable);
    const task_result = task.closure.getResultSlice(AnyTask, task);
    @memcpy(result, task_result);

    // Release the awaitable (decrements ref count, may destroy)
    rt.releaseAwaitable(awaitable, false);
}

fn awaitImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, false);
}

fn cancelImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, true);
}

fn cancelRequestedImpl(userdata: ?*anyopaque) bool {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    rt.checkCanceled() catch return true;
    return false;
}

fn groupAsyncImpl(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Io.Cancelable!void) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    groupSpawnTask(Group.fromStd(group), rt, context, context_alignment, start) catch {
        // If we can't schedule, run synchronously like std.Io.Threaded does
        start(context.ptr) catch |err| switch (err) {
            // Propagate cancellation to the caller
            error.Canceled => recancelImpl(userdata),
        };
    };
}

fn groupConcurrentImpl(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) Io.Cancelable!void) Io.ConcurrentError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    groupSpawnTask(Group.fromStd(group), rt, context, context_alignment, start) catch {
        return error.ConcurrencyUnavailable;
    };
}

fn groupAwaitImpl(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) Io.Cancelable!void {
    _ = initial_token;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return Group.fromStd(group).wait(rt);
}

fn groupCancelImpl(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    _ = initial_token;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    Group.fromStd(group).cancel(rt);
}

fn selectImpl(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Io.Cancelable!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const awaitables: []const *Awaitable = @ptrCast(futures);
    return select.selectAwaitables(rt, awaitables);
}

fn recancelImpl(userdata: ?*anyopaque) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const task = rt.getCurrentTask();
    task.awaitable.recancel();
}

fn swapCancelProtectionImpl(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    switch (new) {
        .blocked => {
            rt.beginShield();
            return .unblocked;
        },
        .unblocked => {
            rt.endShield();
            return .blocked;
        },
    }
}

fn checkCancelImpl(userdata: ?*anyopaque) Io.Cancelable!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    try rt.checkCanceled();
}

fn futexWaitImpl(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert Io.Timeout to nanoseconds using the built-in conversion
    const timeout_ns: u64 = if (timeout.toDurationFromNow(rt.io()) catch return error.Canceled) |duration| blk: {
        const ns = duration.raw.nanoseconds;
        if (ns <= 0) break :blk 1; // Already expired, use minimum timeout
        break :blk @intCast(ns);
    } else 0; // .none -> 0 means wait forever in our Futex API

    Futex.timedWait(rt, ptr, expected, timeout_ns) catch |err| switch (err) {
        error.Timeout => return error.Canceled, // Io treats timeout as cancellation
        error.Canceled => return error.Canceled,
    };
}

fn futexWaitUncancelableImpl(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    rt.beginShield();
    defer rt.endShield();

    Futex.wait(rt, ptr, expected) catch |err| switch (err) {
        error.Canceled => unreachable, // Shielded, should not happen
    };
}

fn futexWakeImpl(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    Futex.wake(rt, ptr, max_waiters);
}

fn dirCreateDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    @panic("TODO");
}

fn dirCreateDirPathImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    @panic("TODO");
}

fn dirCreateDirPathOpenImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
    @panic("TODO");
}

fn dirStatImpl(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const aio_stat = zio_dir.stat(rt) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return aioFileStatToStdIo(aio_stat);
}

fn dirStatFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    // StatFileOptions only has follow_symlinks, which is the default behavior for fstatat
    // We don't support not following symlinks yet
    if (!options.follow_symlinks) {
        return error.Unexpected;
    }

    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const aio_stat = zio_dir.statPath(rt, sub_path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.FileNotFound => return error.FileNotFound,
        error.NameTooLong => return error.NameTooLong,
        error.NotDir => return error.NotDir,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return aioFileStatToStdIo(aio_stat);
}

fn dirAccessImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirCreateFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.CreateFlags) Io.File.OpenError!Io.File {
    // Unsupported options
    if (flags.lock != .none or flags.lock_nonblocking) return error.Unexpected;

    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const aio_flags: os.fs.FileCreateFlags = .{
        .read = flags.read,
        .truncate = flags.truncate,
        .exclusive = flags.exclusive,
    };

    const file = zio_dir.createFile(rt, sub_path, aio_flags) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.PermissionDenied => return error.PermissionDenied,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
        error.NoDevice => return error.NoDevice,
        error.FileNotFound => return error.FileNotFound,
        error.NameTooLong => return error.NameTooLong,
        error.SystemResources => return error.SystemResources,
        error.FileTooBig => return error.FileTooBig,
        error.IsDir => return error.IsDir,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.NotDir => return error.NotDir,
        error.PathAlreadyExists => return error.PathAlreadyExists,
        error.DeviceBusy => return error.DeviceBusy,
        error.BadPathName => return error.BadPathName,
        error.InvalidUtf8 => return error.Unexpected,
        error.NetworkNotFound => return error.NetworkNotFound,
        error.FileBusy => return error.FileBusy,
        else => return error.Unexpected,
    };

    return .{ .handle = file.fd };
}

fn dirOpenFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.OpenFlags) Io.File.OpenError!Io.File {
    // Unsupported options
    if (flags.lock != .none or flags.lock_nonblocking or flags.allow_ctty or !flags.follow_symlinks) {
        return error.Unexpected;
    }

    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const aio_flags: os.fs.FileOpenFlags = .{
        .mode = switch (flags.mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        },
    };

    const file = zio_dir.openFile(rt, sub_path, aio_flags) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.PermissionDenied => return error.PermissionDenied,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
        error.NoDevice => return error.NoDevice,
        error.FileNotFound => return error.FileNotFound,
        error.NameTooLong => return error.NameTooLong,
        error.SystemResources => return error.SystemResources,
        error.FileTooBig => return error.FileTooBig,
        error.IsDir => return error.IsDir,
        error.NoSpaceLeft => return error.NoSpaceLeft,
        error.NotDir => return error.NotDir,
        error.PathAlreadyExists => return error.PathAlreadyExists,
        error.DeviceBusy => return error.DeviceBusy,
        error.BadPathName => return error.BadPathName,
        error.InvalidUtf8 => return error.Unexpected,
        error.NetworkNotFound => return error.NetworkNotFound,
        error.FileBusy => return error.FileBusy,
        else => return error.Unexpected,
    };

    return .{ .handle = file.fd };
}

fn dirOpenDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirCloseImpl(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
    _ = userdata;
    _ = dirs;
    @panic("TODO");
}

fn dirReadImpl(userdata: ?*anyopaque, reader: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    _ = userdata;
    _ = reader;
    _ = entries;
    @panic("TODO");
}

fn dirRealPathImpl(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
    _ = userdata;
    _ = dir;
    _ = out_buffer;
    @panic("TODO");
}

fn dirRealPathFileImpl(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
    _ = userdata;
    _ = dir;
    _ = path_name;
    _ = out_buffer;
    @panic("TODO");
}

fn dirDeleteFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    @panic("TODO");
}

fn dirDeleteDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    @panic("TODO");
}

fn dirRenameImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    @panic("TODO");
}

fn dirRenamePreserveImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    @panic("TODO");
}

fn dirSymLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    _ = userdata;
    _ = dir;
    _ = target_path;
    _ = sym_link_path;
    _ = flags;
    @panic("TODO");
}

fn dirReadLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = buffer;
    @panic("TODO");
}

fn dirSetOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    _ = userdata;
    _ = dir;
    _ = uid;
    _ = gid;
    @panic("TODO");
}

fn dirSetFileOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = uid;
    _ = gid;
    _ = options;
    @panic("TODO");
}

fn dirSetPermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = permissions;
    @panic("TODO");
}

fn dirSetFilePermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = permissions;
    _ = options;
    @panic("TODO");
}

fn dirSetTimestampsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn dirHardLinkImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    _ = userdata;
    _ = old_dir;
    _ = old_sub_path;
    _ = new_dir;
    _ = new_sub_path;
    _ = options;
    @panic("TODO");
}

fn dirCreateFileAtomicImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

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
        .nlink = if (Io.File.NLink == u0) 0 else 1, // TODO: get actual nlink from stat
        .size = aio_stat.size,
        .permissions = @enumFromInt(aio_stat.mode),
        .kind = kind,
        .atime = .{ .nanoseconds = aio_stat.atime },
        .mtime = .{ .nanoseconds = aio_stat.mtime },
        .ctime = .{ .nanoseconds = aio_stat.ctime },
    };
}

fn fileStatImpl(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_file = zio_fs.File.fromFd(file.handle);

    const aio_stat = zio_file.stat(rt) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return aioFileStatToStdIo(aio_stat);
}

fn fileCloseImpl(userdata: ?*anyopaque, files: []const Io.File) void {
    // TODO: batch close operations
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    for (files) |file| {
        var zio_file = zio_fs.File.fromFd(file.handle);
        zio_file.close(rt);
    }
}

fn fileWriteStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = data;
    _ = splat;
    // TODO: splat != 1 case
    // Cannot track position with bare file handle - Io.File is just a handle
    return error.BrokenPipe;
}

fn fileWritePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    if (splat != 1) @panic("TODO: splat != 1"); // splat=1 is normal "write each buffer once" case
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Combine header and data into one buffer list
    if (header.len == 0 and data.len == 0) return 0;

    // For now, just write data (ignoring header for simplicity in this stub)
    if (data.len == 0) {
        var buf = [_][]const u8{header};
        return zio_fs.fileWritePositional(rt, file.handle, &buf, offset) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Unexpected,
        };
    }

    return zio_fs.fileWritePositional(rt, file.handle, data, offset) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn fileReadStreamingImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8) Io.File.Reader.Error!usize {
    _ = userdata;
    _ = file;
    _ = data;
    // Cannot track position with bare file handle - Io.File is just a handle
    return error.BrokenPipe;
}

fn fileReadPositionalImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return zio_fs.fileReadPositional(rt, file.handle, data, offset);
}

fn fileSeekByImpl(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = relative_offset;
    // Cannot seek without position tracking - Io.File is just a handle
    return error.Unseekable;
}

fn fileSeekToImpl(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
    _ = userdata;
    _ = file;
    _ = absolute_offset;
    // Cannot seek without position tracking - Io.File is just a handle
    return error.Unseekable;
}

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
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);

    // Convert timeout to duration from now (handles none/duration/deadline cases)
    const duration = (try timeout.toDurationFromNow(io)) orelse return;

    // Convert nanoseconds to milliseconds
    const ns: i96 = duration.raw.nanoseconds;
    if (ns <= 0) return;
    const ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));

    try rt.sleep(ms);
}

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
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address);
    const zio_options: zio_net.IpAddress.ListenOptions = .{
        .reuse_address = options.reuse_address,
        .kernel_backlog = options.kernel_backlog,
    };
    const server = zio_net.netListenIp(rt, zio_addr, zio_options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .socket = .{
            .handle = server.socket.handle,
            .address = zioIpToStdIo(server.socket.address.ip),
        },
    };
}

fn netAcceptImpl(userdata: ?*anyopaque, server: Io.net.Socket.Handle) Io.net.Server.AcceptError!Io.net.Stream {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const stream = zio_net.netAccept(rt, server) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };

    // Convert address based on family
    // Note: Io.net.Stream.socket.address is IpAddress only, so for Unix sockets we use a fake address
    const std_addr: Io.net.IpAddress = switch (stream.socket.address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => zioIpToStdIo(stream.socket.address.ip),
        std.posix.AF.UNIX => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } }, // Fake address for Unix sockets
        else => unreachable,
    };

    return .{
        .socket = .{
            .handle = stream.socket.handle,
            .address = std_addr,
        },
    };
}

fn netBindIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    _ = options; // std.Io BindOptions don't include reuse_address, use zio API directly for that
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const socket = zio_net.netBindIp(rt, zio_addr, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .handle = socket.handle,
        .address = zioIpToStdIo(socket.address.ip),
    };
}

fn netConnectIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Stream {
    _ = options; // No options used in zio yet
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const stream = zio_net.netConnectIp(rt, zio_addr) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
    return .{
        .socket = .{
            .handle = stream.socket.handle,
            .address = zioIpToStdIo(stream.socket.address.ip),
        },
    };
}

fn netListenUnixImpl(userdata: ?*anyopaque, address: *const Io.net.UnixAddress, options: Io.net.UnixAddress.ListenOptions) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert Io.net.UnixAddress (path) to zio UnixAddress (sockaddr)
    const zio_addr = zio_net.UnixAddress.init(address.path) catch {
        // NameTooLong isn't in the error set, so treat as Unexpected
        return error.Unexpected;
    };
    const zio_options: zio_net.UnixAddress.ListenOptions = .{
        .kernel_backlog = options.kernel_backlog,
    };

    const server = zio_net.netListenUnix(rt, zio_addr, zio_options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AddressInUse => return error.AddressInUse,
        error.SystemResources => return error.SystemResources,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.FileNotFound => return error.FileNotFound,
        error.NotDir => return error.NotDir,
        error.ReadOnlyFileSystem => return error.ReadOnlyFileSystem,
        else => return error.Unexpected,
    };

    return server.socket.handle;
}

fn netConnectUnixImpl(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert Io.net.UnixAddress (path) to zio UnixAddress (sockaddr)
    const zio_addr = zio_net.UnixAddress.init(address.path) catch {
        // NameTooLong isn't in the error set, so treat as Unexpected
        return error.Unexpected;
    };

    const stream = zio_net.netConnectUnix(rt, zio_addr) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.SystemResources => return error.SystemResources,
        // Map any other error to Unexpected
        else => return error.Unexpected,
    };

    return stream.socket.handle;
}

fn netSendImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    _ = userdata;
    _ = handle;
    _ = messages;
    _ = flags;
    @panic("TODO");
}

fn netReceiveImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, message_buffer: []Io.net.IncomingMessage, data_buffer: []u8, flags: Io.net.ReceiveFlags, timeout: Io.Timeout) struct { ?Io.net.Socket.ReceiveTimeoutError, usize } {
    _ = userdata;
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    @panic("TODO");
}

fn netReadImpl(userdata: ?*anyopaque, src: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return zio_net.netRead(rt, src, data) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn netWriteImpl(userdata: ?*anyopaque, dest: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    return zio_net.netWrite(rt, dest, header, data, splat) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return error.Unexpected,
    };
}

fn netCloseImpl(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
    // TODO: batch close operations
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    for (handles) |handle| {
        zio_net.netClose(rt, handle);
    }
}

fn netInterfaceNameResolveImpl(userdata: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    _ = userdata;
    _ = name;
    @panic("TODO");
}

fn netInterfaceNameImpl(userdata: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    _ = userdata;
    _ = interface;
    @panic("TODO");
}

fn netLookupImpl(userdata: ?*anyopaque, hostname: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);
    defer queue.close(io);

    // Call the zio DNS lookup (uses thread pool internally)
    var iter = zio_net.lookupHost(rt, hostname.bytes, options.port) catch |err| {
        return switch (err) {
            error.UnknownHostName => error.UnknownHostName,
            error.NameServerFailure => error.NameServerFailure,
            error.HostLacksNetworkAddresses => error.UnknownHostName,
            error.TemporaryNameServerFailure => error.NameServerFailure,
            else => error.NameServerFailure,
        };
    };
    defer iter.deinit();

    // Push canonical name first (use the original hostname)
    @memcpy(options.canonical_name_buffer[0..hostname.bytes.len], hostname.bytes);
    const canonical_name = Io.net.HostName{
        .bytes = options.canonical_name_buffer[0..hostname.bytes.len],
    };
    queue.putOneUncancelable(io, .{ .canonical_name = canonical_name }) catch |err| switch (err) {
        error.Closed => unreachable, // We close the queue, not the caller
    };

    // Iterate through resolved addresses
    while (iter.next()) |zio_addr| {
        // Filter by address family if specified
        if (options.family) |requested_family| {
            const addr_family: Io.net.IpAddress.Family = switch (zio_addr.any.family) {
                std.posix.AF.INET => .ip4,
                std.posix.AF.INET6 => .ip6,
                else => continue,
            };
            if (addr_family != requested_family) continue;
        }

        // Convert zio IpAddress to Io.net.IpAddress
        const std_addr = zioIpToStdIo(zio_addr);
        queue.putOneUncancelable(io, .{ .address = std_addr }) catch |err| switch (err) {
            error.Closed => unreachable, // We close the queue, not the caller
        };
    }
}

// Stub implementations for missing VTable fields
fn fileLengthImpl(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    _ = userdata;
    _ = file;
    @panic("TODO: fileLength");
}

fn fileWriteFileStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.File.Writer.WriteFileError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    @panic("TODO: fileWriteFileStreaming");
}

fn fileWriteFilePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
    _ = userdata;
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    _ = offset;
    @panic("TODO: fileWriteFilePositional");
}

fn fileSyncImpl(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    _ = userdata;
    _ = file;
    @panic("TODO: fileSync");
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
    _ = file;
    _ = length;
    @panic("TODO: fileSetLength");
}

fn fileSetOwnerImpl(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
    _ = userdata;
    _ = file;
    _ = uid;
    _ = gid;
    @panic("TODO: fileSetOwner");
}

fn fileSetPermissionsImpl(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    _ = userdata;
    _ = file;
    _ = permissions;
    @panic("TODO: fileSetPermissions");
}

fn fileSetTimestampsImpl(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    _ = userdata;
    _ = file;
    _ = options;
    @panic("TODO: fileSetTimestamps");
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
    _ = file;
    _ = out_buffer;
    @panic("TODO: fileRealPath");
}

fn fileHardLinkImpl(userdata: ?*anyopaque, file: Io.File, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    _ = userdata;
    _ = file;
    _ = new_dir;
    _ = new_sub_path;
    _ = options;
    @panic("TODO: fileHardLink");
}

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

fn netWriteFileImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    _ = userdata;
    _ = handle;
    _ = header;
    _ = reader;
    _ = count;
    @panic("TODO: netWriteFile");
}

fn netShutdownImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    _ = userdata;
    _ = handle;
    _ = how;
    @panic("TODO: netShutdown");
}

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

test "Io: basic" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = fromRuntime(rt);
    try std.testing.expect(io.vtable == &vtable);
}

test "Io: async/await pattern" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn computeValue(x: i32) i32 {
            return x * 2 + 10;
        }

        fn mainTask(io: Io) !void {
            // Create async future
            var future = io.async(computeValue, .{21});
            defer _ = future.cancel(io);

            // Await the result
            const result = future.await(io);
            try std.testing.expectEqual(52, result);
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: concurrent/await pattern" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn computeValue(x: i32) i32 {
            return x * 2 + 10;
        }

        fn mainTask(io: Io) !void {
            // Create concurrent future (guaranteed async)
            var future = try io.concurrent(computeValue, .{21});
            defer _ = future.cancel(io);

            // Await the result
            const result = future.await(io);
            try std.testing.expectEqual(52, result);
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: now and sleep" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    // Get current time
    const t1 = try Io.Clock.now(.awake, io);

    // Sleep for 10ms
    try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

    // Get time after sleep
    const t2 = try Io.Clock.now(.awake, io);

    // Verify time moved forward
    const elapsed = t1.durationTo(t2);
    try std.testing.expect(elapsed.nanoseconds >= 10 * std.time.ns_per_ms);
}

test "Io: realtime clock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const t1 = try Io.Clock.Timestamp.now(io, .real);

    // Realtime clock should return a reasonable timestamp (after 2020-01-01)
    const jan_2020_ns: i96 = 1577836800 * 1_000_000_000;
    try std.testing.expect(t1.raw.nanoseconds >= jan_2020_ns);

    try io.sleep(.{ .nanoseconds = 10 * 1_000_000 }, .real);

    const t2 = try Io.Clock.Timestamp.now(io, .real);
    const elapsed = t1.durationTo(t2);
    try std.testing.expect(elapsed.raw.nanoseconds >= 10 * 1_000_000);
}

test "Io: select" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn fastTask() i32 {
            return 42;
        }

        fn slowTask(io: Io) !i32 {
            try io.sleep(.{ .nanoseconds = 100 * 1_000_000 }, .awake);
            return 99;
        }

        fn mainTask(io: Io) !void {
            var fast = io.async(fastTask, .{});
            defer _ = fast.cancel(io);

            var slow = io.async(slowTask, .{io});
            defer _ = slow.cancel(io) catch {};

            const result = try io.select(.{ .fast = &fast, .slow = &slow });
            switch (result) {
                .fast => |val| try std.testing.expectEqual(42, val),
                .slow => |val| try std.testing.expectEqual(99, try val),
            }
            try std.testing.expectEqual(.fast, std.meta.activeTag(result));
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: TCP listen/accept/connect/read/write IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            const addr = Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
            var server = try addr.listen(io, .{});
            defer server.socket.close(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, server });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: Io, server: *Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);
        }

        fn clientFn(io: Io, server: Io.net.Server) !void {
            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: TCP listen/accept/connect/read/write IPv6" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            const addr = Io.net.IpAddress{
                .ip6 = .{
                    .bytes = .{0} ** 15 ++ .{1}, // ::1
                    .port = 0,
                },
            };
            var server = addr.listen(io, .{}) catch |err| {
                if (err == error.AddressNotAvailable) return error.SkipZigTest;
                return err;
            };
            defer server.socket.close(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, server });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: Io, server: *Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);
        }

        fn clientFn(io: Io, server: Io.net.Server) !void {
            const stream = try server.socket.address.connect(io, .{ .mode = .stream });
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: UDP bind IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const addr = Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const socket = try addr.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    // Verify we got a valid address with ephemeral port
    try std.testing.expect(socket.address.ip4.port != 0);
}

test "Io: UDP bind IPv6" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const addr = Io.net.IpAddress{
        .ip6 = .{
            .bytes = .{0} ** 15 ++ .{1}, // ::1
            .port = 0,
        },
    };
    const socket = addr.bind(io, .{ .mode = .dgram }) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
    defer socket.close(io);

    // Verify we got a valid address with ephemeral port
    try std.testing.expect(socket.address.ip6.port != 0);
}

test "Io: Mutex lock/unlock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    var mutex: Io.Mutex = .init;
    var shared_counter: u32 = 0;

    // Lock and increment counter
    try mutex.lock(io);
    shared_counter += 1;
    mutex.unlock(io);

    try std.testing.expectEqual(@as(u32, 1), shared_counter);

    // Test tryLock
    try std.testing.expect(mutex.tryLock());
    shared_counter += 1;
    mutex.unlock(io);

    try std.testing.expectEqual(@as(u32, 2), shared_counter);
}

test "Io: Mutex concurrent access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            var mutex: Io.Mutex = .init;
            var shared_counter: u32 = 0;

            var future1 = try io.concurrent(incrementTask, .{ io, &mutex, &shared_counter });
            defer future1.cancel(io) catch {};

            var future2 = try io.concurrent(incrementTask, .{ io, &mutex, &shared_counter });
            defer future2.cancel(io) catch {};

            try future1.await(io);
            try future2.await(io);

            try std.testing.expectEqual(@as(u32, 200), shared_counter);
        }

        fn incrementTask(io: Io, mutex: *Io.Mutex, counter: *u32) !void {
            for (0..100) |_| {
                try mutex.lock(io);
                defer mutex.unlock(io);
                counter.* += 1;
            }
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: Condition wait/signal" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            var mutex: Io.Mutex = .init;
            var condition = Io.Condition.init;
            var ready = false;

            var waiter_future = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready });
            defer waiter_future.cancel(io) catch {};

            var signaler_future = try io.concurrent(signalerTask, .{ io, &mutex, &condition, &ready });
            defer signaler_future.cancel(io) catch {};

            try waiter_future.await(io);
            try signaler_future.await(io);

            try std.testing.expect(ready);
        }

        fn waiterTask(io: Io, mutex: *Io.Mutex, condition: *Io.Condition, ready_flag: *bool) !void {
            try mutex.lock(io);
            defer mutex.unlock(io);

            while (!ready_flag.*) {
                try condition.wait(io, mutex);
            }
        }

        fn signalerTask(io: Io, mutex: *Io.Mutex, condition: *Io.Condition, ready_flag: *bool) !void {
            // Give waiter time to start waiting
            try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

            try mutex.lock(io);
            ready_flag.* = true;
            mutex.unlock(io);

            condition.signal(io);
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: Condition broadcast" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            var mutex: Io.Mutex = .init;
            var condition = Io.Condition.init;
            var ready = false;
            var count = std.atomic.Value(u32).init(0);

            var waiter1 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter1.cancel(io) catch {};

            var waiter2 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter2.cancel(io) catch {};

            var waiter3 = try io.concurrent(waiterTask, .{ io, &mutex, &condition, &ready, &count });
            defer waiter3.cancel(io) catch {};

            // Give waiters time to start waiting
            try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

            try mutex.lock(io);
            ready = true;
            mutex.unlock(io);

            condition.broadcast(io);

            try waiter1.await(io);
            try waiter2.await(io);
            try waiter3.await(io);

            try std.testing.expectEqual(@as(u32, 3), count.load(.monotonic));
        }

        fn waiterTask(io: Io, mutex: *Io.Mutex, condition: *Io.Condition, ready_flag: *bool, counter: *std.atomic.Value(u32)) !void {
            try mutex.lock(io);
            defer mutex.unlock(io);

            while (!ready_flag.*) {
                try condition.wait(io, mutex);
            }

            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: Unix domain socket listen/accept/connect/read/write" {
    if (!zio_net.has_unix_sockets) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            // Use a simple path for the socket
            const socket_path = "test_stdio_unix.sock";
            defer os.fs.unlinkat(std.testing.allocator, os.fs.cwd(), socket_path) catch {};

            const addr = try Io.net.UnixAddress.init(socket_path);
            var server = try addr.listen(io, .{});
            defer server.deinit(io);

            var server_future = try io.concurrent(serverFn, .{ io, &server });
            defer server_future.cancel(io) catch {};

            var client_future = try io.concurrent(clientFn, .{ io, addr });
            defer client_future.cancel(io) catch {};

            try server_future.await(io);
            try client_future.await(io);
        }

        fn serverFn(io: Io, server: *Io.net.Server) !void {
            const stream = try server.accept(io);
            defer stream.close(io);

            var buf: [32]u8 = undefined;
            var reader = stream.reader(io, &buf);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello unix", line);
        }

        fn clientFn(io: Io, addr: Io.net.UnixAddress) !void {
            const stream = try addr.connect(io);
            defer stream.close(io);

            var write_buf: [32]u8 = undefined;
            var writer = stream.writer(io, &write_buf);
            try writer.interface.writeAll("hello unix\n");
            try writer.interface.flush();
        }
    };

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()}, .{});
    try handle.join(rt);
}

test "Io: File close" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_file_close.txt";
    defer os.fs.unlinkat(std.testing.allocator, cwd.handle, file_path) catch {};

    // Create file using Io.Dir
    const file = try cwd.createFile(io, file_path, .{});

    // Test that close works
    file.close(io);
}

test "Io: DNS lookup localhost" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const io = rt.io();
    const hostname = try Io.net.HostName.init("localhost");

    var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
    var lookup_buffer: [32]Io.net.HostName.LookupResult = undefined;
    var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);

    try hostname.lookup(io, &lookup_queue, .{
        .port = 80,
        .canonical_name_buffer = &canonical_name_buffer,
    });

    var saw_canonical_name = false;
    var address_count: usize = 0;

    while (lookup_queue.getOne(io)) |result| {
        switch (result) {
            .address => |_| {
                address_count += 1;
            },
            .canonical_name => |_| {
                saw_canonical_name = true;
            },
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {}, // Queue closed, done reading
    }

    try std.testing.expect(saw_canonical_name);
    try std.testing.expect(address_count > 0);
}

test "Io: DNS lookup numeric IP" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const io = rt.io();
    const hostname = try Io.net.HostName.init("127.0.0.1");

    var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
    var lookup_buffer: [32]Io.net.HostName.LookupResult = undefined;
    var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);

    try hostname.lookup(io, &lookup_queue, .{
        .port = 8080,
        .canonical_name_buffer = &canonical_name_buffer,
    });

    var saw_canonical_name = false;
    var address_count: usize = 0;
    var found_correct_port = false;

    while (lookup_queue.getOne(io)) |result| {
        switch (result) {
            .address => |addr| {
                address_count += 1;
                if (addr.ip4.port == 8080) {
                    found_correct_port = true;
                }
            },
            .canonical_name => |_| {
                saw_canonical_name = true;
            },
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {}, // Queue closed, done reading
    }

    try std.testing.expect(saw_canonical_name);
    try std.testing.expectEqual(@as(usize, 1), address_count);
    try std.testing.expect(found_correct_port);
}

test "Io: DNS lookup with family filter" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const io = rt.io();
    const hostname = try Io.net.HostName.init("localhost");

    var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
    var lookup_buffer: [32]Io.net.HostName.LookupResult = undefined;
    var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);

    try hostname.lookup(io, &lookup_queue, .{
        .port = 80,
        .canonical_name_buffer = &canonical_name_buffer,
        .family = .ip4,
    });

    var address_count: usize = 0;

    while (lookup_queue.getOne(io)) |result| {
        switch (result) {
            .address => |addr| {
                address_count += 1;
                // Verify it's IPv4
                try std.testing.expect(addr == .ip4);
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {}, // Queue closed, done reading
    }

    try std.testing.expect(address_count > 0);
}

test "Io: Dir createFile/openFile" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const file_path = "test_stdio_dir_file.txt";
    const cwd = Io.Dir.cwd();

    // Create a new file
    const created_file = try cwd.createFile(io, file_path, .{});
    defer os.fs.unlinkat(std.testing.allocator, cwd.handle, file_path) catch {};

    // Write some data
    var write_buf = [_][]const u8{"hello world"};
    _ = try created_file.writePositional(io, &write_buf, 0);
    created_file.close(io);

    // Open the file for reading
    const opened_file = try cwd.openFile(io, file_path, .{ .mode = .read_only });
    defer opened_file.close(io);

    // Read the data back
    var read_buf: [32]u8 = undefined;
    var read_slices = [_][]u8{&read_buf};
    const bytes_read = try opened_file.readPositional(io, &read_slices, 0);

    try std.testing.expectEqualStrings("hello world", read_buf[0..bytes_read]);
}

test "Io: File stat" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const file_path = "test_stdio_file_stat.txt";
    const cwd = Io.Dir.cwd();

    // Create a file with known content
    const file = try cwd.createFile(io, file_path, .{});
    defer os.fs.unlinkat(std.testing.allocator, cwd.handle, file_path) catch {};

    const test_data = "Hello, file stat!";
    var write_buf = [_][]const u8{test_data};
    _ = try file.writePositional(io, &write_buf, 0);

    // Get file stats
    const stat = try file.stat(io);

    // Verify the stats
    try std.testing.expectEqual(@as(u64, test_data.len), stat.size);
    try std.testing.expectEqual(Io.File.Kind.file, stat.kind);

    // Check that timestamps are reasonable (not zero, not in the far future)
    try std.testing.expect(stat.mtime.nanoseconds > 0);
    if (stat.atime) |atime| try std.testing.expect(atime.nanoseconds > 0);
    try std.testing.expect(stat.ctime.nanoseconds > 0);

    file.close(io);
}

test "Io: Dir statFile" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const file_path = "test_stdio_dir_stat_path.txt";
    const cwd = Io.Dir.cwd();

    // Create a file with known content
    const file = try cwd.createFile(io, file_path, .{});
    defer os.fs.unlinkat(std.testing.allocator, cwd.handle, file_path) catch {};

    const test_data = "Hello, stat path!";
    var write_buf = [_][]const u8{test_data};
    _ = try file.writePositional(io, &write_buf, 0);
    file.close(io);

    // Get file stats via statFile
    const stat = try cwd.statFile(io, file_path, .{});

    // Verify the stats
    try std.testing.expectEqual(@as(u64, test_data.len), stat.size);
    try std.testing.expectEqual(Io.File.Kind.file, stat.kind);

    // Check that timestamps are reasonable
    try std.testing.expect(stat.mtime.nanoseconds > 0);
    if (stat.atime) |atime| try std.testing.expect(atime.nanoseconds > 0);
    try std.testing.expect(stat.ctime.nanoseconds > 0);
}

test "Io: Event wait/set" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const TestContext = struct {
        var event: Io.Event = .unset;
        var waiter_completed: bool = false;

        fn waiterTask(i: Io) !void {
            try event.wait(i);
            waiter_completed = true;
        }

        fn setterTask(i: Io) !void {
            // Small delay to ensure waiter is waiting
            try i.sleep(.{ .nanoseconds = 1_000_000 }, .awake);
            event.set(i);
        }
    };

    TestContext.event = .unset;
    TestContext.waiter_completed = false;

    var waiter = try io.concurrent(TestContext.waiterTask, .{io});
    defer waiter.cancel(io) catch {};

    var setter = try io.concurrent(TestContext.setterTask, .{io});
    defer setter.cancel(io) catch {};

    // Wait for both tasks
    _ = try waiter.await(io);
    _ = try setter.await(io);

    try std.testing.expect(TestContext.waiter_completed);
    try std.testing.expect(TestContext.event.isSet());
}

test "Io: Event set before wait" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    var event: Io.Event = .unset;

    // Set before wait - should return immediately
    event.set(io);
    try std.testing.expect(event.isSet());

    // Wait should return immediately since already set
    try event.wait(io);
    try std.testing.expect(event.isSet());
}

test "Io.Group: basic async and await" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    var completed: usize = 0;

    var group: Io.Group = .init;
    defer group.cancel(io);

    const task = struct {
        fn run(c: *usize) void {
            _ = @atomicRmw(usize, c, .Add, 1, .monotonic);
        }
    }.run;

    group.async(io, task, .{&completed});
    group.async(io, task, .{&completed});
    group.async(io, task, .{&completed});

    try group.await(io);

    try std.testing.expectEqual(3, completed);
}

test "Io.Group: concurrent spawn" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    var completed: usize = 0;

    var group: Io.Group = .init;
    defer group.cancel(io);

    const task = struct {
        fn run(c: *usize) void {
            _ = @atomicRmw(usize, c, .Add, 1, .monotonic);
        }
    }.run;

    try group.concurrent(io, task, .{&completed});
    try group.concurrent(io, task, .{&completed});
    try group.concurrent(io, task, .{&completed});

    try group.await(io);

    try std.testing.expectEqual(3, completed);
}
