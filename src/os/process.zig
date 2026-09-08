const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w = @import("windows.zig");
const fs = @import("fs.zig");

const unexpectedError = @import("base.zig").unexpectedError;
const syscall_cancel = @import("syscall_cancel.zig");

// zio always links libc (see build.zig), so unlike std.Io.Threaded the spawn
// path below can lean on libc uniformly instead of carrying raw-syscall and
// no-libc fallbacks. libc is not exposed for `fork`, so declare it here.
const c = std.c;
extern "c" fn fork() c.pid_t;

fn cErrno() c.E {
    return @enumFromInt(c._errno().*);
}

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

// ---------------------------------------------------------------------------
// Process spawning and replacement (POSIX)
//
// A native fork/exec, replacing the throwaway std.Io.Threaded instance io.zig
// used to stand up just to spawn a child. The classic protocol: a CLOEXEC
// "error pipe" the child writes an errno into if anything between fork and exec
// fails; the parent learns exec succeeded when that pipe reports EOF instead.
//
// Everything the child runs between fork and exec must be async-signal-safe, so
// all allocation (argv/env null-termination, the cwd path, /dev/null) happens in
// the parent before the fork, and the child only makes bare libc calls.
// ---------------------------------------------------------------------------

const SearchPath = "/usr/local/bin:/bin/:/usr/bin";

// A child reports a spawn failure by writing @intFromError across the error
// pipe; sized to hold any anyerror value.
const ErrInt = std.meta.Int(.unsigned, @sizeOf(anyerror) * 8);

const STDIN_FILENO = 0;
const STDOUT_FILENO = 1;
const STDERR_FILENO = 2;

/// Raw file descriptors handed back to the caller, who wraps them into a
/// `std.process.Child`. A null field means that stream was not a pipe.
pub const Spawned = struct {
    id: c.pid_t,
    stdin: ?posix.fd_t,
    stdout: ?posix.fd_t,
    stderr: ?posix.fd_t,
};

/// Fork and exec a child process. `parent_environ` supplies both the child's
/// environment (when `options.environ_map` is null) and the PATH used to resolve
/// `argv[0]`, which per `SpawnOptions` always comes from the parent.
pub fn spawn(
    allocator: std.mem.Allocator,
    options: std.process.SpawnOptions,
    parent_environ: std.process.Environ,
) std.process.SpawnError!Spawned {
    // Pipes start CLOEXEC so a racing spawn on another thread cannot leak an end
    // into a different child; the child restores the ends it needs by dup2-ing
    // them onto 0/1/2, which clears CLOEXEC on the copy.
    var stdin_pipe: ?[2]posix.fd_t = null;
    var stdout_pipe: ?[2]posix.fd_t = null;
    var stderr_pipe: ?[2]posix.fd_t = null;
    errdefer {
        if (stdin_pipe) |p| closePipe(p);
        if (stdout_pipe) |p| closePipe(p);
        if (stderr_pipe) |p| closePipe(p);
    }
    if (options.stdin == .pipe) stdin_pipe = try makePipe();
    if (options.stdout == .pipe) stdout_pipe = try makePipe();
    if (options.stderr == .pipe) stderr_pipe = try makePipe();

    const any_ignore = options.stdin == .ignore or options.stdout == .ignore or options.stderr == .ignore;
    var dev_null_fd: posix.fd_t = -1;
    defer if (dev_null_fd != -1) posix.close(dev_null_fd);
    if (any_ignore) dev_null_fd = try openDevNull(allocator);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // POSIX forbids allocation between fork and exec (it can deadlock a libc
    // heap), so everything the child needs is prepared here first.
    const argv_buf = try makeArgv(arena, options.argv);
    const env_block = try makeEnvBlock(arena, options, parent_environ);
    const search_path = if (parent_environ.getPosix("PATH")) |p| p else SearchPath;
    const cwd_path_z: ?[*:0]const u8 = switch (options.cwd) {
        .path => |p| (try arena.dupeZ(u8, p)).ptr,
        else => null,
    };

    const err_pipe = try makePipe();
    var err_pipe_open = true;
    errdefer if (err_pipe_open) closePipe(err_pipe);

    const pid = fork();
    if (pid < 0) return switch (cErrno()) {
        .AGAIN, .NOMEM => error.SystemResources,
        .NOSYS => error.OperationUnsupported,
        else => |e| unexpectedError(e),
    };

    if (pid == 0) childRun(
        options,
        if (stdin_pipe) |p| p[0] else -1,
        if (stdout_pipe) |p| p[1] else -1,
        if (stderr_pipe) |p| p[1] else -1,
        dev_null_fd,
        err_pipe[1],
        argv_buf,
        env_block,
        search_path,
        cwd_path_z,
    );

    // ---- Parent. ----
    // Only the child should hold the write end of the error pipe open; once we
    // close ours, EOF on the read end means the child reached exec.
    posix.close(err_pipe[1]);
    if (stdin_pipe) |p| posix.close(p[0]);
    if (stdout_pipe) |p| posix.close(p[1]);
    if (stderr_pipe) |p| posix.close(p[1]);

    // Blocks until the child execs (EOF) or reports an errno. TODO: drive this
    // read through the event loop so the calling worker is not parked on exec.
    const spawn_err = readErrInt(err_pipe[0]);
    posix.close(err_pipe[0]);
    err_pipe_open = false;

    if (spawn_err) |errno_int| {
        // The child wrote an error and _exit()'d; reap it so it does not linger
        // as a zombie (zio has no global SIGCHLD reaper), then close our pipe
        // ends and surface the failure. Null the trackers so the errdefer above
        // does not double-close.
        reap(pid);
        if (stdin_pipe) |p| posix.close(p[1]);
        if (stdout_pipe) |p| posix.close(p[0]);
        if (stderr_pipe) |p| posix.close(p[0]);
        stdin_pipe = null;
        stdout_pipe = null;
        stderr_pipe = null;
        return @errorCast(@errorFromInt(errno_int));
    }

    return .{
        .id = pid,
        .stdin = if (stdin_pipe) |p| p[1] else null,
        .stdout = if (stdout_pipe) |p| p[0] else null,
        .stderr = if (stderr_pipe) |p| p[0] else null,
    };
}

