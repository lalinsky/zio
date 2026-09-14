const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("loop.zig").Loop;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const NetClose = @import("completion.zig").NetClose;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const NetRecvMsg = @import("completion.zig").NetRecvMsg;
const NetSendTo = @import("completion.zig").NetSendTo;
const NetPoll = @import("completion.zig").NetPoll;
const Backend = @import("backend.zig").Backend;
const PipePoll = @import("completion.zig").PipePoll;
const FileReadStreaming = @import("completion.zig").FileReadStreaming;
const FileWriteStreaming = @import("completion.zig").FileWriteStreaming;
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
    _ = @import("test/dgram_server_msg.zig");
    _ = @import("test/fs.zig");
    _ = @import("test/timer.zig");
    _ = @import("test/cancel.zig");
    _ = @import("test/group.zig");
    _ = @import("test/blocking_sockets.zig");
    _ = @import("test/process_wait.zig");
    _ = @import("test/async_stress.zig");
}

test "Loop: empty poll(.zero)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.poll(.zero);
}

test "Loop: empty poll(.max)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.poll(.max);
}

test "Loop: empty run()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run();
}

test "Loop: timer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 50;
    var timer: Timer = .init(.{ .duration = .fromMilliseconds(timeout_ms) });
    loop.add(&timer.c);

    var wall_timer = time.Stopwatch.start();
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
    try std.testing.expect(elapsed.toMilliseconds() >= timeout_ms - 5);
    try std.testing.expect(elapsed.toMilliseconds() <= timeout_ms + 100);
    std.log.info("timer: expected={}ms, actual={f}", .{ timeout_ms, elapsed });
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .ip, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run();
    const sock = try open.c.getResult(.net_open);

    // Now close it
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run();
}

test "Loop: socket create and bind" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create socket
    var open: NetOpen = .init(.ipv4, .stream, .ip, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run();

    const sock = try open.c.getResult(.net_open);

    // Bind to localhost
    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run();

    try bind.c.getResult(.net_bind);

    // Binding port 0 must write the actual bound address back — a contract
    // every backend path has to keep, including IORING_OP_BIND (which does
    // not report the address by itself).
    try std.testing.expect(addr.port != 0);

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run();
}

