// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const fs = @import("fs.zig");
const Pipe = fs.Pipe;
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const Waiter = @import("common.zig").Waiter;
const waitForIo = @import("common.zig").waitForIo;
const blockInPlace = @import("common.zig").blockInPlace;
const Timeout = @import("time.zig").Timeout;
const Runtime = @import("runtime.zig").Runtime;

pub const ExitStatus = os.process.ExitStatus;

pub const Command = struct {
    pub const StdioAction = os.process.StdioAction;

    pub const Options = struct {
        argv: []const []const u8,
        stdin: StdioAction = .inherit,
        stdout: StdioAction = .inherit,
        stderr: StdioAction = .inherit,
    };

    pub const SpawnError = os.process.SpawnError;

    pub fn spawn(allocator: std.mem.Allocator, options: Options) SpawnError!Child {
        const result = try os.process.spawn(
            allocator,
            options.argv,
            options.stdin,
            options.stdout,
            options.stderr,
        );

        var pidfd: ?os.fs.fd_t = null;
        if (builtin.os.tag == .linux) {
            pidfd = os.process.pidfdOpen(result.pid) catch null;
        }

        return .{
            .pid = result.pid,
            .pidfd = pidfd,
            .stdin = if (result.stdin_fd) |fd| Pipe.fromFd(fd) else null,
            .stdout = if (result.stdout_fd) |fd| Pipe.fromFd(fd) else null,
            .stderr = if (result.stderr_fd) |fd| Pipe.fromFd(fd) else null,
        };
    }
};

pub const Child = struct {
    pid: os.process.pid_t,
    pidfd: ?os.fs.fd_t,
    stdin: ?Pipe,
    stdout: ?Pipe,
    stderr: ?Pipe,

    pub const WaitError = os.process.WaitError || Cancelable;

    pub fn wait(self: *Child) WaitError!ExitStatus {
        if (builtin.os.tag == .linux) {
            return self.waitLinux();
        } else if (comptime isKqueue()) {
            return self.waitKqueue();
        } else {
            return self.waitBlocking();
        }
    }

    fn waitLinux(self: *Child) WaitError!ExitStatus {
        if (self.pidfd) |pidfd| {
            // pidfd is pollable - wait for it to become readable (= child exited)
            var op = ev.PipePoll.init(pidfd, .read);
            waitForIo(&op.c) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            _ = op.getResult() catch {};
            // Now reap the child
            return os.process.waitpidBlocking(self.pid);
        }
        // Fallback: no pidfd (old kernel)
        return self.waitBlocking();
    }

    fn waitKqueue(self: *Child) WaitError!ExitStatus {
        // Use EVFILT_PROC to get async notification of process exit
        var op = ev.ProcessWait.init(self.pid);
        waitForIo(&op.c) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };
        _ = op.getResult() catch {};
        // Reap the child
        return os.process.waitpidBlocking(self.pid);
    }

    fn waitBlocking(self: *Child) WaitError!ExitStatus {
        return blockInPlace(os.process.waitpidBlocking, .{self.pid});
    }

    fn isKqueue() bool {
        return switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
            else => false,
        };
    }

    pub fn deinit(self: *Child) void {
        if (self.stdin) |p| p.close();
        if (self.stdout) |p| p.close();
        if (self.stderr) |p| p.close();
        if (self.pidfd) |fd| std.posix.close(fd);
        os.process.closePid(self.pid);
        self.* = undefined;
    }
};

test "process: spawn and wait for /bin/true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try Command.spawn(std.testing.allocator, .{
        .argv = &.{"/bin/true"},
    });
    defer child.deinit();

    const status = try child.wait();
    try std.testing.expectEqual(ExitStatus{ .exited = 0 }, status);
}

test "process: spawn and wait for /bin/false" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try Command.spawn(std.testing.allocator, .{
        .argv = &.{"/bin/false"},
    });
    defer child.deinit();

    const status = try child.wait();
    try std.testing.expectEqual(ExitStatus{ .exited = 1 }, status);
}

test "process: stdout pipe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try Command.spawn(std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "hello" },
        .stdout = .pipe,
    });
    defer child.deinit();

    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try child.stdout.?.read(buf[total..], .none);
        if (n == 0) break;
        total += n;
    }

    try std.testing.expectEqualStrings("hello\n", buf[0..total]);

    const status = try child.wait();
    try std.testing.expectEqual(ExitStatus{ .exited = 0 }, status);
}

test "process: stdin and stdout pipe with cat" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try Command.spawn(std.testing.allocator, .{
        .argv = &.{"/bin/cat"},
        .stdin = .pipe,
        .stdout = .pipe,
    });
    defer child.deinit();

    // Write to stdin
    const input = "test data\n";
    _ = try child.stdin.?.write(input, .none);
    child.stdin.?.close();
    child.stdin = null;

    // Read from stdout
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try child.stdout.?.read(buf[total..], .none);
        if (n == 0) break;
        total += n;
    }

    try std.testing.expectEqualStrings(input, buf[0..total]);

    const status = try child.wait();
    try std.testing.expectEqual(ExitStatus{ .exited = 0 }, status);
}

test "process: spawn nonexistent command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const result = Command.spawn(std.testing.allocator, .{
        .argv = &.{"/nonexistent/command/that/does/not/exist"},
    });
    try std.testing.expectError(error.FileNotFound, result);
}

test {
    _ = Command;
    _ = Child;
}
