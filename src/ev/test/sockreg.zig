const std = @import("std");
const builtin = @import("builtin");
const time = @import("../../time.zig");
const ev = @import("../root.zig");
const blocking = @import("../blocking.zig");
const os = @import("../../os/root.zig");
const Loop = ev.Loop;
const NetRecv = ev.NetRecv;
const NetClose = ev.NetClose;
const FileReadStreaming = ev.FileReadStreaming;
const net = os.net;

test "sockreg: a socket closed off the loop leaves no registration for its reused fd" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var buf: [16]u8 = undefined;
    var iov: [1]os.iovec = undefined;

    // Park a receive so the loop registers the socket, then cancel it.
    const old = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    var first: NetRecv = .init(old[0], .fromSlice(&buf, &iov), .{});
    loop.add(&first.c);
    loop.cancel(&first.c);
    try loop.run();
    try std.testing.expectError(error.Canceled, first.getResult());

    // Close it outside the loop, the way a thread without a runtime does.
    var close: NetClose = .init(old[0]);
    blocking.executeBlocking(&close.c);
    try close.c.getResult(.net_close);
    net.close(old[1]);

    const new = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(new[0]);
    defer net.close(new[1]);
    if (new[0] != old[0]) return error.SkipZigTest;

    var second: NetRecv = .init(new[0], .fromSlice(&buf, &iov), .{});
    loop.add(&second.c);
    _ = try net.send(new[1], &.{net.iovecConstFromSlice("x")}, .{});

    var stopwatch = time.Stopwatch.start();
    while (second.c.loadState().phase != .dead and stopwatch.read().toMilliseconds() < 1000) {
        try loop.poll(.fromMilliseconds(100));
    }
    if (second.c.loadState().phase != .dead) {
        loop.cancel(&second.c);
        try loop.run();
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(1, try second.getResult());
}

test "sockreg: a socket used on another loop wakes this one while that loop is not polling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (@import("../completion.zig").single_owner) return error.SkipZigTest;

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var group: ev.LoopGroup = .{};

    const Other = struct {
        group: *ev.LoopGroup,
        fd: net.fd_t,
        used: os.ResetEvent = .init(),
        done: os.ResetEvent = .init(),
        err: ?anyerror = null,

        // Registers the socket on its own loop, then stops polling.
        fn run(self: *@This()) void {
            self.runInner() catch |err| {
                self.err = err;
                self.used.set();
            };
        }

        fn runInner(self: *@This()) !void {
            var loop: Loop = undefined;
            try loop.init(.{ .loop_group = self.group });
            defer loop.deinit();

            var buf: [16]u8 = undefined;
            var iov: [1]os.iovec = undefined;
            var recv: NetRecv = .init(self.fd, .fromSlice(&buf, &iov), .{});
            loop.add(&recv.c);
            loop.cancel(&recv.c);
            try loop.run();

            self.used.set();
            self.done.wait();
        }
    };

    var other: Other = .{ .group = &group, .fd = fds[0] };
    const thread = try std.Thread.spawn(.{}, Other.run, .{&other});
    defer thread.join();
    defer other.done.set();

    other.used.wait();
    if (other.err) |err| return err;

    var loop: Loop = undefined;
    try loop.init(.{ .loop_group = &group });
    defer loop.deinit();

    var buf: [16]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &iov), .{});
    loop.add(&recv.c);
    _ = try net.send(fds[1], &.{net.iovecConstFromSlice("x")}, .{});

    var stopwatch = time.Stopwatch.start();
    while (recv.c.loadState().phase != .dead and stopwatch.read().toMilliseconds() < 1000) {
        try loop.poll(.fromMilliseconds(100));
    }
    if (recv.c.loadState().phase != .dead) {
        loop.cancel(&recv.c);
        try loop.run();
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(1, try recv.getResult());
}

test "sockreg: a socket read as a stream file after a socket receive on the same loop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var buf: [16]u8 = undefined;
    var iov: [1]os.iovec = undefined;

    // A receive registers the socket with the loop's poller, then goes away.
    var recv: NetRecv = .init(fds[0], .fromSlice(&buf, &iov), .{});
    loop.add(&recv.c);
    loop.cancel(&recv.c);
    try loop.run();
    try std.testing.expectError(error.Canceled, recv.getResult());

    // A streaming read of the same fd waits through the same registration.
    var read: FileReadStreaming = .init(fds[0], .fromSlice(&buf, &iov));
    loop.add(&read.c);
    try loop.poll(.zero);
    _ = try net.send(fds[1], &.{net.iovecConstFromSlice("x")}, .{});
    try loop.run();
    try std.testing.expectEqual(1, try read.getResult());
}
