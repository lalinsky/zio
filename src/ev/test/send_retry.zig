//! Tests for the io_uring send -EAGAIN bridge (netSendRetry).

const std = @import("std");
const builtin = @import("builtin");
const time = @import("../../time.zig");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const Loop = ev.Loop;
const NetSend = ev.NetSend;
const net = os.net;

/// Only the io_uring backend has bridge state.
const has_retry_state = builtin.os.tag == .linux and
    @hasDecl(ev.Backend, "selectedEngine") and
    @hasField(@FieldType(NetSend, "internal"), "retry");

/// A nonblocking AF_UNIX stream pair with a small send buffer on [0].
fn smallStreamPair() ![2]net.fd_t {
    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    errdefer for (fds) |fd| net.close(fd);
    const size: c_int = 16 * 1024;
    try net.setsockopt(fds[0], os.posix.SOL.SOCKET, os.posix.SO.SNDBUF, std.mem.asBytes(&size));
    return fds;
}

/// Write to `fd` until the kernel refuses more.
fn fill(fd: net.fd_t) !void {
    const chunk: [4096]u8 = @splat('f');
    var iov = [_]net.iovec_const{net.iovecConstFromSlice(&chunk)};
    while (true) {
        _ = net.send(fd, &iov, .{}) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }
}

/// Read from `fd` until nothing is left; returns the byte count.
fn drain(fd: net.fd_t) !usize {
    var buf: [64 * 1024]u8 = undefined;
    var iov = [_]net.iovec{net.iovecFromSlice(&buf)};
    var total: usize = 0;
    while (true) {
        total += net.recv(fd, &iov, .{}) catch |err| switch (err) {
            error.WouldBlock => return total,
            else => return err,
        };
    }
}

fn isDone(c: *ev.Completion) bool {
    return c.loadState().phase == .dead;
}

/// Run the loop for about `ms` milliseconds, or until `c` completes.
fn pumpFor(loop: *Loop, c: *ev.Completion, ms: u64) !void {
    var sw = time.Stopwatch.start();
    while (!isDone(c) and sw.read().toMilliseconds() < ms) {
        try loop.poll(.fromMilliseconds(5));
    }
}

test "send retry: a reused completion starts without the last run's bridge state" {
    if (comptime !has_retry_state) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();
    if (loop.backend.selectedEngine() != .io_uring) return error.SkipZigTest;

    const chunk: [16 * 1024]u8 = @splat('x');
    var storage: [2]os.iovec_const = undefined;
    // Two buffers: IORING_OP_SENDMSG, the opcode seen posting -EAGAIN.
    var op: NetSend = .init(-1, .fromSlices(&.{ &chunk, &chunk }, &storage), .{});

    // First run: park on a full socket, then half-close the peer so the
    // send enters the bridge.
    const first = try smallStreamPair();
    defer for (first) |fd| net.close(fd);
    try fill(first[0]);
    op.handle = first[0];
    loop.add(&op.c);
    try pumpFor(&loop, &op.c, 50);
    try std.testing.expect(!isDone(&op.c));
    try net.shutdown(first[1], .send);
    var sw = time.Stopwatch.start();
    while (op.internal.retry.epfd == -1 and !isDone(&op.c) and sw.read().toMilliseconds() < 2000) {
        try loop.poll(.fromMilliseconds(5));
    }
    if (op.internal.retry.epfd == -1) {
        // This kernel waited without posting -EAGAIN; nothing to reuse.
        try std.testing.expect(!isDone(&op.c));
        _ = try drain(first[1]);
        try pumpFor(&loop, &op.c, 2000);
        return error.SkipZigTest;
    }
    _ = try drain(first[1]);
    try pumpFor(&loop, &op.c, 2000);
    try std.testing.expect(isDone(&op.c));
    try std.testing.expect(try op.getResult() > 0);
    // The bridge state is still set after the run.
    try std.testing.expect(op.internal.retry.resend);

    // Second run, without init, on a healthy full socket: the bridge must not
    // run. A stale `resend` would send with MSG_DONTWAIT and open an epoll fd.
    const second = try smallStreamPair();
    defer for (second) |fd| net.close(fd);
    try fill(second[0]);
    op.handle = second[0];
    loop.add(&op.c);
    try pumpFor(&loop, &op.c, 100);
    try std.testing.expect(!isDone(&op.c));
    try std.testing.expectEqual(@as(i32, -1), op.internal.retry.epfd);
    try std.testing.expect(!op.internal.retry.resend);
    _ = try drain(second[1]);
    try pumpFor(&loop, &op.c, 2000);
    try std.testing.expect(isDone(&op.c));
    try std.testing.expect(try op.getResult() > 0);
}
