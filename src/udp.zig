const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const AnyTask = @import("runtime.zig").AnyTask;
const resumeTask = @import("runtime.zig").resumeTask;
const runIo = @import("io/base.zig").runIo;
const meta = @import("meta.zig");

const TEST_PORT = 45001;

const Handle = if (xev.backend == .iocp) std.os.windows.HANDLE else std.posix.socket_t;

fn createDatagramSocket(family: std.posix.sa_family_t) !Handle {
    if (builtin.os.tag == .windows) {
        return try std.os.windows.WSASocketW(family, std.posix.SOCK.DGRAM, 0, null, 0, std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED);
    } else {
        var flags: u32 = std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC;
        if (xev.backend != .io_uring) flags |= std.posix.SOCK.NONBLOCK;
        return try std.posix.socket(family, flags, 0);
    }
}

fn addressFromStorage(data: []const u8) std.net.Address {
    const sockaddr: *align(1) const std.posix.sockaddr = @ptrCast(data.ptr);
    return switch (sockaddr.family) {
        std.posix.AF.INET => blk: {
            var addr: std.net.Address = .{ .in = undefined };
            @memcpy(std.mem.asBytes(&addr.in), data[0..@sizeOf(std.net.Ip4Address)]);
            break :blk addr;
        },
        std.posix.AF.INET6 => blk: {
            var addr: std.net.Address = .{ .in6 = undefined };
            @memcpy(std.mem.asBytes(&addr.in6), data[0..@sizeOf(std.net.Ip6Address)]);
            break :blk addr;
        },
        else => unreachable,
    };
}

pub const UdpReadResult = struct {
    bytes_read: usize,
    sender_addr: std.net.Address,
};

pub const UdpSocket = struct {
    handle: Handle,

    pub fn init(addr: std.net.Address) !UdpSocket {
        const fd = try createDatagramSocket(addr.any.family);
        return UdpSocket{
            .handle = fd,
        };
    }

    pub fn bind(self: *UdpSocket, addr: std.net.Address) !void {
        const sock = if (xev.backend == .iocp) @as(std.os.windows.ws2_32.SOCKET, @ptrCast(self.handle)) else self.handle;
        try std.posix.bind(sock, &addr.any, addr.getOsSockLen());
    }

    pub fn read(self: *UdpSocket, rt: *Runtime, buffer: []u8) !UdpReadResult {
        return switch (xev.backend) {
            .io_uring, .epoll => try self.readRecvmsg(rt, buffer),
            .iocp, .kqueue => try self.readRecvfrom(rt, buffer),
            .wasi_poll => error.Unsupported,
        };
    }

    fn readRecvfrom(self: *UdpSocket, rt: *Runtime, buffer: []u8) !UdpReadResult {
        var completion: xev.Completion = .{
            .op = .{
                .recvfrom = .{
                    .fd = self.handle,
                    .buffer = .{ .slice = buffer },
                },
            },
        };

        const bytes_read = try runIo(rt, &completion, "recvfrom");
        const addr = std.net.Address.initPosix(@alignCast(&completion.op.recvfrom.addr));

        return UdpReadResult{
            .bytes_read = bytes_read,
            .sender_addr = addr,
        };
    }

    fn readRecvmsg(self: *UdpSocket, rt: *Runtime, buffer: []u8) !UdpReadResult {
        var iov = [_]std.posix.iovec{.{
            .base = buffer.ptr,
            .len = buffer.len,
        }};

        var addr_storage: std.posix.sockaddr.storage = undefined;
        var msg: std.posix.msghdr = .{
            .name = @ptrCast(&addr_storage),
            .namelen = @sizeOf(std.posix.sockaddr.storage),
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        var completion: xev.Completion = .{
            .op = .{
                .recvmsg = .{
                    .fd = self.handle,
                    .msghdr = &msg,
                },
            },
        };

        const bytes_read = try runIo(rt, &completion, "recvmsg");

        // Extract address from msghdr
        const addr_bytes: [*]const u8 = @ptrCast(msg.name);
        const addr = addressFromStorage(addr_bytes[0..msg.namelen]);

        return UdpReadResult{
            .bytes_read = bytes_read,
            .sender_addr = addr,
        };
    }

    pub fn write(self: *UdpSocket, rt: *Runtime, addr: std.net.Address, data: []const u8) !usize {
        return switch (xev.backend) {
            .io_uring, .epoll => try self.writeSendmsg(rt, addr, data),
            .iocp, .kqueue => try self.writeSendto(rt, addr, data),
            .wasi_poll => error.Unsupported,
        };
    }

    fn writeSendto(self: *UdpSocket, rt: *Runtime, addr: std.net.Address, data: []const u8) !usize {
        var completion: xev.Completion = .{
            .op = .{
                .sendto = .{
                    .fd = self.handle,
                    .buffer = .{ .slice = data },
                    .addr = addr,
                },
            },
        };

        return try runIo(rt, &completion, "sendto");
    }

    fn writeSendmsg(self: *UdpSocket, rt: *Runtime, addr: std.net.Address, data: []const u8) !usize {
        var iov = [_]std.posix.iovec_const{.{
            .base = data.ptr,
            .len = data.len,
        }};

        var msg: std.posix.msghdr_const = .{
            .name = @ptrCast(&addr.any),
            .namelen = addr.getOsSockLen(),
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        var completion: xev.Completion = .{
            .op = .{
                .sendmsg = .{
                    .fd = self.handle,
                    .msghdr = &msg,
                },
            },
        };

        return try runIo(rt, &completion, "sendmsg");
    }

    pub fn close(self: *UdpSocket, rt: *Runtime) void {
        rt.beginShield();
        defer rt.endShield();

        var completion: xev.Completion = .{
            .op = .{
                .close = .{
                    .fd = self.handle,
                },
            },
        };

        // Shield ensures this never returns error.Canceled
        runIo(rt, &completion, "close") catch {};
    }
};

test "UDP: basic send and receive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var socket = try UdpSocket.init(bind_addr);
            defer socket.close(rt);

            try socket.bind(bind_addr);

            // Set the server port for the client to connect to
            server_port.* = TEST_PORT;

            // Wait for and echo one message
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.read(rt, &buffer);

            // Echo back to sender
            const bytes_sent = try socket.write(rt, recv_result.sender_addr, buffer[0..recv_result.bytes_read]);
            try testing.expectEqual(recv_result.bytes_read, bytes_sent);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            try rt.sleep(10); // Give server time to bind

            const client_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            var socket = try UdpSocket.init(client_addr);
            defer socket.close(rt);

            try socket.bind(client_addr);

            // Send test data
            const test_data = "Hello, UDP!";
            const server_addr = try std.net.Address.parseIp4("127.0.0.1", server_port.*);
            const bytes_sent = try socket.write(rt, server_addr, test_data);
            try testing.expectEqual(test_data.len, bytes_sent);

            // Receive echo
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.read(rt, &buffer);
            try testing.expectEqualStrings(test_data, buffer[0..recv_result.bytes_read]);
        }
    };

    var server_port: u16 = TEST_PORT;

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_port }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_port }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}
