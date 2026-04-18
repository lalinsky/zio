// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Implementation of the `std.Io` interface backed by zio's runtime.
//!
//! Every vtable method is currently stubbed with `@panic("TODO: ...")`. They
//! will be filled in incrementally; the goal of this initial skeleton is to
//! get the wiring right so callers can already obtain a `std.Io` from a
//! `*Runtime` via `Runtime.io()`.

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
const waitForIoUncancelable = common.waitForIoUncancelable;

const ev = @import("ev/root.zig");
const os_net = @import("os/net.zig");
const os_fs = @import("os/fs.zig");
const zio_net = @import("net.zig");
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
    .fileWriteFileStreaming = fileWriteFileStreamingImpl,
    .fileWriteFilePositional = fileWriteFilePositionalImpl,
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

fn operateImpl(_: ?*anyopaque, _: Io.Operation) Io.Cancelable!Io.Operation.Result {
    @panic("TODO: operate");
}

fn batchAwaitAsyncImpl(_: ?*anyopaque, _: *Io.Batch) Io.Cancelable!void {
    @panic("TODO: batchAwaitAsync");
}

fn batchAwaitConcurrentImpl(_: ?*anyopaque, _: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
    @panic("TODO: batchAwaitConcurrent");
}

fn batchCancelImpl(_: ?*anyopaque, _: *Io.Batch) void {
    @panic("TODO: batchCancel");
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

fn dirCreateDirPathImpl(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    @panic("TODO: dirCreateDirPath");
}

fn dirCreateDirPathOpenImpl(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions, _: Io.Dir.OpenOptions) Io.Dir.CreateDirPathOpenError!Io.Dir {
    @panic("TODO: dirCreateDirPathOpen");
}

fn dirOpenDirImpl(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    @panic("TODO: dirOpenDir");
}

fn dirStatImpl(_: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    // Use fstatat(handle, ".") so this works for Io.Dir.cwd() too — fstat()
    // does not accept AT_FDCWD.
    var op = ev.FileStat.init(stdIoHandleToZio(dir.handle), ".", .{});
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

/// Map zio's file-open errno set onto std.Io.File.OpenError.
///
/// The extra options std.Io surfaces (lock, path_only, allow_directory, ...)
/// are ignored for now — zio's FileOpenFlags don't model them yet. Callers
/// that rely on the defaults get the expected behavior; callers that flip the
/// knobs silently get best-effort results.
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

fn dirCreateFileAtomicImpl(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
    @panic("TODO: dirCreateFileAtomic");
}

fn dirOpenFileImpl(_: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, options: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    var op = ev.FileOpen.init(stdIoHandleToZio(dir.handle), sub_path, .{
        .mode = stdIoModeToZio(options.mode),
    });
    try waitForIo(&op.c);
    const fd = op.getResult() catch |err| return openErrToFileErr(err);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dirCloseImpl(_: ?*anyopaque, _: []const Io.Dir) void {
    @panic("TODO: dirClose");
}

fn dirReadImpl(_: ?*anyopaque, _: *Io.Dir.Reader, _: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    @panic("TODO: dirRead");
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

fn dirRenamePreserveImpl(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir, _: []const u8) Io.Dir.RenamePreserveError!void {
    @panic("TODO: dirRenamePreserve");
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

fn fileWriteFileStreamingImpl(_: ?*anyopaque, _: Io.File, _: []const u8, _: *Io.File.Reader, _: Io.Limit) Io.File.Writer.WriteFileError!usize {
    @panic("TODO: fileWriteFileStreaming");
}

fn fileWriteFilePositionalImpl(_: ?*anyopaque, _: Io.File, _: []const u8, _: *Io.File.Reader, _: Io.Limit, _: u64) Io.File.WriteFilePositionalError!usize {
    @panic("TODO: fileWriteFilePositional");
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

fn fileLockImpl(_: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!void {
    @panic("TODO: fileLock");
}

fn fileTryLockImpl(_: ?*anyopaque, _: Io.File, _: Io.File.Lock) Io.File.LockError!bool {
    @panic("TODO: fileTryLock");
}

fn fileUnlockImpl(_: ?*anyopaque, _: Io.File) void {
    @panic("TODO: fileUnlock");
}

fn fileDowngradeLockImpl(_: ?*anyopaque, _: Io.File) Io.File.DowngradeLockError!void {
    @panic("TODO: fileDowngradeLock");
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
    @panic("TODO: fileMemoryMapCreate");
}

fn fileMemoryMapDestroyImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) void {
    @panic("TODO: fileMemoryMapDestroy");
}

fn fileMemoryMapSetLengthImpl(_: ?*anyopaque, _: *Io.File.MemoryMap, _: usize) Io.File.MemoryMap.SetLengthError!void {
    @panic("TODO: fileMemoryMapSetLength");
}

fn fileMemoryMapReadImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.ReadPositionalError!void {
    @panic("TODO: fileMemoryMapRead");
}

fn fileMemoryMapWriteImpl(_: ?*anyopaque, _: *Io.File.MemoryMap) Io.File.WritePositionalError!void {
    @panic("TODO: fileMemoryMapWrite");
}

fn processExecutableOpenImpl(_: ?*anyopaque, _: Io.Dir.OpenFileOptions) std.process.OpenExecutableError!Io.File {
    @panic("TODO: processExecutableOpen");
}

fn processExecutablePathImpl(_: ?*anyopaque, buffer: []u8) std.process.ExecutablePathError!usize {
    const io = globalIo();
    return io.vtable.processExecutablePath(io.userdata, buffer);
}

fn lockStderrImpl(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    @panic("TODO: lockStderr");
}

fn tryLockStderrImpl(_: ?*anyopaque, _: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    @panic("TODO: tryLockStderr");
}

fn unlockStderrImpl(_: ?*anyopaque) void {
    @panic("TODO: unlockStderr");
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

fn processReplaceImpl(_: ?*anyopaque, _: std.process.ReplaceOptions) std.process.ReplaceError {
    @panic("TODO: processReplace");
}

fn processReplacePathImpl(_: ?*anyopaque, _: Io.Dir, _: std.process.ReplaceOptions) std.process.ReplaceError {
    @panic("TODO: processReplacePath");
}

fn processSpawnImpl(_: ?*anyopaque, _: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    @panic("TODO: processSpawn");
}

fn processSpawnPathImpl(_: ?*anyopaque, _: Io.Dir, _: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    @panic("TODO: processSpawnPath");
}

fn childWaitImpl(_: ?*anyopaque, _: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    @panic("TODO: childWait");
}

fn childKillImpl(_: ?*anyopaque, _: *std.process.Child) void {
    @panic("TODO: childKill");
}

fn progressParentFileImpl(_: ?*anyopaque) std.Progress.ParentFileError!Io.File {
    @panic("TODO: progressParentFile");
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
    const domain = os_net.Domain.fromPosix(zio_addr.any.family);

    var open_op = ev.NetOpen.init(domain, .stream, .ip, .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToListenErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    if (options.reuse_address) {
        const value: c_int = 1;
        os_net.setsockopt(handle, os_net.SOL.SOCKET, os_net.SO.REUSEADDR, std.mem.asBytes(&value)) catch {};
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
    const domain = os_net.Domain.fromPosix(zio_addr.any.family);
    const sock_type: os_net.Type = switch (options.mode) {
        .stream => .stream,
        .dgram => .dgram,
        .seqpacket => .seqpacket,
        .raw => .raw,
        .rdm => return error.SocketModeUnsupported,
    };
    // When the caller leaves protocol unset, pass IPPROTO_IP (== 0) so the
    // kernel chooses the default protocol for the requested socket type.
    const protocol: os_net.Protocol = if (options.protocol) |p|
        @enumFromInt(@intFromEnum(p))
    else
        .ip;

    var open_op = ev.NetOpen.init(domain, sock_type, protocol, .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToBindErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    if (options.ip6_only) {
        if (domain != .ipv6) return error.OptionUnsupported;
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

fn netConnectIpImpl(_: ?*anyopaque, address: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const zio_addr = stdIoIpToZio(address.*);
    const domain = os_net.Domain.fromPosix(zio_addr.any.family);

    var open_op = ev.NetOpen.init(domain, .stream, .ip, .{});
    try waitForIo(&open_op.c);
    const handle = open_op.getResult() catch |err| return openErrToConnectErr(err);
    errdefer {
        var close_op = ev.NetClose.init(handle);
        waitForIoUncancelable(&close_op.c);
    }

    const addr_len = sockAddrLen(&zio_addr.any);
    var connect_op = ev.NetConnect.init(handle, &zio_addr.any, addr_len);
    try waitForIo(&connect_op.c);
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

fn netSocketCreatePairImpl(_: ?*anyopaque, _: Io.net.Socket.CreatePairOptions) Io.net.Socket.CreatePairError![2]Io.net.Socket {
    @panic("TODO: netSocketCreatePair");
}

fn netSendImpl(_: ?*anyopaque, _: Io.net.Socket.Handle, _: []Io.net.OutgoingMessage, _: Io.net.SendFlags) struct { ?Io.net.Socket.SendError, usize } {
    @panic("TODO: netSend");
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
        error.Unexpected,
        => error.Unexpected,
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
    @panic("TODO: netWriteFile");
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

fn netLookupImpl(_: ?*anyopaque, _: Io.net.HostName, _: *Io.Queue(Io.net.HostName.LookupResult), _: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    @panic("TODO: netLookup");
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

    const dir_stat = try dir.stat(io);
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
