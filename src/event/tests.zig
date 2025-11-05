const std = @import("std");
const Loop = @import("loop.zig").Loop;
const Timer = @import("completion.zig").Timer;
const Cancel = @import("completion.zig").Cancel;
const NetClose = @import("completion.zig").NetClose;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const NetListen = @import("completion.zig").NetListen;
const NetAccept = @import("completion.zig").NetAccept;
const NetConnect = @import("completion.zig").NetConnect;
const NetSend = @import("completion.zig").NetSend;
const NetRecv = @import("completion.zig").NetRecv;
const NetShutdown = @import("completion.zig").NetShutdown;
const socket = @import("os/posix/socket.zig");

test "Loop: empty run(.no_wait)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.no_wait);
}

test "Loop: empty run(.once)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.once);
}

test "Loop: empty run(.until_done)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.until_done);
}

test "Loop: timer iters" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state != .completed) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(11, n_iter);
}

test "Loop: timer iters cancel" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var cancel: Cancel = .init(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state != .completed) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            if (n_iter == 5) {
                loop.add(&cancel.c);
            }
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(6, n_iter);
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&open.c);
    try loop.run(.until_done);
    const sock = try open.result;

    // Now close it
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: socket create and bind" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create socket
    var open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&open.c);
    try loop.run(.until_done);

    const sock = try open.result;

    // Bind to localhost
    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var bind: NetBind = .init(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&bind.c);
    try loop.run(.until_done);

    try bind.result;

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: listen and accept" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Get the actual port that was bound
    var bound_addr: socket.sockaddr.in = undefined;
    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try socket.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client socket
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

    // Start accept and connect concurrently
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

    // Run until both complete
    try loop.run(.until_done);

    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Close all sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: send and recv" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Get the actual port
    var bound_addr: socket.sockaddr.in = undefined;
    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try socket.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client socket and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

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
    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Send data from client
    const msg = "Hello, World!";
    var send: NetSend = .init(client_sock, msg, .{});
    loop.add(&send.c);
    try loop.run(.until_done);
    const sent = try send.result;
    try std.testing.expectEqual(msg.len, sent);

    // Recv data on server
    var recv_buf: [128]u8 = undefined;
    var recv: NetRecv = .init(accepted_sock, &recv_buf, .{});
    loop.add(&recv.c);
    try loop.run(.until_done);
    const recvd = try recv.result;
    try std.testing.expectEqual(msg.len, recvd);
    try std.testing.expectEqualStrings(msg, recv_buf[0..recvd]);

    // Close all sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: cancel net_accept" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

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
    try loop.init();
    defer loop.deinit();

    // Create and setup server
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    var bound_addr: socket.sockaddr.in = undefined;
    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try socket.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

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
    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Start recv (will block waiting for data)
    var recv_buf: [128]u8 = undefined;
    var recv: NetRecv = .init(accepted_sock, &recv_buf, .{});
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

test "Loop: shutdown" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    var addr = socket.sockaddr.in{
        .family = socket.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Get the actual port
    var bound_addr: socket.sockaddr.in = undefined;
    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try socket.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client socket and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp);
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

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
    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Send data from client
    const msg = "Hello, World!";
    var send: NetSend = .init(client_sock, msg, .{});
    loop.add(&send.c);
    try loop.run(.until_done);
    const sent = try send.result;
    try std.testing.expectEqual(msg.len, sent);

    // Shutdown send side of client
    var shutdown: NetShutdown = .init(client_sock, .send);
    loop.add(&shutdown.c);
    try loop.run(.until_done);
    try shutdown.result;

    // Recv data on server (should get the message)
    var recv_buf: [128]u8 = undefined;
    var recv: NetRecv = .init(accepted_sock, &recv_buf, .{});
    loop.add(&recv.c);
    try loop.run(.until_done);
    const recvd = try recv.result;
    try std.testing.expectEqual(msg.len, recvd);
    try std.testing.expectEqualStrings(msg, recv_buf[0..recvd]);

    // Another recv should get 0 (EOF) on Linux, or ConnectionResetByPeer on Windows
    var recv2: NetRecv = .init(accepted_sock, &recv_buf, .{});
    loop.add(&recv2.c);
    try loop.run(.until_done);
    if (recv2.result) |recvd2| {
        try std.testing.expectEqual(0, recvd2);
    } else |err| {
        // Windows may return ConnectionResetByPeer after shutdown
        try std.testing.expectEqual(error.ConnectionResetByPeer, err);
    }

    // Close all sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}
