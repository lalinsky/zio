const std = @import("std");
const meta = @import("../../meta.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Server = @import("../net.zig").Server;
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
}

test "IpAddress: parseIp6" {
    const addr = try IpAddress.parseIp6("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr.any.family);
}

test "IpAddress: parseIp" {
    const addr1 = try IpAddress.parseIp("127.0.0.1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET, addr1.any.family);

    const addr2 = try IpAddress.parseIp("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr2.any.family);
}

test "IpAddress: parseIpAndPort" {
    const addr1 = try IpAddress.parseIpAndPort("127.0.0.1:8080");
    try std.testing.expectEqual(std.posix.AF.INET, addr1.any.family);

    const addr2 = try IpAddress.parseIp("::1", 8080);
    try std.testing.expectEqual(std.posix.AF.INET6, addr2.any.family);
}

test "UnixAddress: init" {
    if (!std.net.has_unix_sockets) return error.SkipZigTest;
    const addr = try UnixAddress.init("/tmp/socket");
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

            try server_task.join();
            try client_task.join();
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
            const client = try server.address.connect(rt);
            defer client.close(rt);

            var buf: [32]u8 = undefined;
            var writer = client.writer(rt, &buf);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            client.shutdown(rt, .both) catch {};
        }
    };

    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(Test.mainFn, .{ &runtime, addr, options }, .{});
}

test "UnixAddress: listen/accept/connect/read/write" {
    if (!std.net.has_unix_sockets) return error.SkipZigTest;
    const path = "/tmp/zio-test-socket";
    defer std.fs.deleteFileAbsolute(path) catch {};

    const addr = try UnixAddress.init(path);
    try checkListen(addr, UnixAddress.ListenOptions{});
}

test "IpAddress: listen/accept/connect/read/write" {
    const addr = try IpAddress.parseIp4("127.0.0.1", 0);
    try checkListen(addr, IpAddress.ListenOptions{});
}
