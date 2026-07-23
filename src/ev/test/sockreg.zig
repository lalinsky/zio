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

// Whether `epoll_fd`'s interest list contains `target` (via /proc fdinfo).
fn epollListsTfd(epoll_fd: i32, target: i32) !bool {
    const linux = std.os.linux;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/proc/self/fdinfo/{d}", .{epoll_fd});
    const fd_rc = linux.open(path, .{}, 0);
    if (@as(isize, @bitCast(fd_rc)) < 0) return error.Unexpected;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var buf: [4096]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (@as(isize, @bitCast(n)) < 0) return error.Unexpected;
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "tfd:")) continue;
        var toks = std.mem.tokenizeScalar(u8, line[4..], ' ');
        const num = toks.next() orelse continue;
        if (std.fmt.parseInt(i32, num, 10) catch continue == target) return true;
    }
    return false;
}

// Closing a socket must deregister it from the poller that actually holds the
// registration - the owner loop's epoll - while the fd is still open. An epoll
// subscription is keyed to the file description and the fd is the only handle
// for removing it: if another reference (here a dup) keeps the description
// alive across the close, a registration left behind would be unremovable and
// fire events forever.
test "sockreg: close deregisters from the owner's epoll" {
    if (comptime backend != .epoll) {
        return error.SkipZigTest;
    } else {
        const linux = std.os.linux;

        const fds = try net.socketpair(.unix, .stream, .ip, .{ .nonblocking = true });
        var fd0_open = true;
        defer if (fd0_open) net.close(fds[0]);
        defer net.close(fds[1]);

        var group: LoopGroup = .{};

        // Loop B parks its own recv on fds[0], becoming the read-side owner.
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
                l.add(&recv.c);
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

        var loop_a: Loop = undefined;
        try loop_a.init(.{ .loop_group = &group });
        defer loop_a.deinit();

        try std.testing.expect(try epollListsTfd(loop_b.backend.epoll_fd, fds[0]));

        // Keep the file description alive across the close, so kernel
        // close-time eviction cannot clean B's epoll for us.
        const dup_rc = linux.dup(fds[0]);
        try std.testing.expect(@as(isize, @bitCast(dup_rc)) >= 0);
        const duped: i32 = @intCast(dup_rc);
        defer _ = linux.close(duped);

        // Drain B's parked op (close contract), then close fds[0] from loop A:
        // sockreg.unregister must CTL_DEL on the owner's (B's) epoll.
        loop_a.cancel(&b_recv.c);
        while (!b_fired.load(.acquire)) std.Thread.yield() catch {};

        var close_op = @import("../completion.zig").NetClose.init(fds[0]);
        loop_a.add(&close_op.c);
        fd0_open = false;
        try loop_a.run(.no_wait);

        try std.testing.expect(!try epollListsTfd(loop_b.backend.epoll_fd, fds[0]));
    }
}
