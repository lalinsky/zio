// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const ev = @import("ev/root.zig");

const Io = std.Io;

const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const getCurrentTask = runtime_mod.getCurrentTask;
const AnyTask = @import("runtime/task.zig").AnyTask;
const spawnTask = @import("runtime/task.zig").spawnTask;
const Awaitable = @import("runtime/awaitable.zig").Awaitable;
const Group = @import("runtime/group.zig").Group;
const groupSpawnTask = @import("runtime/group.zig").groupSpawnTask;
const select = @import("select.zig");
const waitForIo = @import("common.zig").waitForIo;
const fillBuf = @import("utils/writer.zig").fillBuf;
const zio_net = @import("net.zig");
const zio_fs = @import("fs.zig");
const os = @import("os/root.zig");
const Futex = @import("sync/Futex.zig");
const CompactWaitQueue = @import("utils/wait_queue.zig").CompactWaitQueue;
const time = @import("time.zig");

/// Convert std.Io.Timeout to our time.Duration.
/// Returns Duration.max for no timeout (.none).
fn timeoutToDuration(rt: *Runtime, timeout: Io.Timeout) time.Duration {
    return switch (timeout) {
        .none => time.Duration.max,
        .duration => |d| blk: {
            const ns = d.raw.nanoseconds;
            if (ns <= 0) break :blk time.Duration.zero;
            break :blk time.Duration.fromNanoseconds(@intCast(ns));
        },
        .deadline => |d| blk: {
            const now = rt.now();
            const deadline_ns = d.raw.nanoseconds;
            const now_ns: i96 = @intCast(now.toNanoseconds());
            const diff = deadline_ns - now_ns;
            if (diff <= 0) break :blk time.Duration.zero;
            break :blk time.Duration.fromNanoseconds(@intCast(diff));
        },
    };
}

fn ioTimeoutToTimeout(rt: *Runtime, timeout: Io.Timeout) time.Timeout {
    return switch (timeout) {
        .none => .none,
        .duration => |d| blk: {
            const ns = d.raw.nanoseconds;
            if (ns <= 0) break :blk .{ .duration = time.Duration.zero };
            break :blk .{ .duration = time.Duration.fromNanoseconds(@intCast(ns)) };
        },
        .deadline => |d| blk: {
            const now = rt.now();
            const deadline_ns = d.raw.nanoseconds;
            const now_ns: i96 = @intCast(now.toNanoseconds());
            const diff = deadline_ns - now_ns;
            if (diff <= 0) break :blk .{ .duration = time.Duration.zero };
            break :blk .{ .duration = time.Duration.fromNanoseconds(@intCast(diff)) };
        },
    };
}

fn asyncImpl(userdata: ?*anyopaque, result: []u8, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) ?*Io.AnyFuture {
    return concurrentImpl(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // If we can't schedule asynchronously, execute synchronously
        start(context.ptr, result.ptr);
        return null;
    };
}

fn concurrentImpl(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque, result: *anyopaque) void) Io.ConcurrentError!*Io.AnyFuture {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const task = spawnTask(rt, result_len, result_alignment, context, context_alignment, .{ .regular = start }, null) catch {
        return error.ConcurrencyUnavailable;
    };
    return @ptrCast(&task.awaitable);
}

fn awaitOrCancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment, should_cancel: bool) void {
    _ = result_alignment;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const awaitable: *Awaitable = @ptrCast(@alignCast(any_future));

    // Request cancellation if needed
    if (should_cancel and !awaitable.hasResult()) {
        awaitable.cancel();
    }

    // Wait for completion
    _ = select.waitUntilComplete(awaitable);

    // Copy result from task to result buffer
    const task = AnyTask.fromAwaitable(awaitable);
    const task_result = task.closure.getResultSlice(AnyTask, task);
    @memcpy(result, task_result);

    // Release the awaitable (decrements ref count, may destroy)
    awaitable.release(rt);
}

fn awaitImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, false);
}

fn cancelImpl(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: std.mem.Alignment) void {
    awaitOrCancel(userdata, any_future, result, result_alignment, true);
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
    return Group.fromStd(group).wait();
}

fn groupCancelImpl(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    _ = initial_token;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    Group.fromStd(group).cancel();
}

fn selectImpl(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Io.Cancelable!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const awaitables: []const *Awaitable = @ptrCast(futures);
    _ = rt;
    return select.selectAwaitables(awaitables);
}

fn recancelImpl(userdata: ?*anyopaque) void {
    _ = userdata;
    const task = getCurrentTask();
    task.recancel();
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
    try rt.checkCancel();
}

fn futexWaitImpl(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const internal_timeout = ioTimeoutToTimeout(rt, timeout);

    Futex.timedWait(rt, ptr, expected, internal_timeout) catch |err| switch (err) {
        error.Timeout => return, // Timeout is not an error, just return void
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
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const mode = if (@hasDecl(Io.Dir.Permissions, "toMode")) permissions.toMode() else 0;
    var op = ev.DirCreateDir.init(dir.handle, sub_path, mode);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirCreateDirPathImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    var it = Io.Dir.path.componentIterator(sub_path);
    var status: Io.Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;

    while (true) {
        // Try to create this component
        if (dirCreateDirImpl(userdata, dir, component.path, permissions)) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                // Check if existing path is actually a directory.
                // Important: a dangling symlink could cause an infinite loop otherwise.
                const stat = dirStatFileImpl(userdata, dir, component.path, .{}) catch |e| switch (e) {
                    error.Canceled => return error.Canceled,
                    error.FileNotFound => return error.FileNotFound,
                    error.AccessDenied => return error.AccessDenied,
                    error.SymLinkLoop => return error.SymLinkLoop,
                    error.NameTooLong => return error.NameTooLong,
                    error.NotDir => return error.NotDir,
                    error.SystemResources => return error.SystemResources,
                    else => return error.Unexpected,
                };
                if (stat.kind != .directory) return error.NotDir;
            },
            error.FileNotFound => {
                // Parent doesn't exist, go back one component
                component = it.previous() orelse return error.FileNotFound;
                continue;
            },
            else => |e| return e,
        }
        // Move to next component (toward the target)
        component = it.next() orelse return status;
    }
}

fn dirCreateDirPathOpenImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    return dirOpenDirImpl(userdata, dir, sub_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try dirCreateDirPathImpl(userdata, dir, sub_path, permissions);
            return dirOpenDirImpl(userdata, dir, sub_path, options);
        },
        else => |e| return e,
    };
}

fn dirStatImpl(userdata: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const ev_stat = zio_dir.stat(rt) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return evFileStatToStdIo(ev_stat);
}

fn dirStatFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    // StatFileOptions only has follow_symlinks, which is the default behavior for fstatat
    // We don't support not following symlinks yet
    if (!options.follow_symlinks) {
        return error.Unexpected;
    }

    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const ev_stat = zio_dir.statPath(rt, sub_path) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SymLinkLoop => return error.SymLinkLoop,
        error.FileNotFound => return error.FileNotFound,
        error.NameTooLong => return error.NameTooLong,
        error.NotDir => return error.NotDir,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return evFileStatToStdIo(ev_stat);
}

fn dirAccessImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirAccess.init(dir.handle, sub_path, .{
        .read = options.read,
        .write = options.write,
        .execute = options.execute,
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirCreateFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, flags: Io.File.CreateFlags) Io.File.OpenError!Io.File {
    // Unsupported options
    if (flags.lock != .none or flags.lock_nonblocking) return error.Unexpected;

    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_dir = zio_fs.Dir{ .fd = dir.handle };

    const ev_flags: os.fs.FileCreateFlags = .{
        .read = flags.read,
        .truncate = flags.truncate,
        .exclusive = flags.exclusive,
    };

    const file = zio_dir.createFile(rt, sub_path, ev_flags) catch |err| switch (err) {
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

    const ev_flags: os.fs.FileOpenFlags = .{
        .mode = switch (flags.mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        },
    };

    const file = zio_dir.openFile(rt, sub_path, ev_flags) catch |err| switch (err) {
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
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    const flags: os.fs.DirOpenFlags = .{
        .follow_symlinks = options.follow_symlinks,
        .iterate = options.iterate,
    };

    var op = ev.DirOpen.init(dir.handle, sub_path, flags);
    try waitForIo(&op.c);
    const fd = try op.getResult();

    return .{ .handle = fd };
}

fn dirCloseImpl(userdata: ?*anyopaque, dirs: []const Io.Dir) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    rt.beginShield();
    defer rt.endShield();

    var i: usize = 0;
    while (i < dirs.len) {
        var group = ev.Group.init(.gather);

        const max_batch = 32;
        var ops: [max_batch]ev.DirClose = undefined;

        const batch_size = @min(dirs.len - i, max_batch);

        for (0..batch_size) |j| {
            ops[j] = ev.DirClose.init(dirs[i + j].handle);
            group.add(&ops[j].c);
        }

        waitForIo(&group.c) catch unreachable;
        i += batch_size;
    }
}

fn dirReadImpl(userdata: ?*anyopaque, dr: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var entry_index: usize = 0;

    // Get the unreserved portion of buffer for syscall (on Windows, reserved space is at start)
    const unreserved = os.fs.DirEntryIterator.getUnreservedBuffer(dr.buffer);

    while (entry_index < entries.len) {
        // Check if buffer needs refilling
        if (dr.end - dr.index == 0) {
            // Don't refill if we already have entries (names reference buffer)
            if (entry_index != 0) break;

            // Async syscall via DirRead - fill unreserved portion
            var op = ev.DirRead.init(dr.dir.handle, unreserved, dr.state == .reset);
            try waitForIo(&op.c);

            const bytes = try op.getResult();
            if (bytes == 0) {
                dr.state = .finished;
                return entry_index;
            }

            dr.index = 0;
            dr.end = bytes;
            if (dr.state == .reset) dr.state = .reading;
        }

        // Parse entries using iterator
        var iter = os.fs.DirEntryIterator.init(dr.buffer, dr.index, dr.end);

        while (iter.next()) |fs_entry| {
            entries[entry_index] = .{
                .name = fs_entry.name,
                .kind = stdFileKind(fs_entry.kind),
                .inode = fs_entry.inode,
            };
            entry_index += 1;
            dr.index = iter.index;

            if (entry_index >= entries.len) break;
        }

        // Update index to mark buffer as consumed
        dr.index = iter.index;
    }

    return entry_index;
}

fn stdFileKind(kind: os.fs.FileKind) Io.File.Kind {
    return switch (kind) {
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
}

fn dirRealPathImpl(userdata: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirRealPath.init(dir.handle, out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirRealPathFileImpl(userdata: ?*anyopaque, dir: Io.Dir, path_name: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirRealPathFile.init(dir.handle, path_name, out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirDeleteFileImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirDeleteFile.init(dir.handle, sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirDeleteDirImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirDeleteDir.init(dir.handle, sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirRenameImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirRename.init(old_dir.handle, old_sub_path, new_dir.handle, new_sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirRenamePreserveImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirRenamePreserve.init(old_dir.handle, old_sub_path, new_dir.handle, new_sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSymLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirSymLink.init(dir.handle, target_path, sym_link_path, .{
        .is_directory = flags.is_directory,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirReadLinkImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirReadLink.init(dir.handle, sub_path, buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirSetOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirSetOwner.init(dir.handle, uid, gid);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetFileOwnerImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, uid: ?Io.File.Uid, gid: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirSetFileOwner.init(dir.handle, sub_path, uid, gid, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetPermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const mode = if (@hasDecl(Io.Dir.Permissions, "toMode")) permissions.toMode() else 0;
    var op = ev.DirSetPermissions.init(dir.handle, mode);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetFilePermissionsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const mode = if (@hasDecl(Io.File.Permissions, "toMode")) permissions.toMode() else 0;
    var op = ev.DirSetFilePermissions.init(dir.handle, sub_path, mode, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetTimestampsImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirSetFileTimestamps.init(dir.handle, sub_path, .{
        .atime = timestampToNanos(options.access_timestamp),
        .mtime = timestampToNanos(options.modify_timestamp),
    }, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirHardLinkImpl(userdata: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.DirHardLink.init(old_dir.handle, old_sub_path, new_dir.handle, new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirCreateFileAtomicImpl(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = dir;
    _ = sub_path;
    _ = options;
    @panic("TODO");
}

fn evFileStatToStdIo(ev_stat: os.fs.FileStatInfo) Io.File.Stat {
    const kind: Io.File.Kind = switch (ev_stat.kind) {
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
        .inode = ev_stat.inode,
        .nlink = ev_stat.nlink,
        .size = ev_stat.size,
        .permissions = @enumFromInt(ev_stat.mode),
        .kind = kind,
        .atime = .{ .nanoseconds = ev_stat.atime },
        .mtime = .{ .nanoseconds = ev_stat.mtime },
        .ctime = .{ .nanoseconds = ev_stat.ctime },
        .block_size = ev_stat.block_size,
    };
}

fn fileStatImpl(userdata: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_file = zio_fs.File.fromFd(file.handle);

    const ev_stat = zio_file.stat(rt) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.AccessDenied => return error.AccessDenied,
        error.SystemResources => return error.SystemResources,
        else => return error.Unexpected,
    };

    return evFileStatToStdIo(ev_stat);
}

fn fileCloseImpl(userdata: ?*anyopaque, files: []const Io.File) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    rt.beginShield();
    defer rt.endShield();

    var i: usize = 0;
    while (i < files.len) {
        var group = ev.Group.init(.gather);

        const max_batch = 32;
        var ops: [max_batch]ev.FileClose = undefined;

        const batch_size = @min(files.len - i, max_batch);

        for (0..batch_size) |j| {
            ops[j] = ev.FileClose.init(files[i + j].handle);
            group.add(&ops[j].c);
        }

        waitForIo(&group.c) catch unreachable;
        i += batch_size;
    }
}

fn fileWriteStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize) Io.File.Writer.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = header;
    _ = data;
    _ = splat;
    // TODO: splat != 1 case
    // Cannot track position with bare file handle - Io.File is just a handle
    return error.BrokenPipe;
}

fn fileWritePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    var splat_buf: [64]u8 = undefined;
    var slices: [zio_fs.max_vecs][]const u8 = undefined;
    const buf_len = fillBuf(&slices, header, data, splat, &splat_buf);

    if (buf_len == 0) return 0;

    const zio_file = zio_fs.File.fromFd(file.handle);
    return try zio_file.writeVec(rt, slices[0..buf_len], offset);
}

fn fileReadStreamingImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8) Io.File.Reader.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = data;
    // Cannot track position with bare file handle - Io.File is just a handle
    return error.BrokenPipe;
}

fn fileReadPositionalImpl(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_file = zio_fs.File.fromFd(file.handle);
    return try zio_file.readVec(rt, data, offset);
}

fn fileSeekByImpl(userdata: ?*anyopaque, file: Io.File, relative_offset: i64) Io.File.SeekError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = relative_offset;
    // Cannot seek without position tracking - Io.File is just a handle
    return error.Unseekable;
}

fn fileSeekToImpl(userdata: ?*anyopaque, file: Io.File, absolute_offset: u64) Io.File.SeekError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = absolute_offset;
    // Cannot seek without position tracking - Io.File is just a handle
    return error.Unseekable;
}

fn nowImpl(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const ts = os.time.now(switch (clock) {
        .awake, .boot => .monotonic,
        .real => .realtime,
        .cpu_process, .cpu_thread => .monotonic, // TODO: Zig 0.16 - implement CPU time clocks
    });
    return .{ .nanoseconds = @intCast(ts.toNanoseconds()) };
}

fn sleepImpl(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);

    // Convert timeout to duration from now (handles none/duration/deadline cases)
    const duration = (try timeout.toDurationFromNow(io)) orelse return;

    // Convert Io.Duration to time.Duration
    const ns: i96 = duration.raw.nanoseconds;
    if (ns <= 0) return;

    try rt.sleep(time.Duration.fromNanoseconds(@intCast(ns)));
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
    const domain = os.net.Domain.fromPosix(zio_addr.any.family);

    // Open socket
    var open_op = ev.NetOpen.init(domain, .stream, .ip, .{});
    try waitForIo(rt, &open_op.c);
    const handle = open_op.getResult() catch |err| switch (err) {
        error.AccessDenied => return error.Unexpected,
        else => |e| return e,
    };

    // Set reuse address if requested
    if (options.reuse_address) {
        const value: c_int = 1;
        const bytes = std.mem.asBytes(&value);
        std.posix.setsockopt(handle, os.posix.SOL.SOCKET, os.posix.SO.REUSEADDR, bytes) catch {};
    }

    // Bind
    var bind_addr = zio_addr;
    var addr_len = zio_net.getSockAddrLen(&bind_addr.any);
    var bind_op = ev.NetBind.init(handle, &bind_addr.any, &addr_len);
    try waitForIo(rt, &bind_op.c);
    bind_op.getResult() catch |err| switch (err) {
        error.AccessDenied,
        error.SymLinkLoop,
        error.FileNotFound,
        error.NotDir,
        error.ReadOnlyFileSystem,
        error.NameTooLong,
        error.InputOutput,
        error.FileDescriptorNotASocket,
        error.AddressNotAvailable,
        => return error.Unexpected,
        else => |e| return e,
    };

    // Listen
    var listen_op = ev.NetListen.init(handle, options.kernel_backlog);
    try waitForIo(rt, &listen_op.c);
    listen_op.getResult() catch |err| switch (err) {
        error.OperationUnsupported,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        => return error.Unexpected,
        else => |e| return e,
    };

    return .{
        .socket = .{
            .handle = handle,
            .address = zioIpToStdIo(bind_addr),
        },
    };
}

fn netAcceptImpl(userdata: ?*anyopaque, server: Io.net.Socket.Handle) Io.net.Server.AcceptError!Io.net.Stream {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var peer_addr: zio_net.Address = undefined;
    var peer_addr_len: os.net.socklen_t = @sizeOf(zio_net.Address);

    var op = ev.NetAccept.init(server, &peer_addr.any, &peer_addr_len);
    try waitForIo(&op.c);
    const handle = op.getResult() catch |err| switch (err) {
        error.OperationUnsupported,
        error.ConnectionResetByPeer,
        error.FileDescriptorNotASocket,
        => return error.Unexpected,
        else => |e| return e,
    };

    // Convert address based on family
    // Note: Io.net.Stream.socket.address is IpAddress only, so for Unix sockets we use a fake address
    const std_addr: Io.net.IpAddress = switch (peer_addr.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => zioIpToStdIo(peer_addr.ip),
        std.posix.AF.UNIX => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } }, // Fake address for Unix sockets
        else => unreachable,
    };

    return .{
        .socket = .{
            .handle = handle,
            .address = std_addr,
        },
    };
}

fn netBindIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    _ = options;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const domain = os.net.Domain.fromPosix(zio_addr.any.family);

    // Open socket
    var open_op = ev.NetOpen.init(domain, .dgram, .ip, .{});
    try waitForIo(rt, &open_op.c);
    const handle = open_op.getResult() catch |err| switch (err) {
        error.AccessDenied => return error.Unexpected,
        else => |e| return e,
    };

    // Bind
    var bind_addr = zio_addr;
    var addr_len = zio_net.getSockAddrLen(&bind_addr.any);
    var bind_op = ev.NetBind.init(handle, &bind_addr.any, &addr_len);
    try waitForIo(rt, &bind_op.c);
    bind_op.getResult() catch |err| switch (err) {
        error.AccessDenied,
        error.SymLinkLoop,
        error.FileNotFound,
        error.NotDir,
        error.ReadOnlyFileSystem,
        error.NameTooLong,
        error.InputOutput,
        error.FileDescriptorNotASocket,
        error.AddressNotAvailable,
        => return error.Unexpected,
        else => |e| return e,
    };

    return .{
        .handle = handle,
        .address = zioIpToStdIo(bind_addr),
    };
}

fn netConnectIpImpl(userdata: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Stream {
    _ = options;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const zio_addr = stdIoIpToZio(address.*);
    const domain = os.net.Domain.fromPosix(zio_addr.any.family);

    // Open socket
    var open_op = ev.NetOpen.init(domain, .stream, .ip, .{});
    try waitForIo(rt, &open_op.c);
    const handle = open_op.getResult() catch |err| switch (err) {
        error.AccessDenied => return error.Unexpected,
        else => |e| return e,
    };

    // Connect
    const addr_len = zio_net.getSockAddrLen(&zio_addr.any);
    var connect_op = ev.NetConnect.init(handle, &zio_addr.any, addr_len);
    try waitForIo(rt, &connect_op.c);
    connect_op.getResult() catch |err| switch (err) {
        error.SymLinkLoop,
        error.FileNotFound,
        error.NotDir,
        error.NameTooLong,
        error.AddressInUse,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        error.AddressNotAvailable,
        error.ConnectionTimedOut,
        => return error.Unexpected,
        else => |e| return e,
    };

    return .{
        .socket = .{
            .handle = handle,
            .address = zioIpToStdIo(zio_addr),
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

    // Open socket
    var open_op = ev.NetOpen.init(.unix, .stream, .ip, .{});
    try waitForIo(rt, &open_op.c);
    const handle = open_op.getResult() catch |err| switch (err) {
        error.AccessDenied, error.ProtocolUnsupportedBySystem => return error.Unexpected,
        else => |e| return e,
    };

    // Bind
    var bind_addr = zio_addr;
    var addr_len = zio_net.getSockAddrLen(&bind_addr.any);
    var bind_op = ev.NetBind.init(handle, &bind_addr.any, &addr_len);
    try waitForIo(rt, &bind_op.c);
    bind_op.getResult() catch |err| switch (err) {
        error.NameTooLong,
        error.InputOutput,
        error.FileDescriptorNotASocket,
        error.AddressNotAvailable,
        => return error.Unexpected,
        else => |e| return e,
    };

    // Listen
    var listen_op = ev.NetListen.init(handle, options.kernel_backlog);
    try waitForIo(rt, &listen_op.c);
    listen_op.getResult() catch |err| switch (err) {
        error.OperationUnsupported,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        => return error.Unexpected,
        else => |e| return e,
    };

    return handle;
}

fn netConnectUnixImpl(userdata: ?*anyopaque, address: *const Io.net.UnixAddress) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    if (!zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    // Convert Io.net.UnixAddress (path) to zio UnixAddress (sockaddr)
    const zio_addr = zio_net.UnixAddress.init(address.path) catch {
        // NameTooLong isn't in the error set, so treat as Unexpected
        return error.Unexpected;
    };

    // Open socket
    var open_op = ev.NetOpen.init(.unix, .stream, .ip, .{});
    try waitForIo(rt, &open_op.c);
    const handle = open_op.getResult() catch |err| switch (err) {
        error.AccessDenied, error.ProtocolUnsupportedBySystem => return error.Unexpected,
        else => |e| return e,
    };

    // Connect
    const addr_len = zio_net.getSockAddrLen(&zio_addr.any);
    var connect_op = ev.NetConnect.init(handle, &zio_addr.any, addr_len);
    try waitForIo(rt, &connect_op.c);
    connect_op.getResult() catch |err| switch (err) {
        error.NameTooLong,
        error.ConnectionResetByPeer,
        error.AddressInUse,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        error.AddressNotAvailable,
        error.ConnectionTimedOut,
        => return error.Unexpected,
        else => |e| return e,
    };

    return handle;
}

fn netSendImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = messages;
    _ = flags;
    @panic("TODO");
}

fn netReceiveImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, message_buffer: []Io.net.IncomingMessage, data_buffer: []u8, flags: Io.net.ReceiveFlags, timeout: Io.Timeout) struct { ?Io.net.Socket.ReceiveTimeoutError, usize } {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    @panic("TODO");
}

fn netReadImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    var iovecs: [zio_net.max_vecs]os.iovec = undefined;
    var op = ev.NetRecv.init(handle, .fromSlices(data, &iovecs), .{});
    try waitForIo(&op.c);
    return op.getResult() catch |err| switch (err) {
        error.WouldBlock,
        error.OperationUnsupported,
        error.ConnectionAborted,
        error.ConnectionRefused,
        error.FileDescriptorNotASocket,
        error.ConnectionTimedOut,
        error.SocketShutdown,
        => return error.Unexpected,
        else => |e| return e,
    };
}

fn netWriteImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));

    var splat_buf: [64]u8 = undefined;
    var slices: [zio_net.max_vecs][]const u8 = undefined;
    const buf_len = fillBuf(&slices, header, data, splat, &splat_buf);

    var iovecs: [zio_net.max_vecs]os.iovec_const = undefined;
    var op = ev.NetSend.init(handle, .fromSlices(slices[0..buf_len], &iovecs), .{});
    try waitForIo(&op.c);
    return op.getResult() catch |err| switch (err) {
        error.WouldBlock => error.Unexpected,
        error.FileDescriptorNotASocket => error.Unexpected,
        error.MessageTooBig => error.Unexpected,
        error.OperationUnsupported => error.Unexpected,
        error.HostDown => error.HostUnreachable,
        else => |e| return e,
    };
}

fn netCloseImpl(userdata: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    rt.beginShield();
    defer rt.endShield();

    var i: usize = 0;
    while (i < handles.len) {
        var group = ev.Group.init(.gather);

        const max_batch = 32;
        var ops: [max_batch]ev.NetClose = undefined;

        const batch_size = @min(handles.len - i, max_batch);

        for (0..batch_size) |j| {
            ops[j] = ev.NetClose.init(handles[i + j]);
            group.add(&ops[j].c);
        }

        waitForIo(&group.c) catch unreachable;
        i += batch_size;
    }
}

fn netInterfaceNameResolveImpl(userdata: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = name;
    @panic("TODO");
}

fn netInterfaceNameImpl(userdata: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = interface;
    @panic("TODO");
}

fn netLookupImpl(userdata: ?*anyopaque, hostname: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), options: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);
    defer queue.close(io);

    // Call the zio DNS lookup (uses thread pool internally)
    const zio_hostname = zio_net.HostName{ .bytes = hostname.bytes };
    var iter = try zio_hostname.lookup(rt, .{
        .port = options.port,
        .family = if (options.family) |f| switch (f) {
            .ip4 => .ipv4,
            .ip6 => .ipv6,
        } else null,
        .canonical_name = options.canonical_name_buffer.len > 0,
    });
    defer iter.deinit();

    // Iterate through resolved addresses and canonical name
    while (iter.next()) |result| {
        switch (result) {
            .canonical_name => |cn| {
                const len = @min(cn.bytes.len, options.canonical_name_buffer.len);
                @memcpy(options.canonical_name_buffer[0..len], cn.bytes[0..len]);
                queue.putOneUncancelable(io, .{ .canonical_name = .{ .bytes = options.canonical_name_buffer[0..len] } }) catch |err| switch (err) {
                    error.Closed => unreachable,
                };
            },
            .address => |zio_addr| {
                const std_addr = zioIpToStdIo(zio_addr);
                queue.putOneUncancelable(io, .{ .address = std_addr }) catch |err| switch (err) {
                    error.Closed => unreachable,
                };
            },
        }
    }
}

// File operations
fn fileLengthImpl(userdata: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileSize.init(file.handle);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn fileWriteFileStreamingImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.File.Writer.WriteFileError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    return error.Unimplemented;
}

fn fileWriteFilePositionalImpl(userdata: ?*anyopaque, file: Io.File, header: []const u8, reader: *Io.File.Reader, count: Io.Limit, offset: u64) Io.File.WriteFilePositionalError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = header;
    _ = reader;
    _ = count;
    _ = offset;
    return error.Unimplemented;
}

