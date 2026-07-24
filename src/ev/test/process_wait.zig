const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const ProcessWait = @import("../completion.zig").ProcessWait;
const ThreadPool = @import("../thread_pool.zig").ThreadPool;

const argv_exit0: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "exit 0" }
else
    &.{ "/bin/sh", "-c", "exit 0" };

const argv_exit1: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "exit 1" }
else
    &.{ "/bin/sh", "-c", "exit 1" };

const argv_kill_self: []const []const u8 = if (builtin.os.tag == .windows)
    &.{}
else
    &.{ "/bin/sh", "-c", "kill -TERM $$" };

test "ProcessWait: wait for child process exit code 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tp: ThreadPool = undefined;
    try tp.init(std.testing.allocator, .{ .min_threads = 1 });
    defer tp.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &tp });
    defer loop.deinit();

    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = argv_exit0 });
    defer if (child.id != null) child.kill(io);

    var wait = ProcessWait.init(child.id.?);
    loop.add(&wait.c);
    try loop.run(.until_done);

    const result = try wait.getResult();
    child.id = null;
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(?u8, null), result.signal);
}

test "ProcessWait: wait for child process exit code 1" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tp: ThreadPool = undefined;
    try tp.init(std.testing.allocator, .{ .min_threads = 1 });
    defer tp.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &tp });
    defer loop.deinit();

    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = argv_exit1 });
    defer if (child.id != null) child.kill(io);

    var wait = ProcessWait.init(child.id.?);
    loop.add(&wait.c);
    try loop.run(.until_done);

    const result = try wait.getResult();
    child.id = null;
    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expectEqual(@as(?u8, null), result.signal);
}

test "ProcessWait: wait for child process killed by signal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tp: ThreadPool = undefined;
    try tp.init(std.testing.allocator, .{ .min_threads = 1 });
    defer tp.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &tp });
    defer loop.deinit();

    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = argv_kill_self });
    defer if (child.id != null) child.kill(io);

    var wait = ProcessWait.init(child.id.?);
    loop.add(&wait.c);
    try loop.run(.until_done);

    const result = try wait.getResult();
    child.id = null;
    try std.testing.expectEqual(@as(?u8, @intFromEnum(std.posix.SIG.TERM)), result.signal);
}
