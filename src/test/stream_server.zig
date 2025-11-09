const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const Backend = @import("../backend.zig").Backend;
const Completion = @import("../completion.zig").Completion;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetAccept = @import("../completion.zig").NetAccept;
const NetConnect = @import("../completion.zig").NetConnect;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetShutdown = @import("../completion.zig").NetShutdown;
const NetClose = @import("../completion.zig").NetClose;
const socket = @import("../os/posix/socket.zig");
const time = @import("../time.zig");

pub fn EchoServer(comptime domain: socket.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *Loop,

        // Server socket
        server_sock: Backend.NetHandle = undefined,
        server_addr: sockaddr,
        server_addr_len: socket.socklen_t,

        // Client socket
        client_sock: ?Backend.NetHandle = null,

        // Union of completions - only one active at a time
        comp: union {
            open: NetOpen,
            bind: NetBind,
            listen: NetListen,
            accept: NetAccept,
            recv: NetRecv,
            send: NetSend,
            close_client: NetClose,
            close_server: NetClose,
        },

        // Buffer for echo
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]socket.iovec = undefined,
        send_iov: [1]socket.iovec_const = undefined,
        bytes_received: usize = 0,
        bytes_sent: usize = 0,

        pub const State = enum {
            init,
            opening,
            binding,
            listening,
            accepting,
            receiving,
            sending,
            closing_client,
            closing_server,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *Loop) Self {
            var self: Self = .{
                .loop = loop,
                .server_addr = undefined,
                .server_addr_len = @sizeOf(sockaddr),
                .comp = undefined,
            };

            switch (domain) {
                .ipv4 => {
                    self.server_addr = .{
                        .family = socket.AF.INET,
                        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
                        .port = 0,
                        .zero = [_]u8{0} ** 8,
                    };
                },
                .ipv6 => {
                    self.server_addr = .{
                        .family = socket.AF.INET6,
                        .addr = [_]u8{0} ** 15 ++ [_]u8{1},
                        .port = 0,
                        .flowinfo = 0,
                        .scope_id = 0,
                    };
                },
                .unix => {
                    self.server_addr = .{
                        .family = socket.AF.UNIX,
                        .path = undefined,
                    };
                    const timestamp = time.now(.realtime);
                    _ = std.fmt.bufPrintZ(&self.server_addr.path, "/tmp/zevent-test-{d}.sock", .{timestamp}) catch unreachable;
                },
            }

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            const protocol: socket.Protocol = if (domain == .unix) .default else .tcp;
            self.comp = .{ .open = NetOpen.init(domain, .stream, protocol) };
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.server_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .binding;
            self.comp = .{ .bind = NetBind.init(
                self.server_sock,
                @ptrCast(&self.server_addr),
                &self.server_addr_len,
            ) };
            self.comp.bind.c.callback = bindCallback;
            self.comp.bind.c.userdata = self;
            loop.add(&self.comp.bind.c);
        }

        fn bindCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.bind.c.getResult(.net_bind) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .listening;
            self.comp = .{ .listen = NetListen.init(self.server_sock, 1) };
            self.comp.listen.c.callback = listenCallback;
            self.comp.listen.c.userdata = self;
            loop.add(&self.comp.listen.c);
        }

        fn listenCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.listen.c.getResult(.net_listen) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .accepting;
            self.comp = .{ .accept = NetAccept.init(self.server_sock, null, null) };
            self.comp.accept.c.callback = acceptCallback;
            self.comp.accept.c.userdata = self;
            loop.add(&self.comp.accept.c);
        }

        fn acceptCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.client_sock = self.comp.accept.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .receiving;
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(&self.recv_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock.?, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn recvCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.bytes_received = self.comp.recv.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Check for EOF (0 bytes received)
            if (self.bytes_received == 0) {
                self.state = .closing_client;
                self.comp = .{ .close_client = NetClose.init(self.client_sock.?) };
                self.comp.close_client.c.callback = closeClientCallback;
                self.comp.close_client.c.userdata = self;
                loop.add(&self.comp.close_client.c);
                return;
            }

            self.state = .sending;
            self.bytes_sent = 0;
            const send_buf = self.recv_buf[0..self.bytes_received];
            self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(send_buf)};
            self.comp = .{ .send = NetSend.init(self.client_sock.?, &self.send_iov, .{}) };
            self.comp.send.c.callback = sendCallback;
            self.comp.send.c.userdata = self;
            loop.add(&self.comp.send.c);
        }

        fn sendCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            const bytes_written = self.comp.send.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.bytes_sent += bytes_written;

            // Check if we've sent everything
            if (self.bytes_sent < self.bytes_received) {
                // Partial write - continue sending remaining data
                const remaining = self.recv_buf[self.bytes_sent..self.bytes_received];
                self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(remaining)};
                self.comp = .{ .send = NetSend.init(self.client_sock.?, &self.send_iov, .{}) };
                self.comp.send.c.callback = sendCallback;
                self.comp.send.c.userdata = self;
                loop.add(&self.comp.send.c);
                return;
            }

            // Full message sent - go back to receiving to check for EOF or more data
            self.state = .receiving;
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(&self.recv_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock.?, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn closeClientCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close_client.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .closing_server;
            self.comp = .{ .close_server = NetClose.init(self.server_sock) };
            self.comp.close_server.c.callback = closeServerCallback;
            self.comp.close_server.c.userdata = self;
            loop.add(&self.comp.close_server.c);
        }

        fn closeServerCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close_server.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .done;
        }
    };
}