fn fileSyncImpl(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileSync.init(file.handle, .{});
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileIsTtyImpl(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileIsTty(io.userdata, file);
}

fn fileEnableAnsiEscapeCodesImpl(userdata: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileEnableAnsiEscapeCodes(io.userdata, file);
}

fn fileSupportsAnsiEscapeCodesImpl(userdata: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.fileSupportsAnsiEscapeCodes(io.userdata, file);
}

fn fileSetLengthImpl(userdata: ?*anyopaque, file: Io.File, length: u64) Io.File.SetLengthError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileSetSize.init(file.handle, length);
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetOwnerImpl(userdata: ?*anyopaque, file: Io.File, uid: ?Io.File.Uid, gid: ?Io.File.Gid) Io.File.SetOwnerError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileSetOwner.init(file.handle, uid, gid);
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetPermissionsImpl(userdata: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const mode = if (@hasDecl(Io.File.Permissions, "toMode")) permissions.toMode() else 0;
    var op = ev.FileSetPermissions.init(file.handle, mode);
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetTimestampsImpl(userdata: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileSetTimestamps.init(file.handle, .{
        .atime = timestampToNanos(options.access_timestamp),
        .mtime = timestampToNanos(options.modify_timestamp),
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn timestampToNanos(ts: Io.File.SetTimestamp) ?i96 {
    return switch (ts) {
        .unchanged => null,
        .now => @intCast(os.time.now(.realtime).toNanoseconds()),
        .new => |t| t.nanoseconds,
    };
}

fn fileLockImpl(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = lock;
    @panic("TODO: fileLock");
}

fn fileTryLockImpl(userdata: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = lock;
    @panic("TODO: fileTryLock");
}

fn fileUnlockImpl(userdata: ?*anyopaque, file: Io.File) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    @panic("TODO: fileUnlock");
}

fn fileDowngradeLockImpl(userdata: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    @panic("TODO: fileDowngradeLock");
}

fn fileRealPathImpl(userdata: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileRealPath.init(file.handle, out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn fileHardLinkImpl(userdata: ?*anyopaque, file: Io.File, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.FileHardLink.init(file.handle, new_dir.handle, new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn processExecutableOpenImpl(userdata: ?*anyopaque, flags: Io.File.OpenFlags) std.process.OpenExecutableError!Io.File {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = flags;
    @panic("TODO: processExecutableOpen");
}

fn processExecutablePathImpl(userdata: ?*anyopaque, out_buffer: []u8) std.process.ExecutablePathError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.processExecutablePath(io.userdata, out_buffer);
}

fn lockStderrImpl(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mode;
    @panic("TODO: lockStderr");
}

fn tryLockStderrImpl(userdata: ?*anyopaque, mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mode;
    return null;
}

fn unlockStderrImpl(userdata: ?*anyopaque) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    @panic("TODO: unlockStderr");
}

fn processCurrentPathImpl(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = buffer;
    @panic("TODO: processCurrentPath");
}

fn processSetCurrentDirImpl(userdata: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = dir;
    @panic("TODO: processSetCurrentDir");
}

fn processReplaceImpl(userdata: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = options;
    @panic("TODO: processReplace");
}

fn processReplacePathImpl(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = dir;
    _ = options;
    @panic("TODO: processReplacePath");
}

fn processSpawnImpl(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = options;
    @panic("TODO: processSpawn");
}

fn processSpawnPathImpl(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = dir;
    _ = options;
    @panic("TODO: processSpawnPath");
}

fn childWaitImpl(userdata: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = child;
    @panic("TODO: childWait");
}

fn childKillImpl(userdata: ?*anyopaque, child: *std.process.Child) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = child;
    @panic("TODO: childKill");
}

fn progressParentFileImpl(userdata: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    @panic("TODO: progressParentFile");
}

fn randomImpl(userdata: ?*anyopaque, buffer: []u8) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.random(io.userdata, buffer);
}

fn randomSecureImpl(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = Io.Threaded.global_single_threaded.io();
    return io.vtable.randomSecure(io.userdata, buffer);
}

fn netWriteFileImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, reader: *Io.File.Reader, count: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = handle;
    _ = header;
    _ = reader;
    _ = count;
    return error.Unexpected;
}

fn fileMemoryMapCreateImpl(userdata: ?*anyopaque, file: Io.File, options: Io.File.MemoryMap.CreateOptions) Io.File.MemoryMap.CreateError!Io.File.MemoryMap {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = file;
    _ = options;
    @panic("TODO: fileMemoryMapCreate");
}

fn fileMemoryMapDestroyImpl(userdata: ?*anyopaque, mm: *Io.File.MemoryMap) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mm;
    @panic("TODO: fileMemoryMapDestroy");
}

fn fileMemoryMapSetLengthImpl(userdata: ?*anyopaque, mm: *Io.File.MemoryMap, new_length: usize) Io.File.MemoryMap.SetLengthError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mm;
    _ = new_length;
    @panic("TODO: fileMemoryMapSetLength");
}

fn fileMemoryMapReadImpl(userdata: ?*anyopaque, mm: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mm;
    @panic("TODO: fileMemoryMapRead");
}

fn fileMemoryMapWriteImpl(userdata: ?*anyopaque, mm: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    _ = mm;
    @panic("TODO: fileMemoryMapWrite");
}

fn netShutdownImpl(userdata: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var op = ev.NetShutdown.init(handle, switch (how) {
        .recv => .receive,
        .send => .send,
        .both => .both,
    });
    try waitForIo(&op.c);
    return try op.getResult();
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
    .fileWritePositional = fileWritePositionalImpl,
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
    .fileMemoryMapCreate = fileMemoryMapCreateImpl,
    .fileMemoryMapDestroy = fileMemoryMapDestroyImpl,
    .fileMemoryMapSetLength = fileMemoryMapSetLengthImpl,
    .fileMemoryMapRead = fileMemoryMapReadImpl,
    .fileMemoryMapWrite = fileMemoryMapWriteImpl,
    .processExecutableOpen = processExecutableOpenImpl,
    .processExecutablePath = processExecutablePathImpl,
    .lockStderr = lockStderrImpl,
    .tryLockStderr = tryLockStderrImpl,
    .unlockStderr = unlockStderrImpl,
    .processCurrentPath = processCurrentPathImpl,
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
}

test "Io: now and sleep" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    // Get current time
    const t1 = Io.Clock.now(.awake, io);

    // Sleep for 10ms
    try io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake);

    // Get time after sleep
    const t2 = Io.Clock.now(.awake, io);

    // Verify time moved forward (allow 1ms tolerance for timer precision)
    const elapsed = t1.durationTo(t2);
    try std.testing.expect(elapsed.nanoseconds >= 9 * std.time.ns_per_ms);
}

