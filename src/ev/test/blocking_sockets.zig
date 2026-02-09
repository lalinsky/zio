const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const blocking = @import("../blocking.zig");
const os = @import("../../os/root.zig");
const net = os.net;

test "Blocking sockets: basic smoke test" {
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
            .zero = [_]u8{0} ** 8,
        },
        .server_addr_len = @sizeOf(net.sockaddr.in),
        .server_ready = os.ResetEvent.init(),
    };

    // Server thread: open, bind, listen, accept, recv, close
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn serverFn(s: *SharedState) void {
            const alloc = std.testing.allocator;

            // Open server socket
            var open = ev.NetOpen.init(.ipv4, .stream, .ip, .{});
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
            var open = ev.NetOpen.init(.ipv4, .stream, .ip, .{});
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
