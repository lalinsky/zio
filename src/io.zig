// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Implementation of the `std.Io` interface backed by zio's runtime.
//!
//! Many vtable methods are implemented; stubs remain for batches, some
//! process operations, file locking (delegates to std), memory maps,
//! and partial directory operations.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Alignment = std.mem.Alignment;

const runtime_mod = @import("runtime.zig");
const Runtime = runtime_mod.Runtime;
const getCurrentTask = runtime_mod.getCurrentTask;
const beginShield = runtime_mod.beginShield;
const endShield = runtime_mod.endShield;
const checkCancel = runtime_mod.checkCancel;

const AnyTask = @import("task.zig").AnyTask;
const spawnTask = @import("task.zig").spawnTask;
const Awaitable = @import("awaitable.zig").Awaitable;
const Group = @import("group.zig").Group;
const groupSpawnTask = @import("group.zig").groupSpawnTask;
const select = @import("select.zig");
const Futex = @import("sync/Futex.zig");
const time = @import("time.zig");
const common = @import("common.zig");
const Waiter = common.Waiter;
const waitForIo = common.waitForIo;
const timedWaitForIo = common.timedWaitForIo;
const waitForIoUncancelable = common.waitForIoUncancelable;

const ev = @import("ev/root.zig");
const os_net = @import("os/net.zig");
const os_fs = @import("os/fs.zig");
const os_posix = @import("os/posix.zig");
const process_impl = @import("process.zig");
const zio_net = @import("net.zig");
const zio_dns = @import("dns/root.zig");
const fillBuf = @import("utils/writer.zig").fillBuf;

/// Must match `net.Stream.max_iovecs_len` in std.Io. Used as the cap on
/// scatter/gather vector counts for netRead/netWrite so we never promise
/// the caller more than std.Io's reader/writer is prepared to handle.
const max_iovecs_len = 8;

/// Construct a `std.Io` instance backed by `rt`.
pub fn fromRuntime(rt: *Runtime) Io {
    return .{
        .userdata = @ptrCast(rt),
        .vtable = &vtable,
    };
}

/// Recover the underlying runtime from a `std.Io` produced by `fromRuntime`.
///
/// Asserts that the vtable matches; passing a `std.Io` from another backend
/// is a programming error.
pub fn toRuntime(io: Io) *Runtime {
    std.debug.assert(io.vtable == &vtable);
    return @ptrCast(@alignCast(io.userdata));
}

pub const vtable: Io.VTable = .{
    .crashHandler = crashHandlerImpl,

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

    .futexWait = futexWaitImpl,
    .futexWaitUncancelable = futexWaitUncancelableImpl,
    .futexWake = futexWakeImpl,

    .operate = operateImpl,
    .batchAwaitAsync = batchAwaitAsyncImpl,
    .batchAwaitConcurrent = batchAwaitConcurrentImpl,
    .batchCancel = batchCancelImpl,

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
    .fileLength = fileLengthImpl,
    .fileClose = fileCloseImpl,
    .fileWritePositional = fileWritePositionalImpl,
    .fileWriteFileStreaming = Io.noFileWriteFileStreaming,
    .fileWriteFilePositional = Io.noFileWriteFilePositional,
    .fileReadPositional = fileReadPositionalImpl,
    .fileSeekBy = fileSeekByImpl,
    .fileSeekTo = fileSeekToImpl,
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
    .processSetCurrentPath = processSetCurrentPathImpl,
    .processReplace = processReplaceImpl,
    .processReplacePath = processReplacePathImpl,
    .processSpawn = processSpawnImpl,
    .processSpawnPath = processSpawnPathImpl,
    .childWait = childWaitImpl,
    .childKill = childKillImpl,

    .progressParentFile = progressParentFileImpl,

    .now = nowImpl,
    .clockResolution = clockResolutionImpl,
    .sleep = sleepImpl,

    .random = randomImpl,
    .randomSecure = randomSecureImpl,

    .netListenIp = netListenIpImpl,
    .netAccept = netAcceptImpl,
    .netBindIp = netBindIpImpl,
    .netConnectIp = netConnectIpImpl,
    .netListenUnix = netListenUnixImpl,
    .netConnectUnix = netConnectUnixImpl,
    .netSocketCreatePair = netSocketCreatePairImpl,
    .netSend = netSendImpl,
    .netRead = netReadImpl,
    .netWrite = netWriteImpl,
    .netWriteFile = netWriteFileImpl,
    .netClose = netCloseImpl,
    .netShutdown = netShutdownImpl,
    .netInterfaceNameResolve = netInterfaceNameResolveImpl,
    .netInterfaceName = netInterfaceNameImpl,
    .netLookup = netLookupImpl,
};

// ---------------------------------------------------------------------------
// VTable stubs. Every function below is intentionally a `@panic("TODO: …")`.
// ---------------------------------------------------------------------------

/// Delegate target for vtable methods that are pure OS calls with no event-loop
/// integration. Only safe for methods that don't open or return backend-owned
/// handles/futures.
fn globalIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn crashHandlerImpl(_: ?*anyopaque) void {}

fn asyncImpl(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    return concurrentImpl(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        // Couldn't schedule asynchronously - run synchronously and return null.
        start(context.ptr, result.ptr);
        return null;
    };
}

fn concurrentImpl(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const task = spawnTask(rt, result_len, result_alignment, context, context_alignment, .{ .regular = start }, null) catch {
        return error.ConcurrencyUnavailable;
    };
    return @ptrCast(&task.awaitable);
}

fn awaitOrCancel(any_future: *Io.AnyFuture, result: []u8, should_cancel: bool) void {
    const awaitable: *Awaitable = @ptrCast(@alignCast(any_future));

    if (should_cancel and !awaitable.hasResult()) {
        awaitable.cancel();
    }

    _ = select.waitUntilComplete(awaitable);

    const task = AnyTask.fromAwaitable(awaitable);
    const task_result = task.closure.getResultSlice(AnyTask, task);
    @memcpy(result, task_result);

    awaitable.release();
}

fn awaitImpl(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: Alignment) void {
    awaitOrCancel(any_future, result, false);
}

fn cancelImpl(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: Alignment) void {
    awaitOrCancel(any_future, result, true);
}

fn groupAsyncImpl(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    groupSpawnTask(Group.fromStd(group), rt, context, context_alignment, start) catch {
        // Couldn't schedule - run synchronously, matching std.Io.Threaded fallback.
        start(context.ptr);
    };
}

fn groupConcurrentImpl(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    groupSpawnTask(Group.fromStd(group), rt, context, context_alignment, start) catch {
        return error.ConcurrencyUnavailable;
    };
}

fn groupAwaitImpl(_: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
    return Group.fromStd(group).wait();
}

fn groupCancelImpl(_: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
    Group.fromStd(group).cancel();
}

fn recancelImpl(_: ?*anyopaque) void {
    getCurrentTask().recancel();
}

fn swapCancelProtectionImpl(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    switch (new) {
        .blocked => {
            beginShield();
            return .unblocked;
        },
        .unblocked => {
            endShield();
            return .blocked;
        },
    }
}

fn checkCancelImpl(_: ?*anyopaque) Io.Cancelable!void {
    try checkCancel();
}

fn futexWaitImpl(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    Futex.timedWait(ptr, expected, time.Timeout.fromStd(timeout)) catch |err| switch (err) {
        error.Timeout => return,
        error.Canceled => return error.Canceled,
    };
}

fn futexWaitUncancelableImpl(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    beginShield();
    defer endShield();
    Futex.wait(ptr, expected) catch unreachable;
}

fn futexWakeImpl(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    Futex.wake(ptr, max_waiters);
}

fn operateImpl(_: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        .file_read_streaming => |*o| return .{ .file_read_streaming = result: {
            const n = fileReadStreamingImpl(o.file, o.data) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| break :result e,
            };
            break :result n;
        } },
        .file_write_streaming => |*o| return .{ .file_write_streaming = result: {
            const n = fileWriteStreamingImpl(o.file, o.header, o.data, o.splat) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| break :result e,
            };
            break :result n;
        } },
        .device_io_control => |*o| return .{ .device_io_control = common.blockInPlace(deviceIoControlBlocking, .{o}) },
        .net_receive => |*o| return .{ .net_receive = result: {
            netReceiveImpl(o.socket_handle, &o.message_buffer[0], o.data_buffer, o.flags) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| break :result .{ e, 0 },
            };
            break :result .{ null, 1 };
        } },
    }
}

fn deviceIoControlBlocking(o: *const Io.Operation.DeviceIoControl) Io.Operation.DeviceIoControl.Result {
    if (builtin.os.tag == .windows) @panic("device_io_control: not supported on Windows");
    return os_fs.ioctl(stdIoHandleToZio(o.file.handle), o.code, o.arg);
}

/// Read from `file` at its current position into `data`, advancing the
/// position. Returns `error.EndOfStream` on EOF (OS returned 0 bytes).
fn fileReadStreamingImpl(
    file: Io.File,
    data: []const []u8,
) (Io.Operation.FileReadStreaming.Error || Io.Cancelable)!usize {
    var iovecs: [max_iovecs_len]os_fs.iovec = undefined;
    var count: usize = 0;
    for (data) |buf| {
        if (count == iovecs.len) break;
        if (buf.len != 0) {
            iovecs[count] = os_net.iovecFromSlice(buf);
            count += 1;
        }
    }
    if (count == 0) return 0;

    var op = ev.FileReadStreaming.init(stdIoHandleToZio(file.handle), .{ .iovecs = iovecs[0..count] });
    try waitForIo(&op.c);
    const n = op.getResult() catch |err| switch (err) {
        error.BrokenPipe => return error.Unexpected,
        else => |e| return e,
    };
    return if (n == 0) error.EndOfStream else n;
}

/// Write from `header` / `data` (with `splat` repetition of the last slice)
/// to `file` at its current position, advancing the position.
fn fileWriteStreamingImpl(
    file: Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) (Io.Operation.FileWriteStreaming.Error || Io.Cancelable)!usize {
    var slices: [max_iovecs_len][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    const n = fillBuf(&slices, header, data, splat, &splat_buf);
    if (n == 0) return 0;

    var iovecs: [max_iovecs_len]os_fs.iovec_const = undefined;
    const wbuf = ev.WriteBuf.fromSlices(slices[0..n], &iovecs);

    var op = ev.FileWriteStreaming.init(stdIoHandleToZio(file.handle), wbuf);
    try waitForIo(&op.c);
    return try op.getResult();
}

// TODO: implement true concurrent batch operations
fn batchAwaitAsyncImpl(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    var tail_index = batch.completed.tail;
    defer batch.completed.tail = tail_index;
    var index = batch.submitted.head;
    errdefer batch.submitted.head = index;
    while (index != .none) {
        const storage = &batch.storage[index.toIndex()];
        const submission = &storage.submission;
        const next_index = submission.node.next;
        const result = try operateImpl(userdata, submission.operation);

        switch (tail_index) {
            .none => batch.completed.head = index,
            else => |ti| batch.storage[ti.toIndex()].completion.node.next = index,
        }
        storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        tail_index = index;
        index = next_index;
    }
    batch.submitted = .{ .head = .none, .tail = .none };
}

fn batchAwaitConcurrentImpl(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    // TODO: implement true concurrent batch operations
    return error.ConcurrencyUnavailable;
}

fn batchCancelImpl(_: ?*anyopaque, batch: *Io.Batch) void {
    // TODO: implement proper cancellation for pending operations
    // For now, just ensure pending list is empty (nothing is actually pending in our linear impl)
    batch.pending = .{ .head = .none, .tail = .none };
}

fn dirCreateDirImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    var op = ev.DirCreateDir.init(stdIoHandleToZio(dir.handle), sub_path, permissionsToZioMode(permissions));
    try waitForIo(&op.c);
    try op.getResult();
}

