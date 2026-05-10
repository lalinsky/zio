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