pub fn EchoClient(comptime domain: socket.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *Loop,

        client_sock: Backend.NetHandle = undefined,
        connect_addr: sockaddr,

        // Union of completions - only one active at a time
        comp: union {
            open: NetOpen,
            connect: NetConnect,
            send: NetSend,
            shutdown: NetShutdown,
            recv: NetRecv,
            close: NetClose,
        },

        // Buffers
        send_buf: []const u8,
        send_iov: [1]socket.iovec_const = undefined,
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]socket.iovec = undefined,
        bytes_sent: usize = 0,
        bytes_received: usize = 0,

        pub const State = enum {
            init,
            opening,
            connecting,
            sending,
            shutting_down,
            receiving,
            closing,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *Loop, server_addr: sockaddr, message: []const u8) Self {
            var self: Self = .{
                .loop = loop,
                .connect_addr = server_addr,
                .send_buf = message,
                .comp = undefined,
            };

            const protocol: socket.Protocol = if (domain == .unix) .default else .tcp;
            self.comp = .{ .open = NetOpen.init(domain, .stream, protocol) };

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.client_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .connecting;
            self.comp = .{ .connect = NetConnect.init(
                self.client_sock,
                @ptrCast(&self.connect_addr),
                @sizeOf(sockaddr),
            ) };
            self.comp.connect.c.callback = connectCallback;
            self.comp.connect.c.userdata = self;
            loop.add(&self.comp.connect.c);
        }

        fn connectCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.connect.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .sending;
            self.bytes_sent = 0;
            self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(self.send_buf)};
            self.comp = .{ .send = NetSend.init(self.client_sock, &self.send_iov, .{}) };
            self.comp.send.c.callback = sendCallback;
            self.comp.send.c.userdata = self;
            loop.add(&self.comp.send.c);
        }

        fn sendCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            const bytes_written = self.comp.send.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.bytes_sent += bytes_written;

            // Check if we've sent everything
            if (self.bytes_sent < self.send_buf.len) {
                // Partial write - continue sending remaining data
                const remaining = self.send_buf[self.bytes_sent..];
                self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(remaining)};
                self.comp = .{ .send = NetSend.init(self.client_sock, &self.send_iov, .{}) };
                self.comp.send.c.callback = sendCallback;
                self.comp.send.c.userdata = self;
                loop.add(&self.comp.send.c);
                return;
            }

            // All data sent - shutdown send side to signal end of data
            self.state = .shutting_down;
            self.comp = .{ .shutdown = NetShutdown.init(self.client_sock, .send) };
            self.comp.shutdown.c.callback = shutdownCallback;
            self.comp.shutdown.c.userdata = self;
            loop.add(&self.comp.shutdown.c);
        }

        fn shutdownCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.shutdown.c.getResult(.net_shutdown) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .receiving;
            self.bytes_received = 0;
            // Start reading into the beginning of recv_buf
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(&self.recv_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn recvCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            const bytes_read = self.comp.recv.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Check for EOF (0 bytes received)
            if (bytes_read == 0) {
                self.state = .closing;
                self.comp = .{ .close = NetClose.init(self.client_sock) };
                self.comp.close.c.callback = closeCallback;
                self.comp.close.c.userdata = self;
                loop.add(&self.comp.close.c);
                return;
            }

            // Accumulate bytes received
            self.bytes_received += bytes_read;

            // Continue reading - re-arm NetRecv to drain the full echo
            // Read into the buffer starting after what we've already received
            const remaining_buf = self.recv_buf[self.bytes_received..];
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(remaining_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn closeCallback(loop: *Loop, c: *Completion) void {
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

fn testEcho(comptime domain: socket.Domain, comptime sockaddr: type) !void {
    var loop: Loop = undefined;
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

    // Run loop until server reaches accepting state
    var iterations: usize = 0;
    while (server.state != .accepting and server.state != .failed) {
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
    client.start();

    // Run until both are done
    try loop.run(.until_done);

    // Verify results
    try std.testing.expectEqual(.done, server.state);
    try std.testing.expectEqual(.done, client.state);
    try std.testing.expectEqual(message.len, client.bytes_received);
    try std.testing.expectEqualStrings(message, client.recv_buf[0..client.bytes_received]);
}

test "Echo server and client - IPv4 TCP" {
    try testEcho(.ipv4, socket.sockaddr.in);
}

test "Echo server and client - IPv6 TCP" {
    try testEcho(.ipv6, socket.sockaddr.in6);
}

test "Echo server and client - Unix stream" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testEcho(.unix, socket.sockaddr.un);
}
