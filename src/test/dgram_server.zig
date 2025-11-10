const std = @import("std");
const builtin = @import("builtin");
const aio = @import("../root.zig");
const net = aio.system.net;
const time = aio.system.time;

pub fn EchoServer(comptime domain: net.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *aio.Loop,

        // Server socket
        server_sock: aio.Backend.NetHandle = undefined,
        server_addr: sockaddr,
        server_addr_len: net.socklen_t,

        // Client address
        client_addr: sockaddr = undefined,
        client_addr_len: net.socklen_t = undefined,

        // Union of completions - only one active at a time
        comp: union {
            open: aio.NetOpen,
            bind: aio.NetBind,
            recvfrom: aio.NetRecvFrom,
            sendto: aio.NetSendTo,
            close: aio.NetClose,
        },

        // Buffer for echo
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]net.iovec = undefined,
        send_iov: [1]net.iovec_const = undefined,
        bytes_received: usize = 0,

        pub const State = enum {
            init,
            opening,
            binding,
            receiving,
            sending,
            closing,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *aio.Loop) Self {
            var self: Self = .{
                .loop = loop,
                .server_addr = undefined,
                .server_addr_len = @sizeOf(sockaddr),
                .comp = undefined,
            };

            switch (domain) {
                .ipv4 => {
                    self.server_addr = .{
                        .family = net.AF.INET,
                        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
                        .port = 0,
                        .zero = [_]u8{0} ** 8,
                    };
                },
                .ipv6 => {
                    self.server_addr = .{
                        .family = net.AF.INET6,
                        .addr = [_]u8{0} ** 15 ++ [_]u8{1},
                        .port = 0,
                        .flowinfo = 0,
                        .scope_id = 0,
                    };
                },
                .unix => {
                    self.server_addr = .{
                        .family = net.AF.UNIX,
                        .path = undefined,
                    };
                    const timestamp = time.now(.realtime);
                    _ = std.fmt.bufPrintZ(&self.server_addr.path, "/tmp/zevent-dgram-test-{d}.sock", .{timestamp}) catch unreachable;
                },
            }

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            const protocol: net.Protocol = if (domain == .unix) .default else .udp;
            self.comp = .{ .open = aio.NetOpen.init(domain, .dgram, protocol) };
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.server_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .binding;
            self.comp = .{ .bind = aio.NetBind.init(
                self.server_sock,
                @ptrCast(&self.server_addr),
                &self.server_addr_len,
            ) };
            self.comp.bind.c.callback = bindCallback;
            self.comp.bind.c.userdata = self;
            loop.add(&self.comp.bind.c);
        }

        fn bindCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.bind.c.getResult(.net_bind) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start receiving
            self.state = .receiving;
            self.recv_iov = [_]net.iovec{net.iovecFromSlice(&self.recv_buf)};
            self.client_addr_len = @sizeOf(sockaddr);
            self.comp = .{ .recvfrom = aio.NetRecvFrom.init(self.server_sock, &self.recv_iov, .{}, @ptrCast(&self.client_addr), &self.client_addr_len) };
            self.comp.recvfrom.c.callback = recvCallback;
            self.comp.recvfrom.c.userdata = self;
            loop.add(&self.comp.recvfrom.c);
        }

        fn recvCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.bytes_received = self.comp.recvfrom.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Echo back to sender
            self.state = .sending;
            const send_buf = self.recv_buf[0..self.bytes_received];
            self.send_iov = [_]net.iovec_const{net.iovecConstFromSlice(send_buf)};
            self.comp = .{ .sendto = aio.NetSendTo.init(self.server_sock, &self.send_iov, .{}, @ptrCast(&self.client_addr), self.client_addr_len) };
            self.comp.sendto.c.callback = sendCallback;
            self.comp.sendto.c.userdata = self;
            loop.add(&self.comp.sendto.c);
        }

        fn sendCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            _ = self.comp.sendto.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Close server socket
            self.state = .closing;
            self.comp = .{ .close = aio.NetClose.init(self.server_sock) };
            self.comp.close.c.callback = closeCallback;
            self.comp.close.c.userdata = self;
            loop.add(&self.comp.close.c);
        }

        fn closeCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .done;
        }
    };
}

