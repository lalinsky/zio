const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const net = @import("../../os/net.zig");

// Drains a socket via re-arming NetRecv until `expected` bytes have been read,
// accumulating into `buf`. Mirrors the re-arming recv pattern used elsewhere.
const Drainer = struct {
    recv: ev.NetRecv = undefined,
    iov: [1]os.iovec = undefined,
    sock: net.fd_t,
    buf: []u8,
    total: usize = 0,
    err: ?anyerror = null,

    fn start(self: *Drainer, loop: *ev.Loop) void {
        self.recv = ev.NetRecv.init(self.sock, .fromSlice(self.buf[self.total..], &self.iov), .{});
        self.recv.c.userdata = self;
        self.recv.c.callback = onRecv;
        loop.add(&self.recv.c);
    }

    fn onRecv(loop: *ev.Loop, c: *ev.Completion) void {
        const self: *Drainer = @ptrCast(@alignCast(c.userdata.?));
        const n = c.cast(ev.NetRecv).getResult() catch |e| {
            self.err = e;
            return;
        };
        self.total += n;
        if (n != 0 and self.total < self.buf.len) {
            self.start(loop); // re-arm for the remainder
        }
    }
};

test "sendfile: NetSendFile sends a file over a socket (fallback)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    const cwd = os.fs.cwd();

    // Build source content larger than the 16 KiB transfer buffer so the
    // fallback loop runs multiple read/write iterations.
    const len = 40_000;
    var content: [len]u8 = undefined;
    for (&content, 0..) |*b, i| b.* = @intCast(i % 251);

    // Create the file and write the content.
    var file_create = ev.FileCreate.init(cwd, "test-sendfile-data", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run(.until_done);
    const file_fd = try file_create.getResult();
    defer {
        var file_close = ev.FileClose.init(file_fd);
        loop.add(&file_close.c);
        loop.run(.until_done) catch {};
        var del = ev.DirDeleteFile.init(cwd, "test-sendfile-data");
        loop.add(&del.c);
        loop.run(.until_done) catch {};
    }

    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(file_fd, .fromSlice(&content, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run(.until_done);
    try std.testing.expectEqual(content.len, try file_write.getResult());

    // Connected socket pair: write into [0], drain from [1].
    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    // Submit the writer and a concurrent drainer to the same loop, so the
    // socket buffer never fills and stalls the writer.
    var recv_buf: [len]u8 = undefined;
    var drainer = Drainer{ .sock = fds[1], .buf = &recv_buf };
    drainer.start(&loop);

    var send_file = ev.NetSendFile.init(fds[0], file_fd, 0, std.math.maxInt(usize));
    loop.add(&send_file.c);

    try loop.run(.until_done);

    // The writer transferred the whole file.
    try std.testing.expectEqual(content.len, try send_file.getResult());

    // The drainer received exactly the same bytes.
    try std.testing.expect(drainer.err == null);
    try std.testing.expectEqual(content.len, drainer.total);
    try std.testing.expectEqualSlices(u8, &content, &recv_buf);
}

test "sendfile: NetSendFile honors the limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    const cwd = os.fs.cwd();

    const content = "the quick brown fox jumps over the lazy dog";
    var file_create = ev.FileCreate.init(cwd, "test-sendfile-limit", .{ .read = true, .truncate = true, .mode = 0o664 });
    loop.add(&file_create.c);
    try loop.run(.until_done);
    const file_fd = try file_create.getResult();
    defer {
        var file_close = ev.FileClose.init(file_fd);
        loop.add(&file_close.c);
        loop.run(.until_done) catch {};
        var del = ev.DirDeleteFile.init(cwd, "test-sendfile-limit");
        loop.add(&del.c);
        loop.run(.until_done) catch {};
    }

    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(file_fd, .fromSlice(content, &write_iov), 0);
    loop.add(&file_write.c);
    try loop.run(.until_done);

    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    const limit = 9; // "the quick"
    var recv_buf: [limit]u8 = undefined;
    var drainer = Drainer{ .sock = fds[1], .buf = &recv_buf };
    drainer.start(&loop);

    var send_file = ev.NetSendFile.init(fds[0], file_fd, 0, limit);
    loop.add(&send_file.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(@as(usize, limit), try send_file.getResult());
    try std.testing.expect(drainer.err == null);
    try std.testing.expectEqualSlices(u8, content[0..limit], &recv_buf);
}

test "sendfile: NetSendFile via blocking executeBlocking (no runtime)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const cwd = os.fs.cwd();

    const content = "blocking sendfile payload";

    var file_create = ev.FileCreate.init(cwd, "test-sendfile-blocking", .{ .read = true, .truncate = true, .mode = 0o664 });
    ev.executeBlocking(&file_create.c, allocator);
    const file_fd = try file_create.getResult();
    defer {
        var file_close = ev.FileClose.init(file_fd);
        ev.executeBlocking(&file_close.c, allocator);
        var del = ev.DirDeleteFile.init(cwd, "test-sendfile-blocking");
        ev.executeBlocking(&del.c, allocator);
    }

    var write_iov: [1]os.iovec_const = undefined;
    var file_write = ev.FileWrite.init(file_fd, .fromSlice(content, &write_iov), 0);
    ev.executeBlocking(&file_write.c, allocator);
    _ = try file_write.getResult();

    // Small payload fits the socket buffer, so a sequential send/recv on the
    // same thread does not deadlock.
    const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var send_file = ev.NetSendFile.init(fds[0], file_fd, 0, std.math.maxInt(usize));
    ev.executeBlocking(&send_file.c, allocator);
    try std.testing.expectEqual(content.len, try send_file.getResult());

    var recv_buf: [64]u8 = undefined;
    var recv_iov: [1]os.iovec = undefined;
    var recv = ev.NetRecv.init(fds[1], .fromSlice(&recv_buf, &recv_iov), .{});
    ev.executeBlocking(&recv.c, allocator);
    const n = try recv.getResult();
    try std.testing.expectEqualStrings(content, recv_buf[0..n]);
}
