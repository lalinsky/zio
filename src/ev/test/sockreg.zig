const std = @import("std");
const builtin = @import("builtin");
const time = @import("../../time.zig");
const ev = @import("../root.zig");
const blocking = @import("../blocking.zig");
const os = @import("../../os/root.zig");
const Loop = ev.Loop;
const NetRecv = ev.NetRecv;
const NetClose = ev.NetClose;
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
