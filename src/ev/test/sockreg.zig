const std = @import("std");
const backend = @import("../backend.zig").backend;
const Loop = @import("../loop.zig").Loop;
const LoopGroup = @import("../loop.zig").LoopGroup;
const Completion = @import("../completion.zig").Completion;
const NetRecv = @import("../completion.zig").NetRecv;
const ReadBuf = @import("../buf.zig").ReadBuf;
const net = @import("../../os/net.zig");
const os = @import("../../os/root.zig");

fn setFlagCallback(_: *Loop, c: *Completion) void {
    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(c.userdata.?));
    flag.store(true, .release);
}

// A socket op submitted on loop A but parked on the fd's owner loop B is
// produced by B's poller: B's inflight must count it and A's must not (A has
// nothing to poll for), while A's active keeps A's until_done open (A stays
// the op's home). Also exercises the cancel path: a detach from the
// non-owner loop must drop the owner's count.
test "sockreg: cross-loop park counts inflight on the owner loop" {
    if (backend != .epoll and backend != .kqueue) return error.SkipZigTest;

    const fds = net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true }) catch |err| switch (err) {
        error.OperationUnsupported => return error.SkipZigTest,
        else => return err,
    };
    defer net.close(fds[0]);
    defer net.close(fds[1]);

    var group: LoopGroup = .{};

    // Loop B lives on its own thread: it inits there (init and tick are
    // same-thread by contract), parks its own recv on fds[0] - becoming the
    // read-side owner - and then services the fd for everyone.
    var loop_b: Loop = undefined;
    var b_fired = std.atomic.Value(bool).init(false);
    var b_recv_buf: [1]u8 = undefined;
    var b_recv_iov: [1]os.iovec = undefined;
    var b_recv: NetRecv = undefined;
    var ready = std.atomic.Value(bool).init(false);
    var stop = std.atomic.Value(bool).init(false);

    const Runner = struct {
        fn run(
            l: *Loop,
            g: *LoopGroup,
            recv: *NetRecv,
            buf: []u8,
            iov: []os.iovec,
            fd: net.fd_t,
            fired: *std.atomic.Value(bool),
            r: *std.atomic.Value(bool),
            s: *std.atomic.Value(bool),
        ) void {
            l.init(.{ .loop_group = g }) catch @panic("loop init failed");
            recv.* = NetRecv.init(fd, ReadBuf.fromSlice(buf, iov), .{});
            recv.c.userdata = fired;
            recv.c.callback = setFlagCallback;
            l.add(&recv.c); // no data yet -> parks, B owns (fd, read)
            r.store(true, .release);
            while (!s.load(.acquire)) {
                l.run(.once) catch return;
            }
        }
    };
    const runner = try std.Thread.spawn(.{}, Runner.run, .{
        &loop_b, &group, &b_recv, &b_recv_buf, &b_recv_iov, fds[0], &b_fired, &ready, &stop,
    });
    defer loop_b.deinit();
    defer runner.join();
    defer {
        stop.store(true, .release);
        loop_b.wake();
    }
    while (!ready.load(.acquire)) std.Thread.yield() catch {};

    // Loop A on this thread, same group. It never needs to run: its op is
    // serviced by B.
    var loop_a: Loop = undefined;
    try loop_a.init(.{ .loop_group = &group });
    defer loop_a.deinit();

    try std.testing.expect(loop_b.backend.hasInflight());
    try std.testing.expect(!loop_a.backend.hasInflight());

    // Submit a recv on the B-owned fd from A: the optimistic syscall sees no
    // data and the op parks on B.
    var a_fired = std.atomic.Value(bool).init(false);
    var a_recv_buf: [1]u8 = undefined;
    var a_recv_iov: [1]os.iovec = undefined;
    var a_recv = NetRecv.init(fds[0], ReadBuf.fromSlice(&a_recv_buf, &a_recv_iov), .{});
    a_recv.c.userdata = &a_fired;
    a_recv.c.callback = setFlagCallback;
    loop_a.add(&a_recv.c);

    // A stays the home loop (active holds its until_done open), but the op is
    // produced by B's poller: only B has it inflight.
    try std.testing.expectEqual(1, loop_a.state.loadActive());
    try std.testing.expect(!loop_a.backend.hasInflight());
    try std.testing.expect(loop_b.backend.hasInflight());

    // Two bytes, one per 1-byte recv buffer: one readiness edge on B services
    // both waiters (B's own and A's).
    var send_iov = [1]os.iovec_const{os.iovecConstFromSlice("ab")};
    _ = try net.send(fds[1], &send_iov, .{});

    while (!b_fired.load(.acquire) or !a_fired.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(1, try b_recv.getResult());
    try std.testing.expectEqual(1, try a_recv.getResult());
    try std.testing.expect(!loop_b.backend.hasInflight());
    try std.testing.expectEqual(0, loop_a.state.loadActive());

    // Cancel path: park another recv from A on B, cancel it from here (the
    // thread driving A). The detach runs against B's waiter queue and must
    // drop B's count.
    var c_fired = std.atomic.Value(bool).init(false);
    var c_recv_buf: [1]u8 = undefined;
    var c_recv_iov: [1]os.iovec = undefined;
    var c_recv = NetRecv.init(fds[0], ReadBuf.fromSlice(&c_recv_buf, &c_recv_iov), .{});
    c_recv.c.userdata = &c_fired;
    c_recv.c.callback = setFlagCallback;
    loop_a.add(&c_recv.c);
    try std.testing.expect(loop_b.backend.hasInflight());

    loop_a.cancel(&c_recv.c);
    // The canceled completion is dispatched on its home loop's completions
    // queue (defer_callback defaults to true at the ev level); one no-wait
    // tick of A delivers it. A's backend has nothing inflight, so this must
    // not need (or make) a poll syscall.
    try loop_a.run(.no_wait);
    try std.testing.expect(c_fired.load(.acquire));
    try std.testing.expectError(error.Canceled, c_recv.getResult());
    try std.testing.expect(!loop_b.backend.hasInflight());
    try std.testing.expectEqual(0, loop_a.state.loadActive());
}