/// Replace the current process image, exec-style. Returns only on failure. PATH
/// (for a bare `argv[0]`) comes from `parent_environ`, matching `spawn`.
pub fn replace(
    allocator: std.mem.Allocator,
    options: std.process.ReplaceOptions,
    parent_environ: std.process.Environ,
) std.process.ReplaceError {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv_buf = makeArgv(arena, options.argv) catch |e| return e;
    const env_block = if (options.environ_map) |map|
        map.createPosixBlock(arena, .{}) catch |e| return e
    else
        parent_environ.createPosixBlock(arena, .{}) catch |e| return e;
    const search_path = if (parent_environ.getPosix("PATH")) |p| p else SearchPath;

    return exec(options.expand_arg0 == .expand, argv_buf, env_block.slice.ptr, search_path);
}

// --- Parent-side helpers ---

fn makeArgv(
    arena: std.mem.Allocator,
    argv: []const []const u8,
) error{OutOfMemory}![*:null]?[*:0]const u8 {
    const buf = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| buf[i] = (try arena.dupeZ(u8, arg)).ptr;
    return buf.ptr;
}

fn makeEnvBlock(
    arena: std.mem.Allocator,
    options: std.process.SpawnOptions,
    parent_environ: std.process.Environ,
) error{OutOfMemory}!std.process.Environ.PosixBlock {
    // Scrub ZIG_PROGRESS from the child (zig_progress_fd = -1): grafting a
    // child's progress tree through a side pipe is not implemented here yet, so
    // an inherited fd would point at nothing useful.
    return if (options.environ_map) |map|
        map.createPosixBlock(arena, .{ .zig_progress_fd = -1 })
    else
        parent_environ.createPosixBlock(arena, .{ .zig_progress_fd = -1 });
}

fn makePipe() std.process.SpawnError![2]posix.fd_t {
    return posix.pipe(.{ .cloexec = true }) catch |e| switch (e) {
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.Unexpected => error.Unexpected,
    };
}

fn closePipe(p: [2]posix.fd_t) void {
    posix.close(p[0]);
    posix.close(p[1]);
}

