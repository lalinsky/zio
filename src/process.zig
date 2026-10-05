// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("runtime.zig").Runtime;
const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const waitForIo = @import("common.zig").waitForIo;
const waitForIoUncancelable = @import("common.zig").waitForIoUncancelable;

const ProcessHandle = ev.ProcessWait.ProcessHandle;

pub fn childWait(child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
    var op = ev.ProcessWait.init(child.id.?);
    waitForIo(&op.c) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
    const status = op.getResult() catch |err| switch (err) {
        error.ProcessNotFound => return error.Unexpected,
        error.SystemResources => return error.Unexpected,
        error.Canceled => return error.Canceled,
        error.Unexpected => return error.Unexpected,
    };
    const term = exitStatusToTerm(status);
    childCleanup(child);
    return term;
}

pub fn childKill(child: *std.process.Child) void {
    sendTermSignal(child.id.?);
    var op = ev.ProcessWait.init(child.id.?);
    waitForIoUncancelable(&op.c);
    childCleanup(child);
}

fn exitStatusToTerm(status: ev.ProcessWait.ExitStatus) std.process.Child.Term {
    if (status.signal) |sig| {
        return .{ .signal = @enumFromInt(sig) };
    }
    return .{ .exited = status.code };
}

fn sendTermSignal(handle: ProcessHandle) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(handle, @enumFromInt(1));
    } else {
        _ = std.posix.system.kill(handle, .TERM);
    }
}

fn childCleanup(child: *std.process.Child) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.CloseHandle(child.id.?);
        std.os.windows.CloseHandle(child.thread_handle);
        child.thread_handle = undefined;
    }
    child.id = null;
    if (child.stdin) |f| {
        os.fs.close(f.handle) catch {};
        child.stdin = null;
    }
    if (child.stdout) |f| {
        os.fs.close(f.handle) catch {};
        child.stdout = null;
    }
    if (child.stderr) |f| {
        os.fs.close(f.handle) catch {};
        child.stderr = null;
    }
}

// POSIX: "true"/"false"/"sleep". Windows: cmd.exe equivalents.
const argv_exit0: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "exit 0" }
else
    &.{"true"};

const argv_exit1: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "exit 1" }
else
    &.{"false"};

const argv_sleep: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "timeout /t 100 /nobreak" }
else
    &.{ "sleep", "100" };

test "childWait: exit code 0" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try std.process.spawn(rt.io(), .{ .argv = argv_exit0 });
    const term = try childWait(&child);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

test "childWait: exit code 1" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try std.process.spawn(rt.io(), .{ .argv = argv_exit1 });
    const term = try childWait(&child);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, term);
}

test "childKill: terminates process" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try std.process.spawn(rt.io(), .{ .argv = argv_sleep });
    childKill(&child);
    try std.testing.expect(child.id == null);
}

test "childWait: spawn nonexistent binary returns FileNotFound" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const result = std.process.spawn(rt.io(), .{ .argv = &.{"definitely-not-a-real-binary-xyz123"} });
    try std.testing.expectError(error.FileNotFound, result);
}

test "spawnPath returns OperationUnsupported" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const result = std.process.spawnPath(rt.io(), .cwd(), .{ .argv = argv_exit0 });
    try std.testing.expectError(error.OperationUnsupported, result);
}

test "replacePath returns OperationUnsupported" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const err = std.process.replacePath(rt.io(), .cwd(), .{ .argv = argv_exit0 });
    try std.testing.expectEqual(error.OperationUnsupported, err);
}

/// Runs this test binary again with only the test `name` selected, which relies
/// on test_runner.zig honoring TEST_FILTER, and the given extra environment.
fn runTestBinary(io: std.Io, name: []const u8, env: []const [2][]const u8) !std.process.Child.Term {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);

    var environ_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ_map.deinit();
    if (std.c.getenv("PATH")) |path| try environ_map.put("PATH", std.mem.span(path));
    try environ_map.put("TEST_FILTER", name);
    for (env) |entry| try environ_map.put(entry[0], entry[1]);

    var child = std.process.spawn(io, .{
        .argv = &.{exe_buf[0..exe_len]},
        .environ_map = &environ_map,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        // Not running natively, e.g. under qemu without binfmt_misc.
        error.InvalidExe => return error.SkipZigTest,
        else => return err,
    };
    return childWait(&child);
}

test "spawn with a progress node" {
    if (builtin.os.tag == .windows or !builtin.link_libc) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    if (std.c.getenv("ZIO_TEST_PROGRESS") != null) {
        // Spawning removes ZIG_PROGRESS from the environment, so point it at
        // stdout here.
        const c = struct {
            extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        };
        try std.testing.expectEqual(0, c.setenv("ZIG_PROGRESS", "1", 1));
        const root = std.Progress.start(io, .{});
        defer root.end();
        const node = root.start("child", 0);
        defer node.end();
        try std.testing.expect(node.index != .none);

        var child = try std.process.spawn(io, .{ .argv = argv_exit0, .progress_node = node });
        const term = try childWait(&child);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
        return;
    }

    // The test runner starts its own progress tree unless it is verbose.
    const term = try runTestBinary(io, "spawn with a progress node", &.{
        .{ "TEST_VERBOSE", "true" },
        .{ "ZIO_TEST_PROGRESS", "1" },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}

test "spawn leaves the SIGIO disposition alone" {
    if (builtin.os.tag == .windows or !@hasField(os.posix.SIG, "IO")) return error.SkipZigTest;

    const S = struct {
        fn handler(_: os.posix.SIG) callconv(.c) void {}

        fn spawnMany(io: std.Io, first_err: *std.atomic.Value(u16)) void {
            for (0..16) |_| {
                var child = std.process.spawn(io, .{ .argv = argv_exit0 }) catch |err| return fail(first_err, err);
                _ = childWait(&child) catch |err| return fail(first_err, err);
            }
        }

        fn fail(first_err: *std.atomic.Value(u16), err: anyerror) void {
            _ = first_err.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);
        }
    };

    const act: os.posix.Sigaction = .{
        .handler = .{ .handler = S.handler },
        .mask = os.posix.sigemptyset(),
        .flags = 0,
    };
    var old: os.posix.Sigaction = undefined;
    os.posix.sigaction(os.posix.SIG.IO, &act, &old);
    defer os.posix.sigaction(os.posix.SIG.IO, &old, null);

    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    var first_err: std.atomic.Value(u16) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |_| try group.concurrent(io, S.spawnMany, .{ io, &first_err });
    try group.await(io);
    const err_int = first_err.load(.monotonic);
    if (err_int != 0) return @errorFromInt(err_int);

    var current: os.posix.Sigaction = undefined;
    os.posix.sigaction(os.posix.SIG.IO, null, &current);
    try std.testing.expect(current.handler.handler == S.handler);
}

test "replace keeps the environment" {
    if (!std.process.can_replace or !builtin.link_libc) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    if (std.c.getenv("ZIO_TEST_REPLACE") != null) {
        return std.process.replace(io, .{
            .argv = &.{ "sh", "-c", "test \"$ZIO_TEST_REPLACE_MARKER\" = ok" },
        });
    }

    const term = try runTestBinary(io, "replace keeps the environment", &.{
        .{ "ZIO_TEST_REPLACE", "1" },
        .{ "ZIO_TEST_REPLACE_MARKER", "ok" },
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
}