test "Io: realtime clock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const t1 = Io.Clock.Timestamp.now(io, .real);

    // Realtime clock should return a reasonable timestamp (after 2020-01-01)
    const jan_2020_ns: i96 = 1577836800 * 1_000_000_000;
    try std.testing.expect(t1.raw.nanoseconds >= jan_2020_ns);

    try io.sleep(.{ .nanoseconds = 10 * 1_000_000 }, .real);

    const t2 = Io.Clock.Timestamp.now(io, .real);
    const elapsed = t1.durationTo(t2);
    // Allow 1ms tolerance for timer precision
    try std.testing.expect(elapsed.raw.nanoseconds >= 9 * 1_000_000);
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
}

test "Io: Unix domain socket listen/accept/connect/read/write" {
    if (!zio_net.has_unix_sockets) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn mainTask(io: Io) !void {
            // Use a simple path for the socket
            const socket_path = "test_stdio_unix.sock";
            defer os.fs.dirDeleteFile(std.testing.allocator, os.fs.cwd(), socket_path) catch {};

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

    var handle = try rt.spawn(TestContext.mainTask, .{rt.io()});
    try handle.join();
}

test "Io: File close" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_file_close.txt";
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

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
            .address => {
                address_count += 1;
            },
            .canonical_name => {
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
            // Canonical name may not be returned for numeric IPs (platform-specific)
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {}, // Queue closed, done reading
    }
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
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

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
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

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
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

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

test "Io: Dir openDir" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const dir_path = "test_stdio_open_dir";

    // Create a directory
    try cwd.createDir(io, dir_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, dir_path) catch {};

    // Open the directory
    const opened_dir = try cwd.openDir(io, dir_path, .{});
    defer opened_dir.close(io);

    // Verify we can stat the opened directory
    const stat = try opened_dir.stat(io);
    try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);
}

