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
        const rc = std.posix.system.kill(handle, .TERM);
        if (builtin.os.tag == .netbsd) {
            std.debug.print("NETBSD childKill: kill(pid={}, SIGTERM) rc={} errno={}\n", .{
                handle,
                rc,
                std.posix.errno(rc),
            });
        }
    }
}

fn dumpTermSignalState() void {
    if (builtin.os.tag != .netbsd) return;

    var action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.TERM, null, &action);
    var mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.SETMASK, null, &mask);

    const handler = action.handler.handler;
    std.debug.print(
        "NETBSD childKill: parent SIGTERM handler=0x{x} (DFL=0x{x}, IGN=0x{x}) blocked={} flags=0x{x}\n",
        .{
            if (handler) |h| @intFromPtr(h) else 0,
            0,
            1,
            std.posix.sigismember(&mask, .TERM),
            action.flags,
        },
    );
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
    &.{ "cmd.exe", "/c", "timeout /t 5 /nobreak" }
else
    &.{ "sleep", "5" };

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

    dumpTermSignalState();
    var child = try std.process.spawn(rt.io(), .{ .argv = argv_sleep });
    if (builtin.os.tag == .netbsd) {
        std.debug.print("NETBSD childKill: spawned pid={}\n", .{child.id.?});
    }
    childKill(&child);
    try std.testing.expect(child.id == null);
}

test "childKill: NetBSD child exits before process wait registration" {
    if (builtin.os.tag != .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var child = try std.process.spawn(rt.io(), .{ .argv = argv_sleep });
    std.debug.print("NETBSD delayed childKill: spawned pid={}\n", .{child.id.?});
    sendTermSignal(child.id.?);
    os.time.sleep(.fromMilliseconds(100));
    std.debug.print("NETBSD delayed childKill: registering ProcessWait after 100ms\n", .{});
    var op = ev.ProcessWait.init(child.id.?);
    waitForIoUncancelable(&op.c);
    childCleanup(&child);
    try std.testing.expect(child.id == null);
}

test "childKill: NetBSD repeated immediate termination" {
    if (builtin.os.tag != .netbsd) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    for (0..100) |iteration| {
        var child = try std.process.spawn(rt.io(), .{ .argv = argv_sleep });
        std.debug.print("NETBSD repeated childKill: iteration={} pid={}\n", .{ iteration, child.id.? });
        childKill(&child);
        try std.testing.expect(child.id == null);
    }
}

test "childWait: spawn nonexistent binary returns FileNotFound" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const result = std.process.spawn(rt.io(), .{ .argv = &.{"definitely-not-a-real-binary-xyz123"} });
    try std.testing.expectError(error.FileNotFound, result);
}