test "Loop: dontwait recvmsg reports an empty queue as WouldBlock" {
    if (!Backend.supports_recv_dontwait) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var open: NetOpen = .init(.ipv4, .dgram, .ip, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run();
    const sock = try open.c.getResult(.net_open);

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run();
    try bind.c.getResult(.net_bind);

    // Nothing queued: the operation completes instead of parking.
    var buf: [32]u8 = undefined;
    var iov: [1]net.iovec = undefined;
    var recv: NetRecvMsg = .init(sock, .fromSlice(&buf, &iov), .{ .dontwait = true }, null, null, null);
    loop.add(&recv.c);
    try loop.run();
    try std.testing.expectError(error.WouldBlock, recv.c.getResult(.net_recvmsg));

    // A queued datagram is received without waiting. Loopback delivery is
    // asynchronous on some kernels, so keep asking until it has arrived:
    // every attempt must come back promptly, with WouldBlock until then.
    var send_iov: [1]net.iovec_const = undefined;
    var send: NetSendTo = .init(sock, .fromSlice("ping", &send_iov), .{}, @ptrCast(&addr), addr_len);
    loop.add(&send.c);
    try loop.run();
    try std.testing.expectEqual(4, try send.c.getResult(.net_sendto));

    var attempts: usize = 0;
    const result = while (attempts < 5000) : (attempts += 1) {
        var recv2: NetRecvMsg = .init(sock, .fromSlice(&buf, &iov), .{ .dontwait = true }, null, null, null);
        loop.add(&recv2.c);
        try loop.run();
        break recv2.c.getResult(.net_recvmsg) catch |err| switch (err) {
            error.WouldBlock => {
                os_time.sleep(.fromMilliseconds(1));
                continue;
            },
            else => return err,
        };
    } else return error.DatagramNeverArrived;
    try std.testing.expectEqualStrings("ping", buf[0..result.len]);

    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run();
}

test "Loop: NetPoll on a datagram socket reports readiness and keeps the datagram" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var open: NetOpen = .init(.ipv4, .dgram, .ip, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run();
    const sock = try open.c.getResult(.net_open);

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run();
    try bind.c.getResult(.net_bind);

    var buf: [32]u8 = undefined;
    var iov: [1]net.iovec = undefined;
    var send_iov: [1]net.iovec_const = undefined;

    // Poll first, then send in the same run: the poll parks and is woken by
    // the datagram. The datagram must survive the poll.
    var readable: NetPoll = .init(sock, .recv);
    loop.add(&readable.c);
    var send: NetSendTo = .init(sock, .fromSlice("ping", &send_iov), .{}, @ptrCast(&addr), addr_len);
    loop.add(&send.c);
    try loop.run();
    try std.testing.expectEqual(4, try send.c.getResult(.net_sendto));
    try readable.c.getResult(.net_poll);

    var recv: NetRecvMsg = .init(sock, .fromSlice(&buf, &iov), .{}, null, null, null);
    loop.add(&recv.c);
    try loop.run();
    const first = try recv.c.getResult(.net_recvmsg);
    try std.testing.expectEqualStrings("ping", buf[0..first.len]);

    // Send first, then poll: the datagram is already queued when the poll
    // is submitted, so readiness is answered on submit.
    var send2: NetSendTo = .init(sock, .fromSlice("pong", &send_iov), .{}, @ptrCast(&addr), addr_len);
    loop.add(&send2.c);
    try loop.run();
    try std.testing.expectEqual(4, try send2.c.getResult(.net_sendto));

    var readable2: NetPoll = .init(sock, .recv);
    loop.add(&readable2.c);
    try loop.run();
    try readable2.c.getResult(.net_poll);

    var recv2: NetRecvMsg = .init(sock, .fromSlice(&buf, &iov), .{}, null, null, null);
    loop.add(&recv2.c);
    try loop.run();
    const second = try recv2.c.getResult(.net_recvmsg);
    try std.testing.expectEqualStrings("pong", buf[0..second.len]);

    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run();
}

test "Loop: receiving a datagram into a short buffer" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var open: NetOpen = .init(.ipv4, .dgram, .ip, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run();
    const sock = try open.c.getResult(.net_open);

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run();
    try bind.c.getResult(.net_bind);

    var send_iov: [1]net.iovec_const = undefined;
    var send: NetSendTo = .init(sock, .fromSlice("eightbyt", &send_iov), .{}, @ptrCast(&addr), addr_len);
    loop.add(&send.c);
    try loop.run();
    try std.testing.expectEqual(8, try send.c.getResult(.net_sendto));

    // The datagram is already queued, so the receive is answered on submit.
    // POSIX truncates and reports the bytes kept; Winsock reports the
    // truncation as WSAEMSGSIZE, and that completion must arrive exactly
    // once.
    var buf: [4]u8 = undefined;
    var iov: [1]net.iovec = undefined;
    var recv: NetRecvMsg = .init(sock, .fromSlice(&buf, &iov), .{}, null, null, null);
    loop.add(&recv.c);
    try loop.run();
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.MessageOversize, recv.c.getResult(.net_recvmsg));
    } else {
        const result = try recv.c.getResult(.net_recvmsg);
        try std.testing.expectEqualStrings("eigh", buf[0..result.len]);
    }

    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run();
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
    try loop.run();
    try std.testing.expectEqual(.dead, async_handle.c.loadState().phase);
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
    try loop.run();
    try std.testing.expectEqual(.dead, async_handle.c.loadState().phase);
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
    try loop.run();
    try std.testing.expectEqual(.dead, async1.c.loadState().phase);
    try std.testing.expectEqual(.dead, async2.c.loadState().phase);
    try std.testing.expectEqual(.dead, async3.c.loadState().phase);
}

test "Loop: async notification - re-arm" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();

    // First notification cycle
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run();
    try std.testing.expectEqual(.dead, async_handle.c.loadState().phase);

    // Re-arm for second notification
    async_handle = .init();
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run();
    try std.testing.expectEqual(.dead, async_handle.c.loadState().phase);
}

test "Pipe: write and read" {
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
    var stream_write: FileWriteStreaming = .init(pipefd[1], write_buf);
    stream_write.pollable = true;
    loop.add(&stream_write.c);
    try loop.run();
    const written = try stream_write.getResult();
    try std.testing.expectEqual(write_data.len, written);

    // Read data from the pipe
    var read_data: [128]u8 = undefined;
    var read_iovecs: [1]fs.iovec = undefined;
    const read_buf = ReadBuf.fromSlice(&read_data, &read_iovecs);
    var stream_read: FileReadStreaming = .init(pipefd[0], read_buf);
    stream_read.pollable = true;
    loop.add(&stream_read.c);
    try loop.run();
    const read_len = try stream_read.getResult();
    try std.testing.expectEqual(write_data.len, read_len);
    try std.testing.expectEqualStrings(write_data, read_data[0..read_len]);
}

test "Pipe: poll for readability" {
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
    var stream_poll: PipePoll = .init(pipefd[0], .read);
    loop.add(&stream_poll.c);
    try loop.run();
    try stream_poll.getResult();

    // Verify we can read the data
    var read_data: [128]u8 = undefined;
    const read_len = posix.system.read(pipefd[0], &read_data, read_data.len);
    try std.testing.expectEqual(write_data.len, @as(usize, @intCast(read_len)));
}