test "Io: Dir symLink and readLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_symlink_target";
    const link_path = "test_stdio_symlink_link";

    // Create a target file
    const file = try cwd.createFile(io, file_path, .{});
    file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Create a symbolic link
    try cwd.symLink(io, file_path, link_path, .{});
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, link_path) catch {};

    // Read the symbolic link
    var buffer: [256]u8 = undefined;
    const len = try cwd.readLink(io, link_path, &buffer);

    // Verify the link target
    try std.testing.expectEqualStrings(file_path, buffer[0..len]);
}

test "Io: Dir hardLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_hardlink_target";
    const link_path = "test_stdio_hardlink_link";

    // Create a target file
    const file = try cwd.createFile(io, file_path, .{});
    file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Create a hard link
    try cwd.hardLink(file_path, cwd, link_path, io, .{});
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, link_path) catch {};

    // Verify the hard link exists and can be opened
    const link_file = try cwd.openFile(io, link_path, .{});
    link_file.close(io);

    // Verify inode is the same (true hard link)
    const orig_stat = try cwd.statFile(io, file_path, .{});
    const link_stat = try cwd.statFile(io, link_path, .{});
    try std.testing.expectEqual(orig_stat.inode, link_stat.inode);
}

test "Io: Dir access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_access_file";

    // Create a target file
    const file = try cwd.createFile(io, file_path, .{});
    file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Check that file exists (default access check)
    try cwd.access(io, file_path, .{});

    // Check read access
    try cwd.access(io, file_path, .{ .read = true });

    // Check that a non-existent file returns FileNotFound
    const result = cwd.access(io, "non_existent_file_12345", .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "Io: Dir realPath" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();

    // Get real path of cwd
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const len = try cwd.realPath(io, &buffer);

    // Should return a non-empty absolute path
    try std.testing.expect(len > 0);
    try std.testing.expect(os.path.isAbsolute(buffer[0..len]));
}

