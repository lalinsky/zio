const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const Channel = @import("sync/channel.zig").Channel;

const io_net = @import("io/net.zig");
pub const IpAddress = io_net.IpAddress;
pub const UnixAddress = io_net.UnixAddress;
pub const Address = io_net.Address;
pub const Server = io_net.Server;
pub const Stream = io_net.Stream;

pub const IpAddressList = struct {
    arena: std.heap.ArenaAllocator,
    addrs: []IpAddress,
    canon_name: ?[]u8,

    pub fn deinit(self: *IpAddressList) void {
        // Here we copy the arena allocator into stack memory, because
        // otherwise it would destroy itself while it was still working.
        var arena = self.arena;
        arena.deinit();
        // self is destroyed
    }
};

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `AddressList.deinit()` on the result when done.
pub fn getAddressList(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !*std.net.AddressList {
    var task = try runtime.spawnBlocking(
        std.net.getAddressList,
        .{ allocator, name, port },
    );
    defer task.deinit();

    return try task.join();
}

pub fn tcpConnectToHost(
    rt: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !Stream {
    const list = try getAddressList(rt, allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return IpAddress.fromStd(addr).connect(rt) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return error.ConnectionRefused;
}

pub fn tcpConnectToAddress(rt: *Runtime, addr: IpAddress) !Stream {
    return addr.connect(rt);
}

test {
    std.testing.refAllDecls(@This());
}

test "getAddressList: localhost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const GetAddressListTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator) !void {
            const list = try getAddressList(rt, alloc, "localhost", 80);
            defer list.deinit();

            try testing.expect(list.addrs.len > 0);
        }
    };

    try runtime.runUntilComplete(GetAddressListTask.run, .{ &runtime, allocator }, .{});
}

test "getAddressList: numeric IP" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const GetAddressListTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator) !void {
            const list = try getAddressList(rt, alloc, "127.0.0.1", 8080);
            defer list.deinit();

            try testing.expectEqual(@as(usize, 1), list.addrs.len);
            try testing.expectEqual(@as(u16, 8080), list.addrs[0].getPort());
        }
    };

    try runtime.runUntilComplete(GetAddressListTask.run, .{ &runtime, allocator }, .{});
}

test "tcpConnectToAddress: basic" {
    var runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            try server_port.send(rt, server.address.ip.getPort());

            var stream = try server.accept(rt);
            defer stream.close(rt);

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const port = try server_port.receive(rt);
            const addr = try IpAddress.parseIp4("127.0.0.1", port);

            var stream = try tcpConnectToAddress(rt, addr);
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            try stream.shutdown(rt, .both);
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_port_ch }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_port_ch }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}

test "tcpConnectToHost: basic" {
    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            std.debug.print("Server listening on port {}\n", .{server.address.ip.getPort()});

            try server_port.send(rt, server.address.ip.getPort());

            var stream = try server.accept(rt);
            defer stream.close(rt);

            var read_buffer: [256]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            const msg = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("hello", msg);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const port = try server_port.receive(rt);
            std.debug.print("Client connecting to port {}\n", .{port});

            var stream = try tcpConnectToHost(rt, std.testing.allocator, "localhost", port);
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            try writer.interface.writeAll("hello\n");
            try writer.interface.flush();

            try stream.shutdown(rt, .both);
        }
    };

    var runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_port_ch }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_port_ch }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}