fn permissionsToZioMode(permissions: Io.File.Permissions) os_fs.mode_t {
    if (builtin.os.tag == .windows) return 0;
    return permissions.toMode();
}

/// Resolve a `std.Io.File.SetTimestamp` union into the `?i96` nanoseconds
/// representation expected by `os_fs.FileTimestamps` (null == UTIME_OMIT).
/// `.now` is evaluated against the realtime clock at call time.
fn resolveSetTimestamp(t: Io.File.SetTimestamp) ?i96 {
    return switch (t) {
        .unchanged => null,
        .now => @intCast(time.Timestamp.now(.realtime).toNanoseconds()),
        .new => |ts| ts.nanoseconds,
    };
}

fn dirCreateDirPathImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    var it = Io.Dir.path.componentIterator(sub_path);
    var status: Io.Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        var op = ev.DirCreateDir.init(stdIoHandleToZio(dir.handle), component.path, permissionsToZioMode(permissions));
        try waitForIo(&op.c);
        if (op.getResult()) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                const kind = try filePathKind(dir, component.path);
                if (kind != .directory) return error.NotDir;
            },
            error.FileNotFound => {
                component = it.previous() orelse return error.FileNotFound;
                continue;
            },
            else => |e| return e,
        }
        component = it.next() orelse return status;
    }
}

fn filePathKind(dir: Io.Dir, sub_path: []const u8) Io.Dir.StatFileError!Io.File.Kind {
    var op = ev.FileStat.init(stdIoHandleToZio(dir.handle), sub_path, .{ .follow_symlinks = false });
    try waitForIo(&op.c);
    const info = op.getResult() catch |err| return statFileErrToStdErr(err);
    return zioKindToStdIoKind(info.kind);
}

fn dirCreateDirPathOpenImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.Dir.Permissions, options: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    return dirOpenDirImpl(null, dir, sub_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try dirCreateDirPathImpl(null, dir, sub_path, permissions);
            return dirOpenDirImpl(null, dir, sub_path, options);
        },
        else => |e| return e,
    };
}

fn dirOpenDirImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    var op = ev.DirOpen.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .follow_symlinks = options.follow_symlinks,
        .iterate = options.iterate,
    });
    try waitForIo(&op.c);
    const fd = op.getResult() catch |err| return dirOpenErrToStdErr(err);
    return .{ .handle = fd };
}

fn dirOpenErrToStdErr(err: ev.DirOpen.Error) Io.Dir.OpenError {
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
        error.NotDir => error.NotDir,
        error.BadPathName => error.BadPathName,
        error.NetworkNotFound => error.NetworkNotFound,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn dirStatImpl(_: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    const handle = stdIoHandleToZio(dir.handle);
    // On POSIX, Io.Dir.cwd().handle is AT_FDCWD — fstat() doesn't accept it, so
    // route through fstatat(".") in that case. Real handles (including Windows
    // cwd) go through fstat() directly, which avoids the \\?\ path pitfalls of
    // resolving "." against a handle's canonicalized path.
    const use_path: ?[]const u8 = if (builtin.os.tag != .windows and handle == os_fs.cwd()) "." else null;
    var op = ev.FileStat.init(handle, use_path, .{});
    try waitForIo(&op.c);
    const info = op.getResult() catch |err| return fileStatErrToStdErr(err);
    return statInfoToStdIo(info);
}

fn dirStatFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    var op = ev.FileStat.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    const info = op.getResult() catch |err| return statFileErrToStdErr(err);
    return statInfoToStdIo(info);
}

fn dirAccessImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    var op = ev.DirAccess.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .read = options.read,
        .write = options.write,
        .execute = options.execute,
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn openErrToFileErr(err: ev.FileOpen.Error) Io.File.OpenError {
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
        error.FileLocksNotSupported => error.FileLocksUnsupported,
        error.BadPathName => error.BadPathName,
        error.NetworkNotFound => error.NetworkNotFound,
        error.FileBusy => error.FileBusy,
        error.Canceled => error.Canceled,
        error.InvalidUtf8,
        error.InvalidWtf8,
        error.ProcessNotFound,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn stdIoModeToZio(mode: Io.Dir.OpenFileOptions.Mode) os_fs.FileOpenMode {
    return switch (mode) {
        .read_only => .read_only,
        .write_only => .write_only,
        .read_write => .read_write,
    };
}

fn dirCreateFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    if (options.lock != .none) @panic("TODO: createFile lock");
    if (options.lock_nonblocking) @panic("TODO: createFile lock_nonblocking");
    if (options.resolve_beneath) @panic("TODO: createFile resolve_beneath");
    var op = ev.FileCreate.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .read = options.read,
        .truncate = options.truncate,
        .exclusive = options.exclusive,
        .mode = permissionsToZioMode(options.permissions),
    });
    try waitForIo(&op.c);
    const fd = op.getResult() catch |err| return openErrToFileErr(err);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dirCreateFileAtomicImpl(_: ?*anyopaque, dir: Io.Dir, dest_path: []const u8, options: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    if (Io.Dir.path.dirname(dest_path)) |dirname| {
        const new_dir = if (options.make_path)
            dirCreateDirPathOpenImpl(null, dir, dirname, .default_dir, .{}) catch |err| switch (err) {
                error.IsDir,
                error.Streaming,
                error.DiskQuota,
                error.PathAlreadyExists,
                error.LinkQuotaExceeded,
                error.PipeBusy,
                error.FileTooBig,
                error.FileLocksUnsupported,
                error.DeviceBusy,
                => return error.Unexpected,
                else => |e| return e,
            }
        else
            try dirOpenDirImpl(null, dir, dirname, .{});
        errdefer dirCloseImpl(null, &.{new_dir});
        return atomicFileInit(Io.Dir.path.basename(dest_path), options.permissions, new_dir, true);
    }
    return atomicFileInit(dest_path, options.permissions, dir, false);
}

fn atomicFileInit(
    dest_basename: []const u8,
    permissions: Io.File.Permissions,
    dir: Io.Dir,
    close_dir_on_deinit: bool,
) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    while (true) {
        var random_integer: u64 = undefined;
        randomImpl(null, std.mem.asBytes(&random_integer));
        const tmp_sub_path = std.fmt.hex(random_integer);
        const file = dirCreateFileImpl(null, dir, &tmp_sub_path, .{
            .permissions = permissions,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists, error.DeviceBusy, error.FileBusy => continue,
            error.IsDir, error.FileTooBig, error.FileLocksUnsupported, error.PipeBusy => return error.Unexpected,
            else => |e| return e,
        };
        return .{
            .file = file,
            .file_basename_hex = random_integer,
            .dest_sub_path = dest_basename,
            .file_open = true,
            .file_exists = true,
            .close_dir_on_deinit = close_dir_on_deinit,
            .dir = dir,
        };
    }
}

fn dirOpenFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    if (options.path_only) @panic("TODO: openFile path_only");
    if (options.lock != .none) @panic("TODO: openFile lock");
    if (options.lock_nonblocking) @panic("TODO: openFile lock_nonblocking");
    if (options.allow_ctty) @panic("TODO: openFile allow_ctty");
    if (!options.follow_symlinks) @panic("TODO: openFile follow_symlinks=false");
    if (options.resolve_beneath) @panic("TODO: openFile resolve_beneath");
    var op = ev.FileOpen.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .mode = stdIoModeToZio(options.mode),
        .allow_directory = options.allow_directory,
    });
    try waitForIo(&op.c);
    const fd = op.getResult() catch |err| return openErrToFileErr(err);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dirCloseImpl(_: ?*anyopaque, dirs: []const Io.Dir) void {
    var i: usize = 0;
    while (i < dirs.len) {
        var ops: [8]ev.DirClose = undefined;
        var group = ev.Group.init(.gather);
        const n = @min(ops.len, dirs.len - i);
        for (0..n) |j| {
            ops[j] = ev.DirClose.init(stdIoHandleToZio(dirs[i + j].handle));
            group.add(&ops[j].c);
        }
        waitForIoUncancelable(&group.c);
        i += n;
    }
}

fn dirReadImpl(_: ?*anyopaque, r: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    var entry_index: usize = 0;
    // Create iterator once to preserve name_index across entries (Windows).
    // Fields are updated in the loop as r.index/r.end change.
    var it = os_fs.DirEntryIterator.init(r.buffer, r.index, r.end);

    while (entry_index < entries.len) {
        if (r.end - r.index == 0) {
            if (entry_index > 0) break;
            if (r.state == .finished) return 0;

            const restart = r.state == .reset;
            r.state = .reading;

            var op = ev.DirRead.init(stdIoHandleToZio(r.dir.handle), r.buffer, restart);
            waitForIo(&op.c) catch |err| {
                r.state = .reset;
                return err;
            };
            const n = op.getResult() catch |err| {
                r.state = .reset;
                return err;
            };
            if (n == 0) {
                r.state = .finished;
                return 0;
            }
            r.index = 0;
            r.end = n;
            it.index = 0;
            it.end = n;
        } else {
            it.index = r.index;
            it.end = r.end;
        }

        const entry = it.next() orelse {
            r.index = it.index;
            r.end = it.end;
            continue;
        };
        r.index = it.index;

        entries[entry_index] = .{
            .name = entry.name,
            .kind = zioKindToStdIoKind(entry.kind),
            .inode = entry.inode,
        };
        entry_index += 1;
    }
    return entry_index;
}