test "Io: Dir realPathFile" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_realpath_file";

    // Create a target file
    const file = try cwd.createFile(io, file_path, .{});
    file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Get real path of file
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const len = try cwd.realPathFile(io, file_path, &buffer);

    // Should return an absolute path ending with file_path
    try std.testing.expect(len > 0);
    try std.testing.expect(os.path.isAbsolute(buffer[0..len]));
    try std.testing.expect(std.mem.endsWith(u8, buffer[0..len], file_path));
}

test "Io: File realPath" {
    // Skip on FreeBSD - F_KINFO cache is unreliable for regular files
    if (builtin.os.tag == .freebsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_file_realpath";

    // Create and open a file
    const file = try cwd.createFile(io, file_path, .{ .read = true });
    defer file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Get real path of the open file handle
    var buffer: [std.posix.PATH_MAX]u8 = undefined;
    const len = try file.realPath(io, &buffer);

    // Should return an absolute path ending with file_path
    try std.testing.expect(len > 0);
    try std.testing.expect(os.path.isAbsolute(buffer[0..len]));
    try std.testing.expect(std.mem.endsWith(u8, buffer[0..len], file_path));
}

test "Io: File hardLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const file_path = "test_stdio_file_hardlink_src";
    const link_path = "test_stdio_file_hardlink_dst";

    // Create and open a file
    const file = try cwd.createFile(io, file_path, .{ .read = true });
    defer file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, file_path) catch {};

    // Create a hard link from the open file handle
    try file.hardLink(io, cwd, link_path, .{});
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, link_path) catch {};

    // Verify the hard link exists and has the same inode
    const orig_stat = try cwd.statFile(io, file_path, .{});
    const link_stat = try cwd.statFile(io, link_path, .{});
    try std.testing.expectEqual(orig_stat.inode, link_stat.inode);
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