fn openDevNull(allocator: std.mem.Allocator) std.process.SpawnError!posix.fd_t {
    return fs.openat(allocator, fs.cwd(), "/dev/null", .{ .mode = .read_write }) catch |e| switch (e) {
        error.AccessDenied => error.AccessDenied,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.Canceled => error.Canceled,
        else => error.NoDevice,
    };
}

fn readErrInt(fd: posix.fd_t) ?ErrInt {
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) {
        const rc = c.read(fd, buf[i..].ptr, buf.len - i);
        if (rc < 0) {
            if (cErrno() == .INTR) continue;
            // We cannot tell if the child is alive; assume it is so its
            // resources are not wrongly reclaimed. Treated as exec success.
            return null;
        }
        if (rc == 0) break; // Write end closed by CLOEXEC at exec: success.
        i += @intCast(rc);
    }
    if (i < buf.len) return null; // EOF before a full int also means success.
    return @intCast(std.mem.readInt(u64, &buf, .little));
}

fn reap(pid: c.pid_t) void {
    var status: c_int = undefined;
    while (true) {
        if (c.waitpid(pid, &status, 0) != -1) return;
        if (cErrno() != .INTR) return;
    }
}

// --- Child-side (post-fork, pre-exec): bare libc calls only ---

fn childRun(
    options: std.process.SpawnOptions,
    stdin_end: posix.fd_t,
    stdout_end: posix.fd_t,
    stderr_end: posix.fd_t,
    dev_null_fd: posix.fd_t,
    err_fd: posix.fd_t,
    argv: [*:null]?[*:0]const u8,
    env_block: std.process.Environ.PosixBlock,
    search_path: []const u8,
    cwd_path_z: ?[*:0]const u8,
) noreturn {
    // childSetup only returns on failure; on success it has already exec'd.
    const err = childSetup(options, stdin_end, stdout_end, stderr_end, dev_null_fd, argv, env_block, search_path, cwd_path_z);
    writeErrInt(err_fd, @intFromError(err));
    // _exit rather than exit: skip any libc atexit handlers, which must not run
    // in a fork child (some, e.g. LLVM's, deadlock).
    c._exit(1);
}

fn childSetup(
    options: std.process.SpawnOptions,
    stdin_end: posix.fd_t,
    stdout_end: posix.fd_t,
    stderr_end: posix.fd_t,
    dev_null_fd: posix.fd_t,
    argv: [*:null]?[*:0]const u8,
    env_block: std.process.Environ.PosixBlock,
    search_path: []const u8,
    cwd_path_z: ?[*:0]const u8,
) std.process.SpawnError {
    setUpChildIo(options.stdin, stdin_end, STDIN_FILENO, dev_null_fd) catch |e| return e;
    setUpChildIo(options.stdout, stdout_end, STDOUT_FILENO, dev_null_fd) catch |e| return e;
    setUpChildIo(options.stderr, stderr_end, STDERR_FILENO, dev_null_fd) catch |e| return e;

    switch (options.cwd) {
        .inherit => {},
        .dir => |dir| childCall(c.fchdir(dir.handle)) catch |e| return e,
        .path => childCall(c.chdir(cwd_path_z.?)) catch |e| return e,
    }

    // setregid before setreuid: dropping the user first can remove the privilege
    // needed to change the group.
    if (options.gid) |gid| setIdCall(c.setregid(gid, gid)) catch |e| return e;
    if (options.uid) |uid| setIdCall(c.setreuid(uid, uid)) catch |e| return e;
    if (options.pgid) |pgid| {
        if (c.setpgid(0, pgid) == -1) return switch (cErrno()) {
            .ACCES => error.ProcessAlreadyExec,
            .INVAL => error.InvalidProcessGroupId,
            .PERM => error.PermissionDenied,
            else => |e| unexpectedError(e),
        };
    }
    if (options.start_suspended) childCall(c.kill(0, .STOP)) catch |e| return e;

    return exec(options.expand_arg0 == .expand, argv, env_block.slice.ptr, search_path);
}

