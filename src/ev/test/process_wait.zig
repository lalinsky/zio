const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const ProcessWait = @import("../completion.zig").ProcessWait;
const ThreadPool = @import("../thread_pool.zig").ThreadPool;

fn processWaitCallback(loop: *Loop, c: *@import("../completion.zig").Completion) void {
    _ = loop;
    _ = c;
}

test "ProcessWait: wait for child process exit code 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tp: ThreadPool = undefined;
    try tp.init(std.testing.allocator, .{ .min_threads = 1 });
    defer tp.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &tp });
    defer loop.deinit();

    // Spawn /bin/true which exits with code 0
    var child = std.process.Child.init(&.{"/bin/true"}, std.testing.allocator);
    try child.spawn();

    var wait = ProcessWait.init(child.id);
    wait.c.callback = processWaitCallback;
    loop.add(&wait.c);

    try loop.run(.until_done);

    const result = try wait.getResult();
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

    // Spawn /bin/false which exits with code 1
    var child = std.process.Child.init(&.{"/bin/false"}, std.testing.allocator);
    try child.spawn();

    var wait = ProcessWait.init(child.id);
    wait.c.callback = processWaitCallback;
    loop.add(&wait.c);

    try loop.run(.until_done);

    const result = try wait.getResult();
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

    // Spawn a process that kills itself with SIGKILL
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", "kill -9 $$" }, std.testing.allocator);
    try child.spawn();

    var wait = ProcessWait.init(child.id);
    wait.c.callback = processWaitCallback;
    loop.add(&wait.c);

    try loop.run(.until_done);

    const result = try wait.getResult();
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqual(@as(?u8, 9), result.signal); // SIGKILL = 9
}
