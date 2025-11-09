const std = @import("std");
const Loop = @import("loop.zig").Loop;
const Timer = @import("completion.zig").Timer;
const Cancel = @import("completion.zig").Cancel;
const Async = @import("completion.zig").Async;
const NetClose = @import("completion.zig").NetClose;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const NetListen = @import("completion.zig").NetListen;
const NetAccept = @import("completion.zig").NetAccept;
const NetConnect = @import("completion.zig").NetConnect;
const NetRecv = @import("completion.zig").NetRecv;
const socket = @import("os/posix/socket.zig");

test {
    _ = @import("test/thread_pool.zig");
    _ = @import("test/stream_server.zig");
    _ = @import("test/dgram_server.zig");
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
    var timer: Timer = .init(timeout_ms);
    loop.add(&timer.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.completed, timer.c.state);
    // Allow 20ms tolerance (timers can be imprecise, especially with spurious wake-ups)
    try std.testing.expect(elapsed_ms >= timeout_ms - 5);
    try std.testing.expect(elapsed_ms <= timeout_ms + 20);
    std.log.info("timer: expected={}ms, actual={}ms", .{ timeout_ms, elapsed_ms });
}

test "Loop: timer cancel" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 100;
    var timer: Timer = .init(timeout_ms);
    loop.add(&timer.c);

    var cancel: Cancel = .init(&timer.c);
    loop.add(&cancel.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Timer should be canceled immediately, much faster than the timeout
    try std.testing.expectEqual(.completed, timer.c.state);
    try std.testing.expectEqual(.completed, cancel.c.state);
    try std.testing.expectError(error.Canceled, timer.c.getResult(.timer));
    try std.testing.expect(elapsed_ms < 50);
    std.log.info("timer cancel: elapsed={}ms", .{elapsed_ms});
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .tcp);
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
    var open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&open.c);
    try loop.run(.until_done);

    const sock = try open.c.getResult(.net_open);

    // Bind to localhost
    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: socket.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run(.until_done);

    try bind.c.getResult(.net_bind);

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: cancel net_accept" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.c.getResult(.net_open);

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: socket.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.c.getResult(.net_bind);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.c.getResult(.net_listen);

    // Start accept (will block waiting for connection)
    var accept_comp: NetAccept = .init(server_sock, null, null);
    loop.add(&accept_comp.c);

    // Run once to get accept into poll queue
    try loop.run(.once);
    try std.testing.expectEqual(.running, accept_comp.c.state);

    // Cancel the accept
    var cancel: Cancel = .init(&accept_comp.c);
    loop.add(&cancel.c);

    // Run until both complete
    try loop.run(.until_done);

    // Verify both completed
    try std.testing.expectEqual(.completed, accept_comp.c.state);
    try std.testing.expectEqual(.completed, cancel.c.state);

    // Verify accept got canceled error
    try std.testing.expectError(error.Canceled, accept_comp.getResult());

    // Close server socket
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: cancel net_recv" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create and setup server
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.c.getResult(.net_open);

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: socket.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.c.getResult(.net_bind);

    const port = std.mem.bigToNative(u16, addr.port);

    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.c.getResult(.net_listen);

    // Create client and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.c.getResult(.net_open);

    var accept_comp: NetAccept = .init(server_sock, null, null);
    loop.add(&accept_comp.c);

    const connect_addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var connect: NetConnect = .init(client_sock, @ptrCast(&connect_addr), @sizeOf(@TypeOf(connect_addr)));
    loop.add(&connect.c);

    try loop.run(.until_done);
    const accepted_sock = try accept_comp.getResult();
    try connect.getResult();

    // Start recv (will block waiting for data)
    var recv_buf: [128]u8 = undefined;
    var recv_iov = [_]socket.iovec{socket.iovecFromSlice(&recv_buf)};
    var recv: NetRecv = .init(accepted_sock, &recv_iov, .{});
    loop.add(&recv.c);

    // Run once to get recv into poll queue
    try loop.run(.once);

    // Only test cancellation if recv is actually waiting
    if (recv.c.state == .running) {
        // Cancel the recv
        var cancel: Cancel = .init(&recv.c);
        loop.add(&cancel.c);

        // Run until both complete
        try loop.run(.until_done);

        // Verify both completed
        try std.testing.expectEqual(.completed, recv.c.state);
        try std.testing.expectEqual(.completed, cancel.c.state);

        // Verify recv got canceled error
        try std.testing.expectError(error.Canceled, recv.getResult());
    } else {
        // Recv completed immediately, just finish the loop
        try loop.run(.until_done);
    }

    // Close sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
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
    try std.testing.expectEqual(.completed, async_handle.c.state);
    try async_handle.c.getResult(.async);
}

test "Loop: async notification - cross-thread" {
    const time = @import("time.zig");
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
            time.sleep(10);
            c.async_handle.notify();
        }
    }.notifyThread, .{&ctx});

    // Run loop - should block until notified
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, async_handle.c.state);
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
    try std.testing.expectEqual(.completed, async1.c.state);
    try std.testing.expectEqual(.completed, async2.c.state);
    try std.testing.expectEqual(.completed, async3.c.state);
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
    try std.testing.expectEqual(.completed, async_handle.c.state);

    // Re-arm for second notification
    async_handle = .init();
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run(.until_done);
    try std.testing.expectEqual(.completed, async_handle.c.state);
}