fn setUpChildIo(
    stdio: std.process.SpawnOptions.StdIo,
    pipe_end: posix.fd_t,
    target: posix.fd_t,
    dev_null_fd: posix.fd_t,
) std.process.SpawnError!void {
    switch (stdio) {
        .pipe => try childDup2(pipe_end, target),
        .close => posix.close(target),
        .inherit => {},
        .ignore => try childDup2(dev_null_fd, target),
        .file => |file| try childDup2(file.handle, target),
    }
}

fn childDup2(old_fd: posix.fd_t, new_fd: posix.fd_t) std.process.SpawnError!void {
    while (true) {
        if (c.dup2(old_fd, new_fd) != -1) return;
        switch (cErrno()) {
            .INTR, .BUSY => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |e| return unexpectedError(e),
        }
    }
}

/// EINTR-retrying wrapper for the child's plain "succeeds or fails" syscalls
/// (chdir/fchdir/setpgid/kill), mapping the common failures to SpawnError.
fn childCall(rc: c_int) std.process.SpawnError!void {
    if (rc != -1) return;
    return switch (cErrno()) {
        .INTR => error.Unexpected, // none of these callers restart; treat as a bug
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOTDIR => error.NotDir,
        .NOENT => error.FileNotFound,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        else => |e| unexpectedError(e),
    };
}

fn setIdCall(rc: c_int) std.process.SpawnError!void {
    if (rc != -1) return;
    return switch (cErrno()) {
        .AGAIN => error.ResourceLimitReached,
        .INVAL => error.InvalidUserId,
        .PERM => error.PermissionDenied,
        else => |e| unexpectedError(e),
    };
}

fn writeErrInt(fd: posix.fd_t, value: ErrInt) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    var i: usize = 0;
    while (i < buf.len) {
        const rc = c.write(fd, buf[i..].ptr, buf.len - i);
        if (rc < 0) {
            if (cErrno() == .INTR) continue;
            return; // Give up; the parent then sees a short read and assumes success.
        }
        i += @intCast(rc);
    }
}

/// The errno set common to execve failures; a subset of both SpawnError and
/// ReplaceError, so it coerces to either on return.
const ExecError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    NameTooLong,
    SystemFdQuotaExceeded,
    AccessDenied,
    PermissionDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    Unexpected,
};

/// execvpe-equivalent: exec `argv[0]` directly if it names a path, else search
/// `search_path`. Only returns on failure. Reimplemented rather than using glibc
/// execvpe because that is a GNU extension absent on the BSDs and Darwin.
fn exec(
    expand_arg0: bool,
    argv: [*:null]?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    search_path: []const u8,
) ExecError {
    const file = std.mem.sliceTo(argv[0].?, 0);
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        _ = c.execve(argv[0].?, argv, envp);
        return execveError(cErrno());
    }

    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const orig_arg0 = argv[0];
    defer if (expand_arg0) {
        argv[0] = orig_arg0;
    };

    var it = std.mem.tokenizeScalar(u8, search_path, ':');
    var saw_eacces = false;
    var last: ExecError = error.FileNotFound;
    while (it.next()) |dir| {
        const total = dir.len + 1 + file.len;
        if (total + 1 > path_buf.len) {
            last = error.NameTooLong;
            continue;
        }
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + 1 ..][0..file.len], file);
        path_buf[total] = 0;
        const full = path_buf[0..total :0];
        if (expand_arg0) argv[0] = full.ptr;

        _ = c.execve(full.ptr, argv, envp);
        last = execveError(cErrno());
        switch (last) {
            // Keep searching later PATH entries on these; remember EACCES so a
            // later ENOENT does not mask a genuine permission problem.
            error.AccessDenied => saw_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => return last,
        }
    }
    if (saw_eacces) return error.AccessDenied;
    return last;
}

fn execveError(e: c.E) ExecError {
    return switch (e) {
        .@"2BIG" => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => error.NameTooLong,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .INVAL, .NOEXEC => error.InvalidExe,
        .IO, .LOOP => error.FileSystem,
        .ISDIR => error.IsDir,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .TXTBSY => error.FileBusy,
        else => switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => switch (e) {
                .BADEXEC, .BADARCH => error.InvalidExe,
                else => unexpectedError(e),
            },
            .linux => switch (e) {
                .LIBBAD => error.InvalidExe,
                else => unexpectedError(e),
            },
            else => unexpectedError(e),
        },
    };
}
