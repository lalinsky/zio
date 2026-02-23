const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const fs = @import("fs.zig");
const unexpectedError = @import("base.zig").unexpectedError;

const windows = builtin.os.tag == .windows;
const E = posix.system.E;

const c_libc = struct {
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

pub const pid_t = if (windows) @import("windows.zig").HANDLE else posix.system.pid_t;

pub const ExitStatus = union(enum) {
    exited: u8,
    signaled: u8,
    stopped: u8,
    unknown: u32,
};

pub const StdioAction = enum {
    inherit,
    pipe,
    close,
};

pub const SpawnResult = struct {
    pid: pid_t,
    stdin_fd: ?fs.fd_t = null,
    stdout_fd: ?fs.fd_t = null,
    stderr_fd: ?fs.fd_t = null,
};

pub const SpawnError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    OutOfMemory,
    AccessDenied,
    FileNotFound,
    Unexpected,
};

/// Convert libc-style return value (returns -1 on error) to errno
fn libcErrno(rc: anytype) E {
    if (builtin.os.tag == .linux) {
        // On Linux, std.c functions set errno via thread-local
        return if (rc == -1) @enumFromInt(std.c._errno().*) else .SUCCESS;
    } else {
        return posix.errno(rc);
    }
}

pub fn spawn(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdin_action: StdioAction,
    stdout_action: StdioAction,
    stderr_action: StdioAction,
) SpawnError!SpawnResult {
    if (windows) {
        @compileError("Windows process spawn not yet implemented");
    } else {
        return spawnPosix(allocator, argv, stdin_action, stdout_action, stderr_action);
    }
}

fn spawnPosix(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    stdin_action: StdioAction,
    stdout_action: StdioAction,
    stderr_action: StdioAction,
) SpawnError!SpawnResult {

    // Build C-style null-terminated argv for execvp
    var total_len: usize = 0;
    for (argv) |arg| total_len += arg.len + 1;

    const argv_buf = alloc.alloc(?[*:0]const u8, argv.len + 1) catch return error.OutOfMemory;
    defer alloc.free(argv_buf);

    const str_buf = alloc.alloc(u8, total_len) catch return error.OutOfMemory;
    defer alloc.free(str_buf);

    var offset: usize = 0;
    for (argv, 0..) |arg, i| {
        @memcpy(str_buf[offset..][0..arg.len], arg);
        str_buf[offset + arg.len] = 0;
        argv_buf[i] = @ptrCast(str_buf[offset..][0..arg.len :0].ptr);
        offset += arg.len + 1;
    }
    argv_buf[argv.len] = null;

    // Create pipes for .pipe actions (cloexec so child-side fds auto-close on exec)
    var stdin_pipe: ?[2]std.posix.fd_t = null;
    var stdout_pipe: ?[2]std.posix.fd_t = null;
    var stderr_pipe: ?[2]std.posix.fd_t = null;

    if (stdin_action == .pipe) {
        stdin_pipe = posix.pipe(.{ .cloexec = true }) catch |err| return mapPipeError(err);
    }
    errdefer if (stdin_pipe) |fds| {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    };

    if (stdout_action == .pipe) {
        stdout_pipe = posix.pipe(.{ .cloexec = true }) catch |err| return mapPipeError(err);
    }
    errdefer if (stdout_pipe) |fds| {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    };

    if (stderr_action == .pipe) {
        stderr_pipe = posix.pipe(.{ .cloexec = true }) catch |err| return mapPipeError(err);
    }
    errdefer if (stderr_pipe) |fds| {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    };

    // Error pipe for exec failure reporting (cloexec'd write end)
    const error_pipe = posix.pipe(.{ .cloexec = true }) catch |err| return mapPipeError(err);
    defer std.posix.close(error_pipe[0]); // Parent always closes read end after use

    const pid = std.c.fork();
    const fork_errno = libcErrno(pid);
    if (fork_errno != .SUCCESS) {
        std.posix.close(error_pipe[1]);
        return switch (fork_errno) {
            .AGAIN => error.OutOfMemory,
            .NOMEM => error.OutOfMemory,
            else => unexpectedError(fork_errno),
        };
    }

    if (pid == 0) {
        // === Child process ===
        // Close parent-side of error pipe (read end)
        std.posix.close(error_pipe[0]);

        // Set up stdin
        switch (stdin_action) {
            .pipe => {
                const fds = stdin_pipe.?;
                _ = std.c.dup2(fds[0], std.posix.STDIN_FILENO);
                std.posix.close(fds[0]);
                std.posix.close(fds[1]);
            },
            .close => std.posix.close(std.posix.STDIN_FILENO),
            .inherit => {},
        }

        // Set up stdout
        switch (stdout_action) {
            .pipe => {
                const fds = stdout_pipe.?;
                _ = std.c.dup2(fds[1], std.posix.STDOUT_FILENO);
                std.posix.close(fds[0]);
                std.posix.close(fds[1]);
            },
            .close => std.posix.close(std.posix.STDOUT_FILENO),
            .inherit => {},
        }

        // Set up stderr
        switch (stderr_action) {
            .pipe => {
                const fds = stderr_pipe.?;
                _ = std.c.dup2(fds[1], std.posix.STDERR_FILENO);
                std.posix.close(fds[0]);
                std.posix.close(fds[1]);
            },
            .close => std.posix.close(std.posix.STDERR_FILENO),
            .inherit => {},
        }

        // exec - on success this doesn't return
        _ = c_libc.execvp(argv_buf[0].?, @ptrCast(argv_buf.ptr));

        // exec failed - write errno to error pipe
        const err_int: u32 = @intFromEnum(libcErrno(@as(c_int, -1)));
        _ = std.c.write(error_pipe[1], std.mem.asBytes(&err_int), @sizeOf(u32));
        std.c._exit(127);
    }

    // === Parent process ===

    // Close child-side pipe ends
    if (stdin_pipe) |fds| std.posix.close(fds[0]); // Close read end
    if (stdout_pipe) |fds| std.posix.close(fds[1]); // Close write end
    if (stderr_pipe) |fds| std.posix.close(fds[1]); // Close write end

    // Close write end of error pipe (child has it via fork, cloexec will close on exec)
    std.posix.close(error_pipe[1]);

    // Read from error pipe - empty means exec succeeded, data means exec errno
    var exec_err: u32 = undefined;
    const n = std.c.read(error_pipe[0], std.mem.asBytes(&exec_err), @sizeOf(u32));
    if (n > 0) {
        // Exec failed - reap the child and return error
        _ = std.c.waitpid(pid, null, 0);
        // Clean up parent-side pipe ends
        if (stdin_pipe) |fds| std.posix.close(fds[1]);
        if (stdout_pipe) |fds| std.posix.close(fds[0]);
        if (stderr_pipe) |fds| std.posix.close(fds[0]);

        const exec_errno: E = @enumFromInt(exec_err);
        return switch (exec_errno) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOMEM => error.OutOfMemory,
            else => unexpectedError(exec_errno),
        };
    }

    // Set parent-side pipe ends to nonblocking
    if (stdin_pipe) |fds| posix.setNonblocking(fds[1]) catch {};
    if (stdout_pipe) |fds| posix.setNonblocking(fds[0]) catch {};
    if (stderr_pipe) |fds| posix.setNonblocking(fds[0]) catch {};

    return .{
        .pid = pid,
        .stdin_fd = if (stdin_pipe) |fds| fds[1] else null, // Write end
        .stdout_fd = if (stdout_pipe) |fds| fds[0] else null, // Read end
        .stderr_fd = if (stderr_pipe) |fds| fds[0] else null, // Read end
    };
}