test "Io: Dir read" {
    const rt = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{} });
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const sep = Io.Dir.path.sep_str;
    const dir_path = "test_stdio_dir_read";

    // Create a test directory
    try cwd.createDir(io, dir_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, dir_path) catch {};

    // Create test files (using cwd-relative paths)
    const file1 = try cwd.createFile(io, dir_path ++ sep ++ "file1.txt", .{});
    file1.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, dir_path ++ sep ++ "file1.txt") catch {};

    const file2 = try cwd.createFile(io, dir_path ++ sep ++ "file2.txt", .{});
    file2.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, dir_path ++ sep ++ "file2.txt") catch {};

    // Create a subdirectory
    try cwd.createDir(io, dir_path ++ sep ++ "subdir", .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, dir_path ++ sep ++ "subdir") catch {};

    // Now open for iteration (after files exist)
    const test_dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer test_dir.close(io);

    // Iterate directory using Dir.Reader
    var reader_buffer: [Io.Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var reader = Io.Dir.Reader.init(test_dir, &reader_buffer);

    var entries: [10]Io.Dir.Entry = undefined;
    var found_file1 = false;
    var found_file2 = false;
    var found_subdir = false;
    var total_entries: usize = 0;

    while (true) {
        const count = try reader.read(io, &entries);
        if (count == 0) break;

        for (entries[0..count]) |entry| {
            total_entries += 1;
            if (std.mem.eql(u8, entry.name, "file1.txt")) {
                found_file1 = true;
                try std.testing.expectEqual(Io.File.Kind.file, entry.kind);
            }
            if (std.mem.eql(u8, entry.name, "file2.txt")) {
                found_file2 = true;
                try std.testing.expectEqual(Io.File.Kind.file, entry.kind);
            }
            if (std.mem.eql(u8, entry.name, "subdir")) {
                found_subdir = true;
                try std.testing.expectEqual(Io.File.Kind.directory, entry.kind);
            }
        }
    }

    try std.testing.expect(found_file1);
    try std.testing.expect(found_file2);
    try std.testing.expect(found_subdir);
    try std.testing.expectEqual(@as(usize, 3), total_entries);
}

