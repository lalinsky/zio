const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("loop.zig").Loop;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const NetClose = @import("completion.zig").NetClose;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const FileStreamPoll = @import("completion.zig").FileStreamPoll;
const FileStreamRead = @import("completion.zig").FileStreamRead;
const FileStreamWrite = @import("completion.zig").FileStreamWrite;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const net = @import("../os/net.zig");
const os_time = @import("../os/time.zig");
const time = @import("../time.zig");
const posix = @import("../os/posix.zig");
const fs = @import("../os/fs.zig");

test {
    _ = @import("test/thread_pool.zig");
    _ = @import("test/stream_server.zig");
    _ = @import("test/poll_server.zig");
    _ = @import("test/dgram_server.zig");
    _ = @import("test/fs.zig");
    _ = @import("test/timer.zig");
    _ = @import("test/cancel.zig");
    _ = @import("test/group.zig");
}

test "Loop: empty run(.no_wait)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.no_wait);
}

test "Loop: empty run(.once)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.once);
}

test "Loop: empty run(.until_done)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.until_done);
}

test "Loop: timer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 50;
    var timer: Timer = .init(.{ .duration = .fromMilliseconds(timeout_ms) });
    loop.add(&timer.c);

    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= timeout_ms - 5);
    try std.testing.expect(elapsed.toMilliseconds() <= timeout_ms + 100);
    std.log.info("timer: expected={}ms, actual={f}", .{ timeout_ms, elapsed });
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&open.c);
    try loop.run(.until_done);
    const sock = try open.c.getResult(.net_open);

    // Now close it
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: socket create and bind" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create socket
    var open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&open.c);
    try loop.run(.until_done);

    const sock = try open.c.getResult(.net_open);

    // Bind to localhost
    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run(.until_done);

    try bind.c.getResult(.net_bind);

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: async notification - same thread" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    // Notify immediately in same thread
    async_handle.notify();

    // Run loop - async should complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
    try async_handle.c.getResult(.async);
}

test "Loop: async notification - cross-thread" {
    const Context = struct {
        async_handle: *Async,
    };

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    // Create thread that will notify after a delay
    var ctx = Context{ .async_handle = &async_handle };
    const thread = try std.Thread.spawn(.{}, struct {
        fn notifyThread(c: *Context) void {
            os_time.sleep(.fromMilliseconds(10));
            c.async_handle.notify();
        }
    }.notifyThread, .{&ctx});

    // Run loop - should block until notified
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
    try async_handle.c.getResult(.async);

    thread.join();
}

test "Loop: async notification - multiple handles" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async1: Async = .init();
    var async2: Async = .init();
    var async3: Async = .init();

    loop.add(&async1.c);
    loop.add(&async2.c);
    loop.add(&async3.c);

    // Notify all three
    async1.notify();
    async2.notify();
    async3.notify();

    // Run loop - all should complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async1.c.state);
    try std.testing.expectEqual(.dead, async2.c.state);
    try std.testing.expectEqual(.dead, async3.c.state);
}

test "Loop: async notification - re-arm" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();

    // First notification cycle
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);

    // Re-arm for second notification
    async_handle = .init();
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
}

test "FileStream: write and read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a pipe
    const pipefd = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
    defer _ = fs.close(pipefd[0]) catch {};
    defer _ = fs.close(pipefd[1]) catch {};

    // Write data to the pipe
    const write_data = "Hello, pipe!";
    var write_iovecs: [1]fs.iovec_const = undefined;
    const write_buf = WriteBuf.fromSlice(write_data, &write_iovecs);
    var stream_write: FileStreamWrite = .init(pipefd[1], write_buf);
    loop.add(&stream_write.c);
    try loop.run(.until_done);
    const written = try stream_write.getResult();
    try std.testing.expectEqual(write_data.len, written);

    // Read data from the pipe
    var read_data: [128]u8 = undefined;
    var read_iovecs: [1]fs.iovec = undefined;
    const read_buf = ReadBuf.fromSlice(&read_data, &read_iovecs);
    var stream_read: FileStreamRead = .init(pipefd[0], read_buf);
    loop.add(&stream_read.c);
    try loop.run(.until_done);
    const read_len = try stream_read.getResult();
    try std.testing.expectEqual(write_data.len, read_len);
    try std.testing.expectEqualStrings(write_data, read_data[0..read_len]);
}

test "FileStream: poll for readability" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a pipe
    const pipefd = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
    defer _ = fs.close(pipefd[0]) catch {};
    defer _ = fs.close(pipefd[1]) catch {};

    // Write data so the read end becomes readable
    const write_data = "poll test";
    _ = posix.system.write(pipefd[1], write_data.ptr, write_data.len);

    // Poll for readability
    var stream_poll: FileStreamPoll = .init(pipefd[0], .read);
    loop.add(&stream_poll.c);
    try loop.run(.until_done);
    try stream_poll.getResult();

    // Verify we can read the data
    var read_data: [128]u8 = undefined;
    const read_len = posix.system.read(pipefd[0], &read_data, read_data.len);
    try std.testing.expectEqual(write_data.len, @as(usize, @intCast(read_len)));
}