fn mapPipeError(err: posix.PipeError) SpawnError {
    return switch (err) {
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.Unexpected => error.Unexpected,
    };
}

pub const PidfdOpenError = error{
    ProcessNotFound,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

pub fn pidfdOpen(pid: pid_t) PidfdOpenError!fs.fd_t {
    if (builtin.os.tag != .linux) @compileError("pidfdOpen is Linux-only");
    const rc = posix.sys.pidfd_open(pid, 0);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .SRCH => error.ProcessNotFound,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOSYS => error.Unexpected, // Kernel too old
        else => |err| unexpectedError(err),
    };
}

pub const WaitError = error{Unexpected};

pub fn waitpidBlocking(pid: pid_t) WaitError!ExitStatus {
    if (windows) @compileError("waitpidBlocking not available on Windows");
    while (true) {
        var status: u32 = undefined;
        const rc = std.c.waitpid(pid, @ptrCast(&status), 0);
        switch (libcErrno(rc)) {
            .SUCCESS => return parseWaitStatus(status),
            .INTR => continue,
            else => |err| return unexpectedError(err),
        }
    }
}

fn parseWaitStatus(status: u32) ExitStatus {
    // These macros follow POSIX wait status encoding
    if (status & 0x7f == 0) {
        // WIFEXITED: low 7 bits are 0
        return .{ .exited = @intCast((status >> 8) & 0xff) };
    } else if (status & 0x7f != 0x7f) {
        // WIFSIGNALED: low 7 bits are non-zero and not 0x7f
        return .{ .signaled = @intCast(status & 0x7f) };
    } else if (status >> 8 != 0) {
        // WIFSTOPPED: low 8 bits are 0x7f
        return .{ .stopped = @intCast((status >> 8) & 0xff) };
    } else {
        return .{ .unknown = status };
    }
}

pub fn closePid(pid: pid_t) void {
    if (windows) {
        // Windows: close process handle
        _ = @import("windows.zig").CloseHandle(pid);
    }
    // POSIX: no-op
}