pub fn EchoClient(comptime domain: net.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *aio.Loop,

        client_sock: aio.Backend.NetHandle = undefined,
        client_addr: sockaddr = undefined,
        client_addr_len: net.socklen_t = undefined,
        server_addr: sockaddr,

        // Union of completions - only one active at a time
        comp: union {
            open: aio.NetOpen,
            bind: aio.NetBind,
            sendto: aio.NetSendTo,
            recvfrom: aio.NetRecvFrom,
            close: aio.NetClose,
        },

        // Buffers
        send_buf: []const u8,
        send_iov: [1]net.iovec_const = undefined,
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]net.iovec = undefined,
        recv_addr: sockaddr = undefined,
        recv_addr_len: net.socklen_t = undefined,
        bytes_received: usize = 0,

        pub const State = enum {
            init,
            opening,
            binding,
            sending,
            receiving,
            closing,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *aio.Loop, server_addr: sockaddr, message: []const u8) Self {
            var self: Self = .{
                .loop = loop,
                .server_addr = server_addr,
                .send_buf = message,
                .comp = undefined,
            };

            // For Unix domain sockets, client needs to bind to a path too
            if (domain == .unix) {
                self.client_addr = .{
                    .family = net.AF.UNIX,
                    .path = undefined,
                };
                const timestamp = time.now(.realtime);
                _ = std.fmt.bufPrintZ(&self.client_addr.path, "/tmp/zevent-dgram-client-{d}.sock", .{timestamp}) catch unreachable;
                self.client_addr_len = @sizeOf(sockaddr);
            }

            const protocol: net.Protocol = if (domain == .unix) .default else .udp;
            self.comp = .{ .open = aio.NetOpen.init(domain, .dgram, protocol) };

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.client_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // For Unix domain sockets, bind client to a path
            if (domain == .unix) {
                self.state = .binding;
                self.comp = .{ .bind = aio.NetBind.init(
                    self.client_sock,
                    @ptrCast(&self.client_addr),
                    &self.client_addr_len,
                ) };
                self.comp.bind.c.callback = bindCallback;
                self.comp.bind.c.userdata = self;
                loop.add(&self.comp.bind.c);
            } else {
                // Start send directly for IP sockets
                self.state = .sending;
                self.send_iov = [_]net.iovec_const{net.iovecConstFromSlice(self.send_buf)};
                self.comp = .{ .sendto = aio.NetSendTo.init(self.client_sock, &self.send_iov, .{}, @ptrCast(&self.server_addr), @sizeOf(sockaddr)) };
                self.comp.sendto.c.callback = sendCallback;
                self.comp.sendto.c.userdata = self;
                loop.add(&self.comp.sendto.c);
            }
        }

        fn bindCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.bind.c.getResult(.net_bind) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start send
            self.state = .sending;
            self.send_iov = [_]net.iovec_const{net.iovecConstFromSlice(self.send_buf)};
            self.comp = .{ .sendto = aio.NetSendTo.init(self.client_sock, &self.send_iov, .{}, @ptrCast(&self.server_addr), @sizeOf(sockaddr)) };
            self.comp.sendto.c.callback = sendCallback;
            self.comp.sendto.c.userdata = self;
            loop.add(&self.comp.sendto.c);
        }

        fn sendCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            _ = self.comp.sendto.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start recv
            self.state = .receiving;
            self.recv_iov = [_]net.iovec{net.iovecFromSlice(&self.recv_buf)};
            self.recv_addr_len = @sizeOf(sockaddr);
            self.comp = .{ .recvfrom = aio.NetRecvFrom.init(self.client_sock, &self.recv_iov, .{}, @ptrCast(&self.recv_addr), &self.recv_addr_len) };
            self.comp.recvfrom.c.callback = recvCallback;
            self.comp.recvfrom.c.userdata = self;
            loop.add(&self.comp.recvfrom.c);
        }

        fn recvCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.bytes_received = self.comp.recvfrom.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Close socket
            self.state = .closing;
            self.comp = .{ .close = aio.NetClose.init(self.client_sock) };
            self.comp.close.c.callback = closeCallback;
            self.comp.close.c.userdata = self;
            loop.add(&self.comp.close.c);
        }

        fn closeCallback(loop: *aio.Loop, c: *aio.Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .done;
        }
    };
}

fn testEcho(comptime domain: net.Domain, comptime sockaddr: type) !void {
    var loop: aio.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Server = EchoServer(domain, sockaddr);
    const Client = EchoClient(domain, sockaddr);

    // Start server
    var server = Server.init(&loop);
    defer {
        if (domain == .unix) {
            const path = std.mem.sliceTo(&server.server_addr.path, 0);
            std.fs.deleteFileAbsolute(path) catch {};
        }
    }
    server.start();

    // Run loop until server reaches receiving state
    var iterations: usize = 0;
    while (server.state != .receiving and server.state != .failed) {
        try loop.run(.once);
        iterations += 1;
        if (iterations > 100) {
            return error.Timeout;
        }
    }

    if (server.state == .failed) {
        return error.ServerSetupFailed;
    }

    // Start client
    const message = "Hello, Echo Server!";
    var client = Client.init(&loop, server.server_addr, message);
    defer {
        if (domain == .unix) {
            const path = std.mem.sliceTo(&client.client_addr.path, 0);
            std.fs.deleteFileAbsolute(path) catch {};
        }
    }
    client.start();

    // Run until both are done
    try loop.run(.until_done);

    // Verify results
    try std.testing.expectEqual(.done, server.state);
    try std.testing.expectEqual(.done, client.state);
    try std.testing.expectEqual(message.len, client.bytes_received);
    try std.testing.expectEqualStrings(message, client.recv_buf[0..client.bytes_received]);
}

test "Echo server and client - IPv4 UDP" {
    try testEcho(.ipv4, net.sockaddr.in);
}

test "Echo server and client - IPv6 UDP" {
    try testEcho(.ipv6, net.sockaddr.in6);
}

test "Echo server and client - Unix datagram" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testEcho(.unix, net.sockaddr.un);
}