fn dirRealPathImpl(_: ?*anyopaque, dir: Io.Dir, out_buffer: []u8) Io.Dir.RealPathError!usize {
    var op = ev.DirRealPath.init(stdIoHandleToZio(dir.handle), out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirRealPathFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, out_buffer: []u8) Io.Dir.RealPathFileError!usize {
    var op = ev.DirRealPathFile.init(stdIoHandleToZio(dir.handle), sub_path, out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirDeleteFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteFileError!void {
    var op = ev.DirDeleteFile.init(stdIoHandleToZio(dir.handle), sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirDeleteDirImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8) Io.Dir.DeleteDirError!void {
    var op = ev.DirDeleteDir.init(stdIoHandleToZio(dir.handle), sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirRenameImpl(_: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenameError!void {
    var op = ev.DirRename.init(stdIoHandleToZio(old_dir.handle), old_sub_path, stdIoHandleToZio(new_dir.handle), new_sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirRenamePreserveImpl(_: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8) Io.Dir.RenamePreserveError!void {
    var op = ev.DirRenamePreserve.init(stdIoHandleToZio(old_dir.handle), old_sub_path, stdIoHandleToZio(new_dir.handle), new_sub_path);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSymLinkImpl(_: ?*anyopaque, dir: Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) Io.Dir.SymLinkError!void {
    var op = ev.DirSymLink.init(stdIoHandleToZio(dir.handle), target_path, sym_link_path, .{
        .is_directory = flags.is_directory,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirReadLinkImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, buffer: []u8) Io.Dir.ReadLinkError!usize {
    var op = ev.DirReadLink.init(stdIoHandleToZio(dir.handle), sub_path, buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn dirSetOwnerImpl(_: ?*anyopaque, dir: Io.Dir, owner: ?Io.File.Uid, group: ?Io.File.Gid) Io.Dir.SetOwnerError!void {
    var op = ev.DirSetOwner.init(stdIoHandleToZio(dir.handle), owner, group);
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetFileOwnerImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, owner: ?Io.File.Uid, group: ?Io.File.Gid, options: Io.Dir.SetFileOwnerOptions) Io.Dir.SetFileOwnerError!void {
    var op = ev.DirSetFileOwner.init(stdIoHandleToZio(dir.handle), sub_path, owner, group, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetPermissionsImpl(_: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    var op = ev.DirSetPermissions.init(stdIoHandleToZio(dir.handle), permissionsToZioMode(permissions));
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetFilePermissionsImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    var op = ev.DirSetFilePermissions.init(stdIoHandleToZio(dir.handle), sub_path, permissionsToZioMode(permissions), .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirSetTimestampsImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.SetTimestampsOptions) Io.Dir.SetTimestampsError!void {
    var op = ev.DirSetFileTimestamps.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .atime = resolveSetTimestamp(options.access_timestamp),
        .mtime = resolveSetTimestamp(options.modify_timestamp),
    }, .{ .follow_symlinks = options.follow_symlinks });
    try waitForIo(&op.c);
    try op.getResult();
}

fn dirHardLinkImpl(_: ?*anyopaque, old_dir: Io.Dir, old_sub_path: []const u8, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.Dir.HardLinkOptions) Io.Dir.HardLinkError!void {
    var op = ev.DirHardLink.init(stdIoHandleToZio(old_dir.handle), old_sub_path, stdIoHandleToZio(new_dir.handle), new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileStatImpl(_: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    var op = ev.FileStat.init(stdIoHandleToZio(file.handle), null, .{});
    try waitForIo(&op.c);
    const info = op.getResult() catch |err| return fileStatErrToStdErr(err);
    return statInfoToStdIo(info);
}

fn fileLengthImpl(_: ?*anyopaque, file: Io.File) Io.File.LengthError!u64 {
    var op = ev.FileStat.init(stdIoHandleToZio(file.handle), null, .{});
    try waitForIo(&op.c);
    const info = op.getResult() catch |err| return fileStatErrToStdErr(err);
    return info.size;
}

fn fileStatErrToStdErr(err: ev.FileStat.Error) Io.File.StatError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        // Should not happen for an already-open fd or dir handle.
        error.InvalidFileDescriptor,
        error.FileNotFound,
        error.NameTooLong,
        error.NotDir,
        error.SymLinkLoop,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn statFileErrToStdErr(err: ev.FileStat.Error) Io.Dir.StatFileError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.FileNotFound => error.FileNotFound,
        error.NameTooLong => error.NameTooLong,
        error.NotDir => error.NotDir,
        error.SymLinkLoop => error.SymLinkLoop,
        error.InvalidFileDescriptor,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn statInfoToStdIo(info: os_fs.FileStatInfo) Io.File.Stat {
    return .{
        .inode = info.inode,
        .nlink = @intCast(info.nlink),
        .size = info.size,
        .permissions = zioModeToPermissions(info.mode),
        .kind = zioKindToStdIoKind(info.kind),
        .block_size = info.block_size,
        .atime = .{ .nanoseconds = info.atime },
        .mtime = .{ .nanoseconds = info.mtime },
        .ctime = .{ .nanoseconds = info.ctime },
    };
}

fn zioModeToPermissions(mode: os_fs.mode_t) Io.File.Permissions {
    return switch (builtin.os.tag) {
        // Zio's FileStatInfo.mode is always 0 on Windows — attributes aren't
        // captured, so fall back to the default.
        .windows => .default_file,
        else => .fromMode(mode),
    };
}

fn zioKindToStdIoKind(kind: os_fs.FileKind) Io.File.Kind {
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

fn fileCloseImpl(_: ?*anyopaque, files: []const Io.File) void {
    var i: usize = 0;
    while (i < files.len) {
        var ops: [8]ev.FileClose = undefined;
        var group = ev.Group.init(.gather);
        const n = @min(ops.len, files.len - i);
        for (0..n) |j| {
            ops[j] = ev.FileClose.init(stdIoHandleToZio(files[i + j].handle));
            group.add(&ops[j].c);
        }
        waitForIoUncancelable(&group.c);
        i += n;
    }
}

fn fileWritePositionalImpl(_: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    var slices: [max_iovecs_len][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    const n = fillBuf(&slices, header, data, splat, &splat_buf);
    if (n == 0) return 0;

    var iovecs: [max_iovecs_len]os_fs.iovec_const = undefined;
    const wbuf = ev.WriteBuf.fromSlices(slices[0..n], &iovecs);

    var op = ev.FileWrite.init(stdIoHandleToZio(file.handle), wbuf, offset);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn fileReadPositionalImpl(_: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    var iovecs: [max_iovecs_len]os_fs.iovec = undefined;
    var count: usize = 0;
    for (data) |buf| {
        if (count == iovecs.len) break;
        if (buf.len != 0) {
            iovecs[count] = os_net.iovecFromSlice(buf);
            count += 1;
        }
    }
    if (count == 0) return 0;

    var op = ev.FileRead.init(stdIoHandleToZio(file.handle), .{ .iovecs = iovecs[0..count] }, offset);
    try waitForIo(&op.c);
    return op.getResult() catch |err| switch (err) {
        error.BrokenPipe => error.Unexpected,
        else => |e| e,
    };
}

fn fileSeekByImpl(_: ?*anyopaque, file: Io.File, offset: i64) Io.File.SeekError!void {
    const io = globalIo();
    return io.vtable.fileSeekBy(io.userdata, file, offset);
}

fn fileSeekToImpl(_: ?*anyopaque, file: Io.File, offset: u64) Io.File.SeekError!void {
    const io = globalIo();
    return io.vtable.fileSeekTo(io.userdata, file, offset);
}

fn fileSyncImpl(_: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    var op = ev.FileSync.init(stdIoHandleToZio(file.handle), .{});
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileIsTtyImpl(_: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    const io = globalIo();
    return io.vtable.fileIsTty(io.userdata, file);
}

fn fileEnableAnsiEscapeCodesImpl(_: ?*anyopaque, file: Io.File) Io.File.EnableAnsiEscapeCodesError!void {
    const io = globalIo();
    return io.vtable.fileEnableAnsiEscapeCodes(io.userdata, file);
}

fn fileSupportsAnsiEscapeCodesImpl(_: ?*anyopaque, file: Io.File) Io.Cancelable!bool {
    const io = globalIo();
    return io.vtable.fileSupportsAnsiEscapeCodes(io.userdata, file);
}

fn fileSetLengthImpl(_: ?*anyopaque, file: Io.File, new_length: u64) Io.File.SetLengthError!void {
    var op = ev.FileSetSize.init(stdIoHandleToZio(file.handle), new_length);
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetOwnerImpl(_: ?*anyopaque, file: Io.File, owner: ?Io.File.Uid, group: ?Io.File.Gid) Io.File.SetOwnerError!void {
    var op = ev.FileSetOwner.init(stdIoHandleToZio(file.handle), owner, group);
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetPermissionsImpl(_: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    var op = ev.FileSetPermissions.init(stdIoHandleToZio(file.handle), permissionsToZioMode(permissions));
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileSetTimestampsImpl(_: ?*anyopaque, file: Io.File, options: Io.File.SetTimestampsOptions) Io.File.SetTimestampsError!void {
    var op = ev.FileSetTimestamps.init(stdIoHandleToZio(file.handle), .{
        .atime = resolveSetTimestamp(options.access_timestamp),
        .mtime = resolveSetTimestamp(options.modify_timestamp),
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileLockBlocking(file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
    const io = globalIo();
    return io.vtable.fileLock(io.userdata, file, lock);
}

fn fileLockImpl(_: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!void {
    // TODO: cancellation not supported; to fix, retry flock(LOCK_NB) in a loop with zio.sleep between attempts
    return common.blockInPlace(fileLockBlocking, .{ file, lock });
}

fn fileTryLockImpl(_: ?*anyopaque, file: Io.File, lock: Io.File.Lock) Io.File.LockError!bool {
    const io = globalIo();
    return io.vtable.fileTryLock(io.userdata, file, lock);
}

fn fileUnlockImpl(_: ?*anyopaque, file: Io.File) void {
    const io = globalIo();
    return io.vtable.fileUnlock(io.userdata, file);
}

fn fileDowngradeLockImpl(_: ?*anyopaque, file: Io.File) Io.File.DowngradeLockError!void {
    const io = globalIo();
    return io.vtable.fileDowngradeLock(io.userdata, file);
}

fn fileRealPathImpl(_: ?*anyopaque, file: Io.File, out_buffer: []u8) Io.File.RealPathError!usize {
    var op = ev.FileRealPath.init(stdIoHandleToZio(file.handle), out_buffer);
    try waitForIo(&op.c);
    return try op.getResult();
}

fn fileHardLinkImpl(_: ?*anyopaque, file: Io.File, new_dir: Io.Dir, new_sub_path: []const u8, options: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
    var op = ev.FileHardLink.init(stdIoHandleToZio(file.handle), stdIoHandleToZio(new_dir.handle), new_sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    try waitForIo(&op.c);
    try op.getResult();
}

fn fileMemoryMapCreateImpl(_: ?*anyopaque, _: Io.File, _: Io.File.MemoryMap.CreateOptions) Io.File.MemoryMap.CreateError!Io.File.MemoryMap {
    @panic("fileMemoryMapCreate: not supported");
}

fn fileMemoryMapDestroyImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) void {
    @panic("fileMemoryMapDestroy: not supported");
}

fn fileMemoryMapSetLengthImpl(_: ?*anyopaque, _: *Io.File.MemoryMap, _: usize) Io.File.MemoryMap.SetLengthError!void {
    @panic("fileMemoryMapSetLength: not supported");
}

fn fileMemoryMapReadImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
    @panic("fileMemoryMapRead: not supported");
}

fn fileMemoryMapWriteImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
    @panic("fileMemoryMapWrite: not supported");
}

fn processExecutableOpenImpl(_: ?*anyopaque, _: Io.Dir.OpenFileOptions) std.process.OpenExecutableError!Io.File {
    @panic("processExecutableOpen: not supported");
}

fn processExecutablePathImpl(_: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
    const io = globalIo();
    return io.vtable.processExecutablePath(io.userdata, buffer);
}

fn lockStderrImpl(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    @panic("lockStderr: not supported");
}

fn tryLockStderrImpl(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    @panic("tryLockStderr: not supported");
}

fn unlockStderrImpl(_: ?*anyopaque) void {
    @panic("unlockStderr: not supported");
}

fn processCurrentPathImpl(_: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
    const io = globalIo();
    return io.vtable.processCurrentPath(io.userdata, buffer);
}

fn processSetCurrentDirImpl(_: ?*anyopaque, dir: Io.Dir) std.process.SetCurrentDirError!void {
    const io = globalIo();
    return io.vtable.processSetCurrentDir(io.userdata, dir);
}

fn processSetCurrentPathImpl(_: ?*anyopaque, path: []const u8) std.process.SetCurrentPathError!void {
    const io = globalIo();
    return io.vtable.processSetCurrentPath(io.userdata, path);
}

// TODO: implement using our own execve wrapper
fn processReplaceImpl(_: ?*anyopaque, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const io = globalIo();
    return io.vtable.processReplace(io.userdata, options);
}

// TODO: implement using our own execve wrapper
fn processReplacePathImpl(_: ?*anyopaque, dir: Io.Dir, options: std.process.ReplaceOptions) std.process.ReplaceError {
    const io = globalIo();
    return io.vtable.processReplacePath(io.userdata, dir, options);
}

// TODO: implement using our own posix_spawn/fork+exec wrapper
fn processSpawnImpl(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var threaded: Io.Threaded = .init(rt.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try io.vtable.processSpawn(io.userdata, options);
    setChildPipesNonblocking(&child);
    return child;
}

// TODO: implement using our own posix_spawn/fork+exec wrapper
fn processSpawnPathImpl(userdata: ?*anyopaque, dir: Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    var threaded: Io.Threaded = .init(rt.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try io.vtable.processSpawnPath(io.userdata, dir, options);
    setChildPipesNonblocking(&child);
    return child;
}

fn setChildPipesNonblocking(child: *std.process.Child) void {
    if (builtin.os.tag == .windows) return;
    if (child.stdin) |f| os_posix.setNonblocking(f.handle) catch {};
    if (child.stdout) |f| os_posix.setNonblocking(f.handle) catch {};
    if (child.stderr) |f| os_posix.setNonblocking(f.handle) catch {};
}

fn childWaitImpl(_: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    return process_impl.childWait(child);
}

fn childKillImpl(_: ?*anyopaque, child: *std.process.Child) void {
    process_impl.childKill(child);
}

fn progressParentFileImpl(_: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    @panic("progressParentFile: not supported");
}

fn nowImpl(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const ts = switch (clock) {
        .real => time.Timestamp.now(.realtime),
        .awake, .boot => time.Timestamp.now(.monotonic),
        // zio does not expose CPU-time clocks yet. Callers should check
        // `clockResolution` (returns `ClockUnavailable`) before relying on these.
        .cpu_process, .cpu_thread => return .{ .nanoseconds = 0 },
    };
    return .{ .nanoseconds = @intCast(ts.toNanoseconds()) };
}

fn clockResolutionImpl(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    return switch (clock) {
        .real, .awake, .boot => .{ .nanoseconds = 1 },
        .cpu_process, .cpu_thread => error.ClockUnavailable,
    };
}

fn sleepImpl(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    if (timeout == .none) return;
    var waiter: Waiter = .init();
    try waiter.timedWait(1, time.Timeout.fromStd(timeout), .allow_cancel);
}

fn randomImpl(_: ?*anyopaque, buffer: []u8) void {
    const io = globalIo();
    io.vtable.random(io.userdata, buffer);
}

fn randomSecureImpl(_: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const io = globalIo();
    return io.vtable.randomSecure(io.userdata, buffer);
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

fn sockAddrLen(addr: *const os_net.sockaddr) os_net.socklen_t {
    return switch (addr.family) {
        std.posix.AF.INET => @sizeOf(os_net.sockaddr.in),
        std.posix.AF.INET6 => @sizeOf(os_net.sockaddr.in6),
        else => unreachable,
    };
}

fn stdIoHandleToZio(h: Io.net.Socket.Handle) os_net.fd_t {
    return if (@typeInfo(os_net.fd_t) == .pointer) @ptrCast(h) else h;
}

const OpenOrCancel = os_net.OpenError || common.Cancelable;
const BindOrCancel = os_net.BindError || common.Cancelable;
const ListenOrCancel = os_net.ListenError || common.Cancelable;
const ConnectOrCancel = os_net.ConnectError || common.Cancelable;
const AcceptOrCancel = os_net.AcceptError || common.Cancelable;

/// Map zio socket-open errors into the subset of std.Io listen/connect errors
/// they can surface through.
fn openErrToListenErr(err: OpenOrCancel) Io.net.IpAddress.ListenError {
    return switch (err) {
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.ProtocolNotSupported => error.ProtocolUnsupportedBySystem,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.PermissionDenied => error.Unexpected,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn bindErrToListenErr(err: BindOrCancel) Io.net.IpAddress.ListenError {
    return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.AccessDenied,
        error.FileDescriptorNotASocket,
        error.SymLinkLoop,
        error.NameTooLong,
        error.FileNotFound,
        error.NotDir,
        error.ReadOnlyFileSystem,
        error.InputOutput,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn listenErrToListenErr(err: ListenOrCancel) Io.net.IpAddress.ListenError {
    return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.OperationNotSupported => error.SocketModeUnsupported,
        error.Canceled => error.Canceled,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn netListenIpImpl(_: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ListenOptions) Io.net.IpAddress.ListenError!Io.net.Socket {
    const zio_addr = stdIoIpToZio(address.*);

    var open_op = ev.NetOpen.init(.fromPosix(zio_addr.any.family), .fromStd(options.mode), .fromStd(options.protocol), .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToListenErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    if (options.reuse_address) {
        const value: c_int = 1;
        os_net.setsockopt(handle, os_net.SOL.SOCKET, os_net.SO.REUSEADDR, std.mem.asBytes(&value)) catch
            return error.OptionUnsupported;
        if (@hasDecl(os_net.SO, "REUSEPORT")) {
            os_net.setsockopt(handle, os_net.SOL.SOCKET, os_net.SO.REUSEPORT, std.mem.asBytes(&value)) catch {};
        }
    }

    var bind_addr = zio_addr;
    var addr_len = sockAddrLen(&bind_addr.any);
    var bind_op = ev.NetBind.init(handle, &bind_addr.any, &addr_len);
    try waitForIo(&bind_op.c);
    bind_op.getResult() catch |err| return bindErrToListenErr(err);

    var listen_op = ev.NetListen.init(handle, options.kernel_backlog);
    try waitForIo(&listen_op.c);
    listen_op.getResult() catch |err| return listenErrToListenErr(err);

    return .{
        .handle = handle,
        .address = zioIpToStdIo(bind_addr),
    };
}

fn netAcceptImpl(_: ?*anyopaque, server: Io.net.Socket.Handle, _: Io.net.Server.AcceptOptions) Io.net.Server.AcceptError!Io.net.Socket {
    var peer_addr: zio_net.Address = undefined;
    var peer_addr_len: os_net.socklen_t = @sizeOf(zio_net.Address);

    var op = ev.NetAccept.init(stdIoHandleToZio(server), &peer_addr.any, &peer_addr_len);
    try waitForIo(&op.c);
    const handle = op.getResult() catch |err| switch (err) {
        error.WouldBlock => return error.WouldBlock,
        error.ConnectionAborted => return error.ConnectionAborted,
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
        error.SystemResources => return error.SystemResources,
        error.SocketNotListening => return error.SocketNotListening,
        error.ProtocolFailure => return error.ProtocolFailure,
        error.BlockedByFirewall => return error.BlockedByFirewall,
        error.NetworkDown => return error.NetworkDown,
        error.Canceled => return error.Canceled,
        error.ConnectionResetByPeer,
        error.FileDescriptorNotASocket,
        error.OperationNotSupported,
        error.Unexpected,
        => return error.Unexpected,
    };

    return .{
        .handle = handle,
        .address = switch (peer_addr.any.family) {
            os_net.AF.INET, os_net.AF.INET6 => zioIpToStdIo(peer_addr.ip),
            // std.Io.net.Socket.address is an IpAddress; use an IPv4 loopback
            // placeholder for Unix peers, matching std.Io.UnixAddress.listen.
            else => .{ .ip4 = .loopback(0) },
        },
    };
}

fn openErrToBindErr(err: OpenOrCancel) Io.net.IpAddress.BindError {
    return switch (err) {
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.ProtocolNotSupported => error.ProtocolUnsupportedBySystem,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.PermissionDenied => error.Unexpected,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn bindErrToBindErr(err: BindOrCancel) Io.net.IpAddress.BindError {
    return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.AccessDenied,
        error.FileDescriptorNotASocket,
        error.SymLinkLoop,
        error.NameTooLong,
        error.FileNotFound,
        error.NotDir,
        error.ReadOnlyFileSystem,
        error.InputOutput,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn netBindIpImpl(_: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.BindOptions) Io.net.IpAddress.BindError!Io.net.Socket {
    const zio_addr = stdIoIpToZio(address.*);

    var open_op = ev.NetOpen.init(.fromPosix(zio_addr.any.family), .fromStd(options.mode), if (options.protocol) |p| .fromStd(p) else .ip, .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToBindErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    if (options.ip6_only) {
        if (zio_addr.any.family != os_net.AF.INET6) return error.OptionUnsupported;
        const value: c_int = 1;
        // IPV6_V6ONLY optname: 26 on Linux, 27 on BSD/macOS/Windows.
        const v6only: u32 = switch (builtin.os.tag) {
            .linux => 26,
            else => 27,
        };
        os_net.setsockopt(handle, os_net.IPPROTO.IPV6, v6only, std.mem.asBytes(&value)) catch
            return error.OptionUnsupported;
    }

    if (options.allow_broadcast) {
        if (@hasDecl(os_net.SO, "BROADCAST")) {
            const value: c_int = 1;
            os_net.setsockopt(handle, os_net.SOL.SOCKET, os_net.SO.BROADCAST, std.mem.asBytes(&value)) catch
                return error.OptionUnsupported;
        } else {
            return error.OptionUnsupported;
        }
    }

    var bind_addr = zio_addr;
    var addr_len = sockAddrLen(&bind_addr.any);
    var bind_op = ev.NetBind.init(handle, &bind_addr.any, &addr_len);
    try waitForIo(&bind_op.c);
    bind_op.getResult() catch |err| return bindErrToBindErr(err);

    return .{
        .handle = handle,
        .address = zioIpToStdIo(bind_addr),
    };
}

fn openErrToConnectErr(err: OpenOrCancel) Io.net.IpAddress.ConnectError {
    return switch (err) {
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.ProtocolNotSupported => error.ProtocolUnsupportedBySystem,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.PermissionDenied => error.AccessDenied,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn connectErrToConnectErr(err: ConnectOrCancel) Io.net.IpAddress.ConnectError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.WouldBlock => error.WouldBlock,
        error.ConnectionPending => error.ConnectionPending,
        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.Timeout => error.Timeout,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.AddressInUse,
        error.AlreadyConnected,
        error.FileDescriptorNotASocket,
        error.FileNotFound,
        error.SymLinkLoop,
        error.NameTooLong,
        error.NotDir,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn netConnectIpImpl(_: ?*anyopaque, address: *const Io.net.IpAddress, options: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const zio_addr = stdIoIpToZio(address.*);

    var open_op = ev.NetOpen.init(.fromPosix(zio_addr.any.family), .fromStd(options.mode), if (options.protocol) |p| .fromStd(p) else .ip, .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToConnectErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    const addr_len = sockAddrLen(&zio_addr.any);
    var connect_op = ev.NetConnect.init(handle, &zio_addr.any, addr_len);
    try timedWaitForIo(&connect_op.c, .fromStd(options.timeout));
    connect_op.getResult() catch |err| return connectErrToConnectErr(err);

    return .{
        .handle = handle,
        .address = zioIpToStdIo(zio_addr),
    };
}

fn netListenUnixImpl(
    _: ?*anyopaque,
    address: *const Io.net.UnixAddress,
    options: Io.net.UnixAddress.ListenOptions,
) Io.net.UnixAddress.ListenError!Io.net.Socket.Handle {
    if (comptime !zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const unix_addr = zio_net.UnixAddress.init(address.path) catch |err| switch (err) {
        error.NameTooLong => return error.AddressUnavailable,
    };

    const server = zio_net.UnixAddress.listen(unix_addr, .{
        .kernel_backlog = options.kernel_backlog,
    }) catch |err| return switch (err) {
        error.AddressFamilyUnsupported, error.ProtocolNotSupported => error.AddressFamilyUnsupported,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.PermissionDenied => error.PermissionDenied,
        error.AccessDenied => error.AccessDenied,
        error.AddressInUse => error.AddressInUse,
        error.AddressUnavailable => error.AddressUnavailable,
        error.SymLinkLoop => error.SymLinkLoop,
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.NetworkDown => error.NetworkDown,
        error.Canceled => error.Canceled,
        error.FileDescriptorNotASocket,
        error.NameTooLong,
        error.InputOutput,
        error.AlreadyConnected,
        error.OperationNotSupported,
        error.Unexpected,
        => error.Unexpected,
    };

    return server.socket.handle;
}

fn netConnectUnixImpl(
    _: ?*anyopaque,
    address: *const Io.net.UnixAddress,
) Io.net.UnixAddress.ConnectError!Io.net.Socket.Handle {
    if (comptime !zio_net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const unix_addr = zio_net.UnixAddress.init(address.path) catch |err| switch (err) {
        error.NameTooLong => return error.FileNotFound,
    };

    const stream = zio_net.UnixAddress.connect(unix_addr, .{}) catch |err| return switch (err) {
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.ProtocolNotSupported => error.ProtocolUnsupportedBySystem,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.SystemResources => error.SystemResources,
        error.PermissionDenied => error.PermissionDenied,
        error.AccessDenied => error.AccessDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.WouldBlock => error.WouldBlock,
        error.NetworkDown => error.NetworkDown,
        error.Canceled => error.Canceled,
        error.AddressInUse,
        error.AddressUnavailable,
        error.AlreadyConnected,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.Timeout,
        error.NetworkUnreachable,
        error.FileDescriptorNotASocket,
        error.NameTooLong,
        error.Unexpected,
        => error.Unexpected,
    };

    return stream.socket.handle;
}

fn netSocketCreatePairImpl(_: ?*anyopaque, options: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
    const domain: os_net.Domain = switch (options.family) {
        .ip4 => .ipv4,
        .ip6 => .ipv6,
    };
    const socket_type: os_net.Type = .fromStd(options.mode);
    const protocol: os_net.Protocol = if (options.protocol) |p| .fromStd(p) else .ip;

    const fds = try os_net.socketpair(domain, socket_type, protocol, .{ .nonblocking = true });

    // socketpair sockets are AF_UNIX in practice (AF_INET/INET6 fail with
    // PROTONOSUPPORT on Linux). The Socket.address field is an IpAddress, so
    // there's no meaningful value for an unnamed Unix socket — use an IPv4
    // loopback placeholder, matching the netAccept fallback.
    return .{
        .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } },
        .{ .handle = fds[1], .address = .{ .ip4 = .loopback(0) } },
    };
}

fn sendErrToSocketSendErr(err: ev.NetSendMsg.Error) Io.net.Socket.SendError {
    return switch (err) {
        error.MessageTooBig => error.MessageOversize,
        error.SystemResources => error.SystemResources,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.NetworkDown => error.NetworkDown,
        error.ConnectionResetByPeer, error.ConnectionAborted => error.ConnectionResetByPeer,
        error.SocketNotConnected, error.BrokenPipe => error.SocketUnconnected,
        error.AccessDenied => error.AccessDenied,
        error.Canceled => error.Canceled,
        error.WouldBlock,
        error.Timeout,
        error.FileDescriptorNotASocket,
        error.OperationNotSupported,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn netSendImpl(_: ?*anyopaque, handle: Io.net.Socket.Handle, messages: []Io.net.OutgoingMessage, flags: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    const zio_flags: os_net.SendFlags = .{
        .confirm = flags.confirm,
        .dont_route = flags.dont_route,
        .eor = flags.eor,
        .oob = flags.oob,
        .fastopen = flags.fastopen,
    };

    for (messages, 0..) |*msg, i| {
        const zio_addr = stdIoIpToZio(msg.address.*);
        const iovec = os_net.iovecConstFromSlice(msg.data_ptr[0..msg.data_len]);

        var op = ev.NetSendMsg.init(
            stdIoHandleToZio(handle),
            .{ .iovecs = (&iovec)[0..1] },
            zio_flags,
            &zio_addr.any,
            sockAddrLen(&zio_addr.any),
            if (msg.control.len != 0) msg.control else null,
        );
        waitForIo(&op.c) catch |err| return .{ err, i };
        const sent = op.getResult() catch |err| return .{ sendErrToSocketSendErr(err), i };
        msg.data_len = sent;
    }
    return .{ null, messages.len };
}

fn recvErrToReadErr(err: ev.NetRecv.Error) Io.net.Stream.Reader.Error {
    return switch (err) {
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.Timeout => error.Timeout,
        error.SocketNotConnected, error.SocketShutdown => error.SocketUnconnected,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.WouldBlock,
        error.ConnectionRefused,
        error.ConnectionAborted,
        error.FileDescriptorNotASocket,
        error.OperationNotSupported,
        error.MessageOversize,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn recvMsgErrToReceiveErr(err: ev.NetRecvMsg.Error) Io.net.Socket.ReceiveError {
    return switch (err) {
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.SocketNotConnected, error.SocketShutdown, error.ConnectionAborted => error.SocketUnconnected,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.MessageOversize => error.MessageOversize,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        // On datagram sockets, an ICMP "port unreachable" response to a prior
        // send is surfaced as ECONNREFUSED on the next receive.
        error.ConnectionRefused => error.PortUnreachable,
        error.Canceled => error.Canceled,
        error.WouldBlock,
        error.Timeout,
        error.FileDescriptorNotASocket,
        error.OperationNotSupported,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn decodeIncomingFlags(raw: u32) Io.net.IncomingMessage.Flags {
    switch (builtin.os.tag) {
        .windows => {
            // Windows WSAMSG.dwFlags uses a different bit layout than POSIX
            // msghdr.flags and doesn't distinguish most of these. Match
            // std.Io.Threaded's Windows behavior: report all-zero output flags.
            return .{ .eor = false, .trunc = false, .ctrunc = false, .oob = false, .errqueue = false };
        },
        else => {
            const MSG = std.posix.MSG;
            return .{
                .eor = (raw & MSG.EOR) != 0,
                .trunc = (raw & MSG.TRUNC) != 0,
                .ctrunc = (raw & MSG.CTRUNC) != 0,
                .oob = (raw & MSG.OOB) != 0,
                .errqueue = if (@hasDecl(MSG, "ERRQUEUE")) (raw & MSG.ERRQUEUE) != 0 else false,
            };
        },
    }
}

/// Receive a single datagram, filling `message` with its metadata and returning
/// the received bytes as a sub-slice of `data_buffer`. Mirrors the structure of
/// std.Io.Threaded's netReceivePosix: one recvmsg per call, caller loops in the
/// batch path if they want more.
fn netReceiveImpl(
    socket_handle: Io.net.Socket.Handle,
    message: *Io.net.IncomingMessage,
    data_buffer: []u8,
    flags: Io.net.ReceiveFlags,
) Io.net.Socket.ReceiveError!void {
    const zio_flags: os_net.RecvFlags = .{
        .peek = flags.peek,
        .oob = flags.oob,
        .trunc = flags.trunc,
    };
    var storage: zio_net.Address = undefined;
    var addr_len: os_net.socklen_t = @sizeOf(zio_net.Address);
    var iov = os_net.iovecFromSlice(data_buffer);
    const has_control = message.control.len != 0;
    var op = ev.NetRecvMsg.init(
        stdIoHandleToZio(socket_handle),
        .{ .iovecs = (&iov)[0..1] },
        zio_flags,
        &storage.any,
        &addr_len,
        if (has_control) message.control else null,
    );
    try waitForIo(&op.c);
    const result = op.getResult() catch |err| return recvMsgErrToReceiveErr(err);
    message.* = .{
        .from = zioIpToStdIo(storage.ip),
        // When flags.trunc is set on Linux, result.len is the full datagram
        // length — which may exceed data_buffer.len. We slice verbatim to
        // match std.Io.Threaded; callers that enable .trunc are responsible
        // for sizing data_buffer appropriately.
        .data = data_buffer[0..result.len],
        .control = if (has_control) message.control[0..result.controllen] else message.control,
        .flags = decodeIncomingFlags(result.flags),
    };
}

fn netReadImpl(_: ?*anyopaque, handle: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    var iovecs: [max_iovecs_len]os_net.iovec = undefined;
    var count: usize = 0;
    for (data) |buf| {
        if (count == iovecs.len) break;
        if (buf.len != 0) {
            iovecs[count] = os_net.iovecFromSlice(buf);
            count += 1;
        }
    }
    if (count == 0) return 0;

    var op = ev.NetRecv.init(stdIoHandleToZio(handle), .{ .iovecs = iovecs[0..count] }, .{});
    try waitForIo(&op.c);
    return op.getResult() catch |err| return recvErrToReadErr(err);
}

fn sendErrToWriteErr(err: ev.NetSend.Error) Io.net.Stream.Writer.Error {
    return switch (err) {
        error.ConnectionResetByPeer, error.ConnectionAborted => error.ConnectionResetByPeer,
        error.SocketNotConnected, error.BrokenPipe => error.SocketUnconnected,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.NetworkDown => error.NetworkDown,
        error.SystemResources => error.SystemResources,
        error.Canceled => error.Canceled,
        error.WouldBlock,
        error.AccessDenied,
        error.Timeout,
        error.FileDescriptorNotASocket,
        error.MessageTooBig,
        error.OperationNotSupported,
        error.Unexpected,
        => error.Unexpected,
    };
}

fn netWriteImpl(_: ?*anyopaque, handle: Io.net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) Io.net.Stream.Writer.Error!usize {
    var slices: [max_iovecs_len][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    const n = fillBuf(&slices, header, data, splat, &splat_buf);
    if (n == 0) return 0;

    var iovecs: [max_iovecs_len]os_net.iovec_const = undefined;
    const wbuf = ev.WriteBuf.fromSlices(slices[0..n], &iovecs);

    var op = ev.NetSend.init(stdIoHandleToZio(handle), wbuf, .{});
    try waitForIo(&op.c);
    return op.getResult() catch |err| return sendErrToWriteErr(err);
}

fn netWriteFileImpl(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []const u8, _: *Io.File.Reader, _: Io.Limit) Io.net.Stream.Writer.WriteFileError!usize {
    // As of Zig 0.16, std.Io defines this vtable slot but never calls it — every
    // std backend assigns it (Threaded panics, Dispatch/Uring return NetworkDown)
    // and no code path dispatches through it. Leave unimplemented until std wires
    // it up.
    @panic("netWriteFile is unused by std.Io as of Zig 0.16");
}

fn netCloseImpl(_: ?*anyopaque, handles: []const Io.net.Socket.Handle) void {
    var i: usize = 0;
    while (i < handles.len) {
        var ops: [8]ev.NetClose = undefined;
        var group = ev.Group.init(.gather);
        const n = @min(ops.len, handles.len - i);
        for (0..n) |j| {
            ops[j] = ev.NetClose.init(stdIoHandleToZio(handles[i + j]));
            group.add(&ops[j].c);
        }
        waitForIoUncancelable(&group.c);
        i += n;
    }
}

fn shutdownErrToStdErr(err: ev.NetShutdown.Error) Io.net.ShutdownError {
    return switch (err) {
        error.SocketUnconnected => error.SocketUnconnected,
        error.ConnectionAborted => error.ConnectionAborted,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.NetworkDown => error.NetworkDown,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn netShutdownImpl(_: ?*anyopaque, handle: Io.net.Socket.Handle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
    const zio_how: os_net.ShutdownHow = switch (how) {
        .recv => .receive,
        .send => .send,
        .both => .both,
    };
    var op = ev.NetShutdown.init(stdIoHandleToZio(handle), zio_how);
    try waitForIo(&op.c);
    op.getResult() catch |err| return shutdownErrToStdErr(err);
}

fn netInterfaceNameResolveImpl(_: ?*anyopaque, name: *const Io.net.Interface.Name) Io.net.Interface.Name.ResolveError!Io.net.Interface {
    const io = globalIo();
    return io.vtable.netInterfaceNameResolve(io.userdata, name);
}

fn netInterfaceNameImpl(_: ?*anyopaque, interface: Io.net.Interface) Io.net.Interface.NameError!Io.net.Interface.Name {
    const io = globalIo();
    return io.vtable.netInterfaceName(io.userdata, interface);
}

fn netLookupImpl(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    const rt: *Runtime = @ptrCast(@alignCast(userdata));
    const io = fromRuntime(rt);
    defer resolved.close(io);

    var result = zio_dns.lookup(.{
        .name = host_name.bytes,
        .port = options.port,
        .family = if (options.family) |f| switch (f) {
            .ip4 => .ipv4,
            .ip6 => .ipv6,
        } else null,
        .canonical_name = options.canonical_name_buffer != null,
    }) catch |err| return dnsLookupErrToStdErr(err);
    defer result.deinit();

    while (result.next()) |entry| switch (entry) {
        .address => |addr| {
            resolved.putOne(io, .{ .address = zioIpToStdIo(addr) }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable, // caller must not close `resolved` until we return
            };
        },
        .canonical_name => |name| {
            if (name.bytes.len > Io.net.HostName.max_len) return error.InvalidDnsCnameRecord;
            const buf = options.canonical_name_buffer.?;
            const dest = buf[0..name.bytes.len];
            @memcpy(dest, name.bytes);
            resolved.putOne(io, .{ .canonical_name = .{ .bytes = dest } }) catch |err| switch (err) {
                error.Canceled => |e| return e,
                error.Closed => unreachable,
            };
        },
    };
}

fn dnsLookupErrToStdErr(err: zio_dns.LookupError) Io.net.HostName.LookupError {
    return switch (err) {
        error.UnknownHostName => error.UnknownHostName,
        error.NameServerFailure, error.TemporaryNameServerFailure => error.NameServerFailure,
        error.HostLacksNetworkAddresses => error.NoAddressReturned,
        error.AddressFamilyUnsupported => error.AddressFamilyUnsupported,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemResources, error.OutOfMemory => error.SystemResources,
        error.Canceled => error.Canceled,
        error.Unexpected, error.ServiceUnavailable, error.NoThreadPool, error.RuntimeShutdown => error.Unexpected,
        error.Closed => unreachable,
    };
}

test {
    _ = process_impl;
}

test "Runtime.io / Runtime.fromIo round-trip" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const value = rt.io();
    try std.testing.expect(value.vtable == &vtable);
    try std.testing.expectEqual(rt, Runtime.fromIo(value));
}

test "io: async/await returns task result" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn doubleIt(x: i32) i32 {
            return x * 2;
        }

        fn run(io: Io) !void {
            var future = io.async(doubleIt, .{21});
            const value = future.await(io);
            try std.testing.expectEqual(@as(i32, 42), value);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: Io.Mutex lock/unlock serializes tasks" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const State = struct {
        mutex: Io.Mutex = .init,
        counter: u32 = 0,
    };

    const Worker = struct {
        fn bump(io: Io, s: *State) !void {
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                try s.mutex.lock(io);
                s.counter += 1;
                s.mutex.unlock(io);
            }
        }

        fn run(io: Io) !void {
            var s: State = .{};
            var group: Io.Group = .init;
            group.async(io, bump, .{ io, &s });
            group.async(io, bump, .{ io, &s });
            group.async(io, bump, .{ io, &s });
            try group.await(io);
            try std.testing.expectEqual(@as(u32, 300), s.counter);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: Io.Condition wakes waiter after signal" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const State = struct {
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        ready: bool = false,
    };

    const Worker = struct {
        fn producer(io: Io, s: *State) !void {
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            s.ready = true;
            s.cond.signal(io);
        }

        fn consumer(io: Io, s: *State, observed: *bool) !void {
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            while (!s.ready) try s.cond.wait(io, &s.mutex);
            observed.* = true;
        }

        fn run(io: Io) !void {
            var s: State = .{};
            var observed = false;
            var group: Io.Group = .init;
            group.async(io, consumer, .{ io, &s, &observed });
            group.async(io, producer, .{ io, &s });
            try group.await(io);
            try std.testing.expect(observed);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: Io.Semaphore limits concurrent workers" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Shared = struct {
        sem: Io.Semaphore = .{ .permits = 2 },
        active: std.atomic.Value(u32) = .init(0),
        peak: std.atomic.Value(u32) = .init(0),
    };

    const Worker = struct {
        fn work(io: Io, shared: *Shared) !void {
            try shared.sem.wait(io);
            defer shared.sem.post(io);

            const current = shared.active.fetchAdd(1, .acq_rel) + 1;
            // Track peak concurrency.
            var peak = shared.peak.load(.monotonic);
            while (current > peak) {
                peak = shared.peak.cmpxchgWeak(peak, current, .acq_rel, .monotonic) orelse break;
            }
            _ = shared.active.fetchSub(1, .acq_rel);
        }

        fn run(io: Io) !void {
            var shared: Shared = .{};
            var group: Io.Group = .init;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                group.async(io, work, .{ io, &shared });
            }
            try group.await(io);
            try std.testing.expect(shared.peak.load(.acquire) <= 2);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: processExecutablePath returns a non-empty path" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &buf);
    try std.testing.expect(len > 0);
}

test "io: now returns monotonically increasing awake timestamps" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const a = Io.Timestamp.now(io, .awake);
    try io.sleep(.fromMilliseconds(5), .awake);
    const b = Io.Timestamp.now(io, .awake);
    try std.testing.expect(b.nanoseconds >= a.nanoseconds + 5 * std.time.ns_per_ms);
}

test "io: clockResolution reports availability per clock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const res_awake = try Io.Clock.resolution(.awake, io);
    try std.testing.expect(res_awake.nanoseconds > 0);

    try std.testing.expectError(error.ClockUnavailable, Io.Clock.resolution(.cpu_process, io));
    try std.testing.expectError(error.ClockUnavailable, Io.Clock.resolution(.cpu_thread, io));
}

test "io: random fills buffer with varying bytes" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var buf: [64]u8 = @splat(0);
    io.random(&buf);
    // Probabilistically asserts we actually filled the buffer.
    var nonzero: usize = 0;
    for (buf) |b| if (b != 0) {
        nonzero += 1;
    };
    try std.testing.expect(nonzero > 32);
}

test "io: randomSecure fills buffer with varying bytes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var buf: [64]u8 = @splat(0);
    try io.randomSecure(&buf);
    var nonzero: usize = 0;
    for (buf) |b| if (b != 0) {
        nonzero += 1;
    };
    try std.testing.expect(nonzero > 32);
}

test "io: sleep with duration returns after delay" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var sw = time.Stopwatch.start();
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expect(sw.read().toMilliseconds() >= 20);
}

test "io: sleep is cancelable" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn sleeper(io: Io, observed: *Io.Cancelable!void) void {
            observed.* = io.sleep(.fromSeconds(60), .awake);
        }

        fn run(io: Io) !void {
            var observed: Io.Cancelable!void = {};
            var future = io.async(sleeper, .{ io, &observed });
            try io.sleep(.fromMilliseconds(10), .awake);
            future.cancel(io);
            try std.testing.expectError(error.Canceled, observed);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: net TCP listen/connect/accept handshake" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn connector(io: Io, address: *const Io.net.IpAddress, result: *Io.net.IpAddress.ConnectError!Io.net.Stream) void {
            result.* = Io.net.IpAddress.connect(address, io, .{ .mode = .stream });
        }

        fn run(io: Io) !void {
            var server = try Io.net.IpAddress.listen(
                &.{ .ip4 = .loopback(0) },
                io,
                .{ .reuse_address = true },
            );
            defer server.deinit(io);

            var connect_result: Io.net.IpAddress.ConnectError!Io.net.Stream = undefined;
            var future = io.async(connector, .{ io, &server.socket.address, &connect_result });
            defer future.cancel(io);

            const accepted = try server.accept(io);
            defer accepted.close(io);

            const client = try connect_result;
            defer client.close(io);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: net TCP read/write/shutdown round-trip" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn echoer(io: Io, server: *Io.net.Server) !void {
            const peer = try server.accept(io);
            defer peer.close(io);

            var recv_buf: [256]u8 = undefined;
            var reader = peer.reader(io, &recv_buf);

            var send_buf: [256]u8 = undefined;
            var writer = peer.writer(io, &send_buf);

            // Echo until EOF.
            while (true) {
                const n = reader.interface.stream(&writer.interface, .limited(64)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                if (n == 0) break;
                try writer.interface.flush();
            }
            try peer.shutdown(io, .send);
        }

        fn run(io: Io) !void {
            var server = try Io.net.IpAddress.listen(
                &.{ .ip4 = .loopback(0) },
                io,
                .{ .reuse_address = true },
            );
            defer server.deinit(io);

            var echo_err: anyerror!void = {};
            var future = io.async(struct {
                fn call(io2: Io, s: *Io.net.Server, out: *anyerror!void) void {
                    out.* = echoer(io2, s);
                }
            }.call, .{ io, &server, &echo_err });

            const client = try Io.net.IpAddress.connect(&server.socket.address, io, .{ .mode = .stream });
            defer client.close(io);

            var send_buf: [64]u8 = undefined;
            var writer = client.writer(io, &send_buf);
            try writer.interface.writeAll("hello ");
            try writer.interface.writeAll("world");
            try writer.interface.flush();
            try client.shutdown(io, .send);

            var recv_buf: [64]u8 = undefined;
            var reader = client.reader(io, &recv_buf);
            var out: [32]u8 = undefined;
            const got = try reader.interface.readSliceShort(&out);
            try std.testing.expectEqualStrings("hello world", out[0..got]);

            future.await(io);
            try echo_err;
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: net Unix listen/connect/accept round-trip" {
    if (!zio_net.has_unix_sockets) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn connector(io: Io, address: *const Io.net.UnixAddress, result: *Io.net.UnixAddress.ConnectError!Io.net.Stream) void {
            result.* = Io.net.UnixAddress.connect(address, io);
        }

        fn run(io: Io) !void {
            const path = "test_io_net_unix.sock";
            (Io.Dir.cwd()).deleteFile(io, path) catch {};
            defer (Io.Dir.cwd()).deleteFile(io, path) catch {};

            const address = try Io.net.UnixAddress.init(path);
            var server = try address.listen(io, .{});
            defer server.deinit(io);

            var connect_result: Io.net.UnixAddress.ConnectError!Io.net.Stream = undefined;
            var future = io.async(connector, .{ io, &address, &connect_result });
            defer future.cancel(io);

            const accepted = try server.accept(io);
            defer accepted.close(io);

            const client = try connect_result;
            defer client.close(io);

            var send_buf: [32]u8 = undefined;
            var writer = client.writer(io, &send_buf);
            try writer.interface.writeAll("ping");
            try writer.interface.flush();
            try client.shutdown(io, .send);

            var recv_buf: [32]u8 = undefined;
            var reader = accepted.reader(io, &recv_buf);
            var out: [8]u8 = undefined;
            const got = try reader.interface.readSliceShort(&out);
            try std.testing.expectEqualStrings("ping", out[0..got]);
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: net UDP bind assigns ephemeral port" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var socket = try Io.net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram });
    defer socket.close(io);

    try std.testing.expect(socket.address.ip4.port != 0);
}

test "io: net createPair for AF_INET fails with OperationUnsupported" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    // socketpair(2) only supports AF_UNIX on Linux/macOS; the std.Io API
    // exposes AF_INET/INET6 via the family option. The kernel rejects it.
    // This test pins down the error path so createPair stays wired correctly.
    try std.testing.expectError(error.OperationUnsupported, Io.net.Socket.createPair(io, .{}));
}

test "io: net UDP send single datagram succeeds" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var sender = try Io.net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram });
    defer sender.close(io);

    var receiver = try Io.net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram });
    defer receiver.close(io);

    try sender.send(io, &receiver.address, "hello");
}

test "io: net UDP sendMany delivers multiple datagrams" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var sender = try Io.net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram });
    defer sender.close(io);

    var receiver = try Io.net.IpAddress.bind(&.{ .ip4 = .loopback(0) }, io, .{ .mode = .dgram });
    defer receiver.close(io);

    const payloads = [_][]const u8{ "one", "two", "three" };
    var messages: [payloads.len]Io.net.OutgoingMessage = undefined;
    for (&messages, payloads) |*m, p| {
        m.* = .{ .address = &receiver.address, .data_ptr = p.ptr, .data_len = p.len };
    }

    try sender.sendMany(io, &messages, .{});

    for (&messages, payloads) |m, p| {
        try std.testing.expectEqual(p.len, m.data_len);
    }
}

test "io: netLookup resolves numeric IPv4" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const host: Io.net.HostName = try .init("127.0.0.1");
    var buf: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    try Io.net.HostName.lookup(host, io, &queue, .{ .port = 8080 });

    var got_address = false;
    while (queue.getOneUncancelable(io)) |entry| switch (entry) {
        .address => |addr| {
            got_address = true;
            try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
            try std.testing.expectEqual(Io.net.IpAddress.Family.ip4, @as(Io.net.IpAddress.Family, addr));
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => {},
    }
    try std.testing.expect(got_address);
}

test "io: netLookup returns canonical name when buffer provided" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    // Use "localhost" rather than a numeric IP: macOS getaddrinfo skips
    // AI_CANONNAME for numeric inputs.
    const host: Io.net.HostName = try .init("localhost");
    var buf: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    var canon_buf: [Io.net.HostName.max_len]u8 = undefined;
    try Io.net.HostName.lookup(host, io, &queue, .{
        .port = 0,
        .canonical_name_buffer = &canon_buf,
    });

    var got_canonical = false;
    while (queue.getOneUncancelable(io)) |entry| switch (entry) {
        .address => {},
        .canonical_name => |name| {
            got_canonical = true;
            try std.testing.expect(name.bytes.len > 0);
        },
    } else |err| switch (err) {
        error.Closed => {},
    }
    try std.testing.expect(got_canonical);
}

test "io: file create/open/close" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_create_open_close.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var created = try dir.createFile(io, file_path, .{});
    created.close(io);

    var opened = try dir.openFile(io, file_path, .{});
    opened.close(io);
}

test "io: file open returns FileNotFound for missing file" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    try std.testing.expectError(
        error.FileNotFound,
        dir.openFile(io, "definitely-not-a-real-file-xyz123.txt", .{}),
    );
}

test "io: file positional read/write round-trip" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_positional_rw.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    try std.testing.expectEqual(5, try file.writePositional(io, &.{"HELLO"}, 0));
    try std.testing.expectEqual(5, try file.writePositional(io, &.{"WORLD"}, 10));

    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(5, try file.readPositional(io, &.{&buf}, 0));
    try std.testing.expectEqualStrings("HELLO", &buf);
    try std.testing.expectEqual(5, try file.readPositional(io, &.{&buf}, 10));
    try std.testing.expectEqualStrings("WORLD", &buf);
}

test "io: file streaming read advances position and reports EOF" {
    // On Windows, zio opens files with FILE_FLAG_OVERLAPPED (for IOCP). Such
    // handles have no implicit file position, so ReadFile/WriteFile without an
    // OVERLAPPED struct fails with INVALID_PARAMETER. Streaming requires
    // per-handle position tracking which we don't implement.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_read_streaming.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    try std.testing.expectEqual(10, try file.writePositional(io, &.{"HELLOWORLD"}, 0));

    var buf1: [5]u8 = undefined;
    try std.testing.expectEqual(5, try file.readStreaming(io, &.{&buf1}));
    try std.testing.expectEqualStrings("HELLO", &buf1);

    var buf2: [5]u8 = undefined;
    try std.testing.expectEqual(5, try file.readStreaming(io, &.{&buf2}));
    try std.testing.expectEqualStrings("WORLD", &buf2);

    var buf3: [5]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, file.readStreaming(io, &.{&buf3}));
}

test "io: file streaming write advances position and appends" {
    // See note on Windows in the streaming-read test above.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_write_streaming.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    try std.testing.expectEqual(5, try file.writeStreaming(io, "HELLO", &.{}, 1));
    try std.testing.expectEqual(6, try file.writeStreaming(io, "", &.{ " ", "WORLD" }, 1));
    try std.testing.expectEqual(3, try file.writeStreaming(io, "", &.{"!"}, 3));

    try std.testing.expectEqual(14, try file.length(io));

    var buf: [14]u8 = undefined;
    try std.testing.expectEqual(14, try file.readPositional(io, &.{&buf}, 0));
    try std.testing.expectEqualStrings("HELLO WORLD!!!", &buf);
}

test "io: file length/sync/setLength" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_length_sync.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    try std.testing.expectEqual(0, try file.length(io));

    _ = try file.writePositional(io, &.{"1234567890"}, 0);
    try std.testing.expectEqual(10, try file.length(io));

    try file.sync(io);

    try file.setLength(io, 4);
    try std.testing.expectEqual(4, try file.length(io));

    try file.setLength(io, 20);
    try std.testing.expectEqual(20, try file.length(io));
}

test "io: file/dir stat and dir statFile" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_stat.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    _ = try file.writePositional(io, &.{"hello"}, 0);

    const file_stat = try file.stat(io);
    try std.testing.expectEqual(Io.File.Kind.file, file_stat.kind);
    try std.testing.expectEqual(@as(u64, 5), file_stat.size);

    const at_stat = try dir.statFile(io, file_path, .{});
    try std.testing.expectEqual(Io.File.Kind.file, at_stat.kind);
    try std.testing.expectEqual(@as(u64, 5), at_stat.size);
    try std.testing.expectEqual(file_stat.inode, at_stat.inode);

    const dir_path = "test_io_stat_dir";
    try dir.createDir(io, dir_path, .default_dir);
    defer dir.deleteDir(io, dir_path) catch {};
    var sub_dir = try dir.openDir(io, dir_path, .{});
    defer sub_dir.close(io);
    const dir_stat = try sub_dir.stat(io);
    try std.testing.expectEqual(Io.File.Kind.directory, dir_stat.kind);
}

test "io: dir symLink and readLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const target = "test_io_symlink_target.txt";
    const link = "test_io_symlink_link";
    defer dir.deleteFile(io, target) catch {};
    defer dir.deleteFile(io, link) catch {};

    var file = try dir.createFile(io, target, .{});
    file.close(io);

    try dir.symLink(io, target, link, .{});

    var buffer: [256]u8 = undefined;
    const n = try dir.readLink(io, link, &buffer);
    try std.testing.expectEqualStrings(target, buffer[0..n]);
}

test "io: dir statFile follow_symlinks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const target = "test_io_stat_symlink_target.txt";
    const link = "test_io_stat_symlink_link";
    defer dir.deleteFile(io, target) catch {};
    defer dir.deleteFile(io, link) catch {};

    var file = try dir.createFile(io, target, .{});
    file.close(io);

    try dir.symLink(io, target, link, .{});

    const followed = try dir.statFile(io, link, .{ .follow_symlinks = true });
    try std.testing.expectEqual(Io.File.Kind.file, followed.kind);

    const not_followed = try dir.statFile(io, link, .{ .follow_symlinks = false });
    try std.testing.expectEqual(Io.File.Kind.sym_link, not_followed.kind);
}

test "io: dir hardLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const original = "test_io_hardlink_original.txt";
    const link = "test_io_hardlink_link.txt";
    defer dir.deleteFile(io, original) catch {};
    defer dir.deleteFile(io, link) catch {};

    var file = try dir.createFile(io, original, .{});
    _ = try file.writePositional(io, &.{"linked"}, 0);
    file.close(io);

    try Io.Dir.hardLink(dir, original, dir, link, io, .{});

    var opened = try dir.openFile(io, link, .{});
    defer opened.close(io);
    var buf: [16]u8 = undefined;
    const n = try opened.readPositional(io, &.{&buf}, 0);
    try std.testing.expectEqualStrings("linked", buf[0..n]);
}

test "io: dir access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_access.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    file.close(io);

    try dir.access(io, file_path, .{ .read = true });
    try dir.access(io, file_path, .{ .write = true });
    try std.testing.expectError(error.FileNotFound, dir.access(io, "nonexistent_io_access_xyz.txt", .{ .read = true }));
}

test "io: dir rename" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const old_path = "test_io_rename_old.txt";
    const new_path = "test_io_rename_new.txt";
    defer dir.deleteFile(io, old_path) catch {};
    defer dir.deleteFile(io, new_path) catch {};

    var file = try dir.createFile(io, old_path, .{});
    file.close(io);

    try dir.rename(old_path, dir, new_path, io);
    try std.testing.expectError(error.FileNotFound, dir.openFile(io, old_path, .{}));
    var moved = try dir.openFile(io, new_path, .{});
    moved.close(io);

    try std.testing.expectError(error.FileNotFound, dir.rename(old_path, dir, new_path, io));
}

test "io: dir create/delete" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dir_path = "test_io_dir_create_delete";
    defer dir.deleteDir(io, dir_path) catch {};

    try dir.createDir(io, dir_path, .default_dir);
    try std.testing.expectError(error.PathAlreadyExists, dir.createDir(io, dir_path, .default_dir));
    try dir.deleteDir(io, dir_path);
    try std.testing.expectError(error.FileNotFound, dir.deleteDir(io, dir_path));
}

test "io: dir createDirPath creates nested directories" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const sep = Io.Dir.path.sep_str;
    const nested_path = "test_io_createDirPath" ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c";
    const base_path = "test_io_createDirPath";

    // Clean up from previous failed runs.
    dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
    dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a" ++ sep ++ "b") catch {};
    dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a") catch {};
    dir.deleteDir(io, base_path) catch {};

    defer {
        dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a" ++ sep ++ "b" ++ sep ++ "c") catch {};
        dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a" ++ sep ++ "b") catch {};
        dir.deleteDir(io, "test_io_createDirPath" ++ sep ++ "a") catch {};
        dir.deleteDir(io, base_path) catch {};
    }

    // Create nested path from scratch.
    const status = try dir.createDirPathStatus(io, nested_path, .default_dir);
    try std.testing.expectEqual(Io.Dir.CreatePathStatus.created, status);

    // Verify it exists.
    var sub = try dir.openDir(io, nested_path, .{});
    sub.close(io);

    // Creating again should return .existed.
    const status2 = try dir.createDirPathStatus(io, nested_path, .default_dir);
    try std.testing.expectEqual(Io.Dir.CreatePathStatus.existed, status2);
}

test "io: dir createDirPathOpen creates and opens" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const sep = Io.Dir.path.sep_str;
    const nested_path = "test_io_createDirPathOpen" ++ sep ++ "x" ++ sep ++ "y";
    const base_path = "test_io_createDirPathOpen";

    // Clean up from previous failed runs.
    dir.deleteDir(io, "test_io_createDirPathOpen" ++ sep ++ "x" ++ sep ++ "y") catch {};
    dir.deleteDir(io, "test_io_createDirPathOpen" ++ sep ++ "x") catch {};
    dir.deleteDir(io, base_path) catch {};

    defer {
        dir.deleteDir(io, "test_io_createDirPathOpen" ++ sep ++ "x" ++ sep ++ "y") catch {};
        dir.deleteDir(io, "test_io_createDirPathOpen" ++ sep ++ "x") catch {};
        dir.deleteDir(io, base_path) catch {};
    }

    // Create and open nested path.
    var sub = try dir.createDirPathOpen(io, nested_path, .{});
    sub.close(io);

    // Should be able to open it again.
    var sub2 = try dir.openDir(io, nested_path, .{});
    sub2.close(io);
}

test "io: dir iterate over files" {
    // NetBSD's getdirentries can return dirents with either 32-bit or
    // 64-bit d_fileno depending on the filesystem, shifting all field
    // offsets. Skip until we implement auto-detection.
    if (builtin.os.tag == .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dir_path = "test_io_dir_iterate";
    // Clean up from previous failed runs.
    dir.deleteDir(io, dir_path) catch {};

    try dir.createDir(io, dir_path, .default_dir);
    errdefer dir.deleteDir(io, dir_path) catch {};

    // Create a few files in the directory.
    {
        var sub = try dir.openDir(io, dir_path, .{ .iterate = true });
        defer sub.close(io);

        const file_names = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
        for (file_names) |name| {
            var f = try sub.createFile(io, name, .{});
            f.close(io);
        }
        defer for (file_names) |name| sub.deleteFile(io, name) catch {};

        var it = sub.iterate();
        var found: usize = 0;
        var all_entries: [64]Io.Dir.Entry = undefined;
        while (try it.next(io)) |entry| {
            if (found >= all_entries.len) break;
            all_entries[found] = entry;
            found += 1;
        }
        try std.testing.expectEqual(3, found);
        for (all_entries[0..found]) |entry| {
            try std.testing.expect(entry.kind == .file);
            try std.testing.expect(std.mem.eql(u8, entry.name, "a.txt") or
                std.mem.eql(u8, entry.name, "b.txt") or
                std.mem.eql(u8, entry.name, "c.txt"));
        }
    }
    // sub's deferred cleanup (file deletion + close) has now run.
    try dir.deleteDir(io, dir_path);
}

test "io: dir iterate empty directory" {
    // See comment on dir iterate over files above.
    if (builtin.os.tag == .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dir_path = "test_io_dir_iterate_empty";
    defer dir.deleteDir(io, dir_path) catch {};

    try dir.createDir(io, dir_path, .default_dir);

    var sub = try dir.openDir(io, dir_path, .{ .iterate = true });
    defer sub.close(io);

    var it = sub.iterate();
    var found2: usize = 0;
    var all_entries2: [64]Io.Dir.Entry = undefined;
    while (try it.next(io)) |entry| {
        if (found2 >= all_entries2.len) break;
        all_entries2[found2] = entry;
        found2 += 1;
    }
    try std.testing.expectEqual(0, found2);
}

test "io: file setPermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_set_permissions.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    defer file.close(io);

    try file.setPermissions(io, .fromMode(0o444));
    try file.setPermissions(io, .fromMode(0o644));
}

test "io: file setOwner accepts null uid/gid as no-op" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_set_owner.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    defer file.close(io);

    try file.setOwner(io, null, null);
}

test "io: file setTimestamps round-trip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_set_timestamps.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    defer file.close(io);

    const atime: i96 = 1_700_000_000 * std.time.ns_per_s;
    const mtime: i96 = 1_700_000_123 * std.time.ns_per_s;
    try file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = atime } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime } },
    });

    try file.setTimestampsNow(io);
}

test "io: dir setFilePermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_dir_set_file_permissions.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    file.close(io);

    try dir.setFilePermissions(io, file_path, .fromMode(0o444), .{});
    try dir.setFilePermissions(io, file_path, .fromMode(0o644), .{});
}

test "io: dir setTimestamps round-trip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_dir_set_timestamps.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    file.close(io);

    const atime: i96 = 1_700_000_000 * std.time.ns_per_s;
    const mtime: i96 = 1_700_000_123 * std.time.ns_per_s;
    try dir.setTimestamps(io, file_path, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = atime } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime } },
    });

    try dir.setTimestamps(io, file_path, .{
        .access_timestamp = .now,
        .modify_timestamp = .now,
    });
}

test "io: dir realPath and realPathFile" {
    if (builtin.os.tag == .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_dir_realpath.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    file.close(io);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try dir.realPath(io, &cwd_buf);
    try std.testing.expect(cwd_len > 0);

    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_len = try dir.realPathFile(io, file_path, &file_buf);
    try std.testing.expect(file_len > cwd_len);
    try std.testing.expectEqualStrings(cwd_buf[0..cwd_len], file_buf[0..cwd_len]);
    try std.testing.expect(std.mem.endsWith(u8, file_buf[0..file_len], file_path));
}

test "io: file realPath" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_file_realpath.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{});
    defer file.close(io);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = file.realPath(io, &buf) catch |err| switch (err) {
        error.OperationUnsupported => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(std.mem.endsWith(u8, buf[0..len], file_path));
}

test "io: file hardLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const original = "test_io_file_hardlink_original.txt";
    const link = "test_io_file_hardlink_link.txt";
    defer dir.deleteFile(io, original) catch {};
    defer dir.deleteFile(io, link) catch {};

    var file = try dir.createFile(io, original, .{});
    defer file.close(io);
    _ = try file.writePositional(io, &.{"linked"}, 0);

    try file.hardLink(io, dir, link, .{});

    var opened = try dir.openFile(io, link, .{});
    defer opened.close(io);
    var buf: [16]u8 = undefined;
    const n = try opened.readPositional(io, &.{&buf}, 0);
    try std.testing.expectEqualStrings("linked", buf[0..n]);
}

test "io: group runs spawned tasks to completion" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Worker = struct {
        fn bump(counter: *std.atomic.Value(u32)) void {
            _ = counter.fetchAdd(1, .acq_rel);
        }

        fn run(io: Io) !void {
            var counter: std.atomic.Value(u32) = .init(0);
            var group: Io.Group = .init;
            group.async(io, bump, .{&counter});
            group.async(io, bump, .{&counter});
            group.async(io, bump, .{&counter});
            try group.await(io);
            try std.testing.expectEqual(@as(u32, 3), counter.load(.acquire));
        }
    };

    var handle = try rt.spawn(Worker.run, .{rt.io()});
    try handle.join();
}

test "io: batch awaitAsync executes operations linearly" {
    // file_read_streaming uses iovec which doesn't work on Windows regular files
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const file_path = "test_io_batch.txt";
    defer dir.deleteFile(io, file_path) catch {};

    var file = try dir.createFile(io, file_path, .{ .read = true });
    defer file.close(io);

    // Write some data
    const data = "hello batch";
    _ = try file.writePositional(io, &.{data}, 0);

    // Use batch to read it back
    var read_buf: [32]u8 = undefined;
    var storage: [1]Io.Operation.Storage = undefined;
    var batch = Io.Batch.init(&storage);
    _ = batch.add(.{ .file_read_streaming = .{ .file = file, .data = &.{&read_buf} } });

    try batch.awaitAsync(io);

    const completion = batch.next().?;
    try std.testing.expectEqual(@as(u32, 0), completion.index);
    const n = try completion.result.file_read_streaming;
    try std.testing.expectEqualStrings(data, read_buf[0..n]);
}

test "io: batch awaitConcurrent returns ConcurrencyUnavailable" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var storage: [1]Io.Operation.Storage = undefined;
    var batch = Io.Batch.init(&storage);

    const err = batch.awaitConcurrent(io, .{ .none = {} });
    try std.testing.expectError(error.ConcurrencyUnavailable, err);
}

test "io: createFileAtomic link" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dest_path = "test_io_atomic_file.txt";
    defer dir.deleteFile(io, dest_path) catch {};

    var af = try dir.createFileAtomic(io, dest_path, .{});
    defer af.deinit(io);

    _ = try af.file.writePositional(io, &.{"hello atomic"}, 0);

    try af.link(io);

    const content = try dir.readFileAlloc(io, dest_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello atomic", content);
}

test "io: createFileAtomic replace" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dest_path = "test_io_atomic_replace.txt";
    defer dir.deleteFile(io, dest_path) catch {};

    // Create initial file.
    var f = try dir.createFile(io, dest_path, .{});
    _ = try f.writePositional(io, &.{"original"}, 0);
    f.close(io);

    // Replace atomically.
    var af = try dir.createFileAtomic(io, dest_path, .{ .replace = true });
    defer af.deinit(io);

    _ = try af.file.writePositional(io, &.{"replaced"}, 0);

    try af.replace(io);

    const content = try dir.readFileAlloc(io, dest_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("replaced", content);
}

test "io: createFileAtomic with make_path" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    const dir: Io.Dir = .cwd();
    const dest_path = "test_io_atomic_nested/subdir/file.txt";
    defer {
        dir.deleteFile(io, dest_path) catch {};
        dir.deleteDir(io, "test_io_atomic_nested/subdir") catch {};
        dir.deleteDir(io, "test_io_atomic_nested") catch {};
    }

    // Clean up from previous runs.
    dir.deleteFile(io, dest_path) catch {};
    dir.deleteDir(io, "test_io_atomic_nested/subdir") catch {};
    dir.deleteDir(io, "test_io_atomic_nested") catch {};

    var af = try dir.createFileAtomic(io, dest_path, .{ .make_path = true });
    defer af.deinit(io);

    _ = try af.file.writePositional(io, &.{"nested atomic"}, 0);

    try af.link(io);

    const content = try dir.readFileAlloc(io, dest_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("nested atomic", content);
}
