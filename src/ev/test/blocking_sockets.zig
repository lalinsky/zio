const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const blocking = @import("../blocking.zig");
const os = @import("../../os/root.zig");
const net = os.net;

test "Blocking sockets: basic smoke test" {
    // Normally done by Loop.init; this test bypasses the loop and uses
    // blocking ops directly from raw threads.
    net.ensureWSAInitialized();

    // Shared state between threads
    const SharedState = struct {
        server_addr: net.sockaddr.in,
        server_addr_len: net.socklen_t,
        server_ready: os.ResetEvent,
        server_err: ?anyerror = null,
        client_err: ?anyerror = null,
    };

    var state = SharedState{
        .server_addr = net.sockaddr.in{
            .family = net.AF.INET,
            .port = 0,
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            .zero = @splat(0),
        },
        .server_addr_len = @sizeOf(net.sockaddr.in),
        .server_ready = os.ResetEvent.init(),
    };

    // Server thread: open, bind, listen, accept, recv, close
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn serverFn(s: *SharedState) void {
            const alloc = std.testing.allocator;

            // Open server socket
            var open = ev.NetOpen.init(.ipv4, .stream, .ip, .{ .nonblocking = false });
            blocking.executeBlocking(&open.c, alloc);
            const server_sock = open.c.getResult(.net_open) catch |err| {
                s.server_err = err;
                s.server_ready.set();
                return;
            };
            defer {
                var close = ev.NetClose.init(server_sock);
                blocking.executeBlocking(&close.c, alloc);
                _ = close.c.getResult(.net_close) catch {};
            }

            // Bind
            var bind = ev.NetBind.init(server_sock, @ptrCast(&s.server_addr), &s.server_addr_len);
            blocking.executeBlocking(&bind.c, alloc);
            bind.c.getResult(.net_bind) catch |err| {
                s.server_err = err;
                s.server_ready.set();
                return;
            };

            // Listen
            var listen = ev.NetListen.init(server_sock, 1);
            blocking.executeBlocking(&listen.c, alloc);
            listen.c.getResult(.net_listen) catch |err| {
                s.server_err = err;
                s.server_ready.set();
                return;
            };

            // Signal that server is ready to accept connections
            s.server_ready.set();

            // Accept
            var accept = ev.NetAccept.init(server_sock, null, null);
            blocking.executeBlocking(&accept.c, alloc);
            const client_sock = accept.getResult() catch |err| {
                s.server_err = err;
                return;
            };
            defer {
                var close = ev.NetClose.init(client_sock);
                blocking.executeBlocking(&close.c, alloc);
                _ = close.c.getResult(.net_close) catch {};
            }

            // Receive message
            var recv_buf: [128]u8 = undefined;
            var recv_iov: [1]os.iovec = undefined;
            var recv = ev.NetRecv.init(client_sock, .fromSlice(&recv_buf, &recv_iov), .{});
            blocking.executeBlocking(&recv.c, alloc);
            const bytes_received = recv.getResult() catch |err| {
                s.server_err = err;
                return;
            };

            // Verify received message
            const expected = "Hello, blocking sockets!";
            if (bytes_received != expected.len or !std.mem.eql(u8, recv_buf[0..bytes_received], expected)) {
                s.server_err = error.MessageMismatch;
            }
        }
    }.serverFn, .{&state});

    // Client thread: wait for server, then open, connect, send, close
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn clientFn(s: *SharedState) void {
            const alloc = std.testing.allocator;

            // Wait for server to be ready
            s.server_ready.wait();

            // Check if server setup failed
            if (s.server_err) |_| return;

            // Open client socket
            var open = ev.NetOpen.init(.ipv4, .stream, .ip, .{ .nonblocking = false });
            blocking.executeBlocking(&open.c, alloc);
            const client_sock = open.c.getResult(.net_open) catch |err| {
                s.client_err = err;
                return;
            };
            defer {
                var close = ev.NetClose.init(client_sock);
                blocking.executeBlocking(&close.c, alloc);
                _ = close.c.getResult(.net_close) catch {};
            }

            // Connect
            var connect = ev.NetConnect.init(client_sock, @ptrCast(&s.server_addr), s.server_addr_len);
            blocking.executeBlocking(&connect.c, alloc);
            connect.getResult() catch |err| {
                s.client_err = err;
                return;
            };

            // Send message
            const message = "Hello, blocking sockets!";
            var send_iov: [1]os.iovec_const = undefined;
            var send = ev.NetSend.init(client_sock, .fromSlice(message, &send_iov), .{});
            blocking.executeBlocking(&send.c, alloc);
            const bytes_sent = send.getResult() catch |err| {
                s.client_err = err;
                return;
            };

            if (bytes_sent != message.len) {
                s.client_err = error.IncompleteSend;
            }
        }
    }.clientFn, .{&state});

    // Wait for both threads to complete
    server_thread.join();
    client_thread.join();

    // Check for errors
    try std.testing.expectEqual(null, state.server_err);
    try std.testing.expectEqual(null, state.client_err);
}