test "Io: Dir createDirPath" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const sep = Io.Dir.path.sep_str;
    const base_path = "test_stdio_create_dir_path";

    // Clean up from any previous failed test
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create base directory first
    try cwd.createDir(io, base_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create nested directories in one call
    const status = try cwd.createDirPathStatus(io, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c", .default_dir);
    try std.testing.expectEqual(Io.Dir.CreatePathStatus.created, status);

    // Verify all directories were created
    const dir_a = try cwd.openDir(io, base_path ++ sep ++ "a", .{});
    dir_a.close(io);

    const dir_b = try cwd.openDir(io, base_path ++ sep ++ "a" ++ sep ++ "b", .{});
    dir_b.close(io);

    const dir_c = try cwd.openDir(io, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c", .{});
    dir_c.close(io);

    // Calling again should return .existed
    const status2 = try cwd.createDirPathStatus(io, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c", .default_dir);
    try std.testing.expectEqual(Io.Dir.CreatePathStatus.existed, status2);

    // Clean up (in reverse order)
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b") catch {};
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};
}

test "Io: Dir createDirPath with existing file" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const sep = Io.Dir.path.sep_str;
    const base_path = "test_stdio_create_dir_path_file";

    // Clean up from any previous failed test
    os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create base directory
    try cwd.createDir(io, base_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create a file where we want a directory
    const file = try cwd.createFile(io, base_path ++ sep ++ "a", .{});
    file.close(io);
    defer os.fs.dirDeleteFile(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};

    // Trying to create a path through that file should fail with NotDir
    const result = cwd.createDirPathStatus(io, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c", .default_dir);
    try std.testing.expectError(error.NotDir, result);
}

test "Io: Dir createDirPathOpen" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const sep = Io.Dir.path.sep_str;
    const base_path = "test_stdio_create_dir_path_open";

    // Clean up from any previous failed test
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create base directory first
    try cwd.createDir(io, base_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create nested directories and open the result in one call
    const opened_dir = try cwd.createDirPathOpen(io, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c", .{});
    defer opened_dir.close(io);

    // Verify we got a valid directory handle
    const stat = try opened_dir.stat(io);
    try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);

    // Clean up (in reverse order)
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a" ++ sep ++ "b") catch {};
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path ++ sep ++ "a") catch {};
}

test "Io: Dir createDirPathOpen existing" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const io = rt.io();
    const cwd = Io.Dir.cwd();
    const base_path = "test_stdio_create_dir_path_open_existing";

    // Clean up from any previous failed test
    os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Create directory
    try cwd.createDir(io, base_path, .default_dir);
    defer os.fs.dirDeleteDir(std.testing.allocator, cwd.handle, base_path) catch {};

    // Open existing directory with createDirPathOpen
    const opened_dir = try cwd.createDirPathOpen(io, base_path, .{});
    defer opened_dir.close(io);

    // Verify we got a valid directory handle
    const stat = try opened_dir.stat(io);
    try std.testing.expectEqual(Io.File.Kind.directory, stat.kind);
}
