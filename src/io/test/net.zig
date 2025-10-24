const std = @import("std");
const builtin = @import("builtin");
const meta = @import("../../meta.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Server = @import("../net.zig").Server;
const Socket = @import("../net.zig").Socket;
const IpAddress = @import("../net.zig").IpAddress;
const UnixAddress = @import("../net.zig").UnixAddress;

test "IpAddress: initIp4" {
    const addr = IpAddress.initIp4(.{0} ** 4, 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr.any.family);
}

test "IpAddress: initIp6" {
    const addr = IpAddress.initIp6(.{0} ** 16, 8080, 0, 0);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
}

test "IpAddress: parseIp4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr.any.family);
    try std.testing.expectEqual(8080, addr.getPort());
}

test "IpAddress: parseIp6" {
    const addr = try IpAddress.parseIp6("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
    try std.testing.expectEqual(8080, addr.getPort());
}

test "IpAddress: parseIp" {
    const addr1 = try IpAddress.parseIp("127.0.0.1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.getPort());

    const addr2 = try IpAddress.parseIp("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.getPort());
}

test "IpAddress: parseIpAndPort" {
    const addr1 = try IpAddress.parseIpAndPort("127.0.0.1:8080");
    try std.testing.expectEqual(std.posix.AF.INET, addr1.any.family);
    try std.testing.expectEqual(8080, addr1.getPort());

    const addr2 = try IpAddress.parseIpAndPort("[::1]:8080");
    try std.testing.expectEqual(std.posix.AF.INET6, addr2.any.family);
    try std.testing.expectEqual(8080, addr2.getPort());
}

test "UnixAddress: init" {
    if (!std.net.has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer std.fs.cwd().deleteFile(path) catch {};

    const addr = try UnixAddress.init(path);
    try std.testing.expectEqual(std.posix.AF.UNIX, addr.any.family);
}

pub fn checkListen(addr: anytype, options: anytype) !void {
    const Test = struct {
        pub fn mainFn(rt: *Runtime, addr_inner: @TypeOf(addr), options_inner: @TypeOf(options)) !void {
            const server = try addr_inner.listen(rt, options_inner);
            defer server.close(rt);

            var server_task = try rt.spawn(serverFn, .{ rt, server }, .{});
            defer server_task.deinit();

            var client_task = try rt.spawn(clientFn, .{ rt, server }, .{});
            defer client_task.deinit();

            // TODO use TaskGroup

            try server_task.join(rt);
            try client_task.join(rt);
        }

        pub fn serverFn(rt: *Runtime, server: Server) !void {
            const client = try server.accept(rt);
            defer client.close(rt);

            var buf: [32]u8 = undefined;
            var reader = client.reader(rt, &buf);

            const line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", line);

            client.shutdown(rt, .both) catch {};
        }

        pub fn clientFn(rt: *Runtime, server: Server) !void {
            const client = try server.socket.address.connect(rt);
            defer client.close(rt);

            var buf: [32]u8 = undefined;
            var writer = client.writer(rt, &buf);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            client.shutdown(rt, .both) catch {};
        }
    };

    var runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    try runtime.runUntilComplete(Test.mainFn, .{ &runtime, addr, options }, .{});
}

pub fn checkBind(server_addr: anytype, client_addr: anytype) !void {
    const Test = struct {
        pub fn mainFn(rt: *Runtime, server_addr_inner: @TypeOf(server_addr), client_addr_inner: @TypeOf(client_addr)) !void {
            const socket = try server_addr_inner.bind(rt);
            defer socket.close(rt);

            var server_task = try rt.spawn(serverFn, .{ rt, socket }, .{});
            defer server_task.deinit();

            var client_task = try rt.spawn(clientFn, .{ rt, socket, client_addr_inner }, .{});
            defer client_task.deinit();

            try server_task.join(rt);
            try client_task.join(rt);
        }

        pub fn serverFn(rt: *Runtime, socket: Socket) !void {
            var buf: [1024]u8 = undefined;
            const result = try socket.receiveFrom(rt, &buf);

            try std.testing.expectEqualStrings("hello", buf[0..result.len]);

            const bytes_sent = try socket.sendTo(rt, result.from, buf[0..result.len]);
            try std.testing.expectEqual(result.len, bytes_sent);
        }

        pub fn clientFn(rt: *Runtime, server_socket: Socket, client_addr_inner: @TypeOf(client_addr)) !void {
            const client_socket = try client_addr_inner.bind(rt);
            defer client_socket.close(rt);

            const test_data = "hello";
            const bytes_sent = try client_socket.sendTo(rt, server_socket.address, test_data);
            try std.testing.expectEqual(test_data.len, bytes_sent);

            var buf: [1024]u8 = undefined;
            const result = try client_socket.receiveFrom(rt, &buf);
            try std.testing.expectEqualStrings(test_data, buf[0..result.len]);
        }
    };

    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(Test.mainFn, .{ &runtime, server_addr, client_addr }, .{});
}

test "UnixAddress: listen/accept/connect/read/write" {
    if (!std.net.has_unix_sockets) return error.SkipZigTest;

    const path = "zio-test-socket.sock";
    defer std.fs.cwd().deleteFile(path) catch {};

    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{});
}

test "IpAddress: listen/accept/connect/read/write IPv4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkListen(addr, IpAddress.ListenOptions{});
}

test "IpAddress: listen/accept/connect/read/write IPv6" {
    const addr = try IpAddress.parseIp6("::1", 0);
    checkListen(addr, IpAddress.ListenOptions{}) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}

test "IpAddress: bind/sendTo/receiveFrom IPv4" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkBind(addr, addr);
}

test "IpAddress: bind/sendTo/receiveFrom IPv6" {
    const addr = try IpAddress.parseIp6("::1", 0);
    checkBind(addr, addr) catch |err| {
        if (err == error.AddressNotAvailable) return error.SkipZigTest;
        return err;
    };
}

test "UnixAddress: bind/sendTo/receiveFrom" {
    if (!std.net.has_unix_sockets) return error.SkipZigTest;

    const server_path = "zio-test-udp-server.sock";
    defer std.fs.cwd().deleteFile(server_path) catch {};

    const client_path = "zio-test-udp-client.sock";
    defer std.fs.cwd().deleteFile(client_path) catch {};

    const server_addr = try UnixAddress.init(server_path);
    const client_addr = try UnixAddress.init(client_path);
    try checkBind(server_addr, client_addr);
}