test "Blocking sockets: recv on a nonblocking socket waits for data" {
    // NetAccept hands back a nonblocking socket by default (the event loop
    // wants that), so the blocking executor cannot assume its handles are in
    // blocking mode: a recv that arrives before the peer's send must poll
    // and wait, not surface WouldBlock. The ordering here is deterministic:
    // the sender only transmits after the receiver is already parked in
    // executeBlocking.
    net.ensureWSAInitialized();

    const alloc = std.testing.allocator;

    // Listener, blocking mode, on an ephemeral loopback port.
    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = @splat(0),
    };
    var addr_len: net.socklen_t = @sizeOf(net.sockaddr.in);

    var open = ev.NetOpen.init(.ipv4, .stream, .ip, .{ .nonblocking = false });
    blocking.executeBlocking(&open.c, alloc);
    const listener = try open.c.getResult(.net_open);
    defer {
        var close = ev.NetClose.init(listener);
        blocking.executeBlocking(&close.c, alloc);
        _ = close.c.getResult(.net_close) catch {};
    }

    var bind = ev.NetBind.init(listener, @ptrCast(&addr), &addr_len);
    blocking.executeBlocking(&bind.c, alloc);
    try bind.c.getResult(.net_bind);

    var listen = ev.NetListen.init(listener, 1);
    blocking.executeBlocking(&listen.c, alloc);
    try listen.c.getResult(.net_listen);

    // Client connects; loopback connect completes without an accept.
    var copen = ev.NetOpen.init(.ipv4, .stream, .ip, .{ .nonblocking = false });
    blocking.executeBlocking(&copen.c, alloc);
    const client = try copen.c.getResult(.net_open);
    defer {
        var close = ev.NetClose.init(client);
        blocking.executeBlocking(&close.c, alloc);
        _ = close.c.getResult(.net_close) catch {};
    }

    var connect = ev.NetConnect.init(client, @ptrCast(&addr), addr_len);
    blocking.executeBlocking(&connect.c, alloc);
    try connect.getResult();

    // Accept with the default flags: the accepted socket is nonblocking.
    var accept = ev.NetAccept.init(listener, null, null);
    blocking.executeBlocking(&accept.c, alloc);
    const accepted = try accept.getResult();
    defer {
        var close = ev.NetClose.init(accepted);
        blocking.executeBlocking(&close.c, alloc);
        _ = close.c.getResult(.net_close) catch {};
    }

    // The send happens strictly after this thread is inside the recv.
    const sender = try std.Thread.spawn(.{}, struct {
        fn sendLate(sock: net.fd_t) void {
            os.time.sleep(.fromMilliseconds(50));
            var iov: [1]os.iovec_const = undefined;
            var send = ev.NetSend.init(sock, .fromSlice("late data", &iov), .{});
            blocking.executeBlocking(&send.c, std.testing.allocator);
            _ = send.getResult() catch {};
        }
    }.sendLate, .{client});
    defer sender.join();

    var buf: [32]u8 = undefined;
    var iov: [1]os.iovec = undefined;
    var recv = ev.NetRecv.init(accepted, .fromSlice(&buf, &iov), .{});
    blocking.executeBlocking(&recv.c, alloc);
    const n = try recv.getResult();
    try std.testing.expectEqualStrings("late data", buf[0..n]);
}
