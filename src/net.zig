const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const Channel = @import("sync/channel.zig").Channel;

const io_net = @import("io/net.zig");
pub const IpAddress = io_net.IpAddress;
pub const UnixAddress = io_net.UnixAddress;
pub const Address = io_net.Address;
pub const Socket = io_net.Socket;
pub const Server = io_net.Server;
pub const Stream = io_net.Stream;

pub const IpAddressList = struct {
    arena: std.heap.ArenaAllocator,
    addrs: []IpAddress,
    canon_name: ?[]u8,

    pub fn deinit(self: *IpAddressList) void {
        // Save the child allocator before destroying the arena
        const child_allocator = self.arena.child_allocator;
        // Copy the arena allocator into stack memory, because
        // otherwise it would destroy itself while it was still working.
        var arena = self.arena;
        arena.deinit();
        // Now destroy the struct itself
        child_allocator.destroy(self);
    }
};

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `IpAddressList.deinit()` on the result when done.
pub fn getAddressList(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !*IpAddressList {
    var task = try runtime.spawnBlocking(
        getAddressListBlocking,
        .{ allocator, name, port },
    );
    defer task.cancel(runtime);

    return try task.join(runtime);
}

fn getAddressListBlocking(
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !*IpAddressList {
    const result = try allocator.create(IpAddressList);
    errdefer allocator.destroy(result);

    result.* = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .addrs = &.{},
        .canon_name = null,
    };
    errdefer result.arena.deinit();

    const arena_allocator = result.arena.allocator();

    const name_c = try arena_allocator.dupeZ(u8, name);
    var port_buf: [6]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{}", .{port}) catch unreachable;
    const port_c = try arena_allocator.dupeZ(u8, port_str);

    const hints = std.c.addrinfo{
        .flags = .{ .NUMERICSERV = true },
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.STREAM,
        .protocol = std.posix.IPPROTO.TCP,
        .addrlen = 0,
        .addr = null,
        .canonname = null,
        .next = null,
    };

    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res);
    if (@intFromEnum(rc) != 0) return error.UnknownHostName;
    defer std.c.freeaddrinfo(res.?);

    // Count results
    var count: usize = 0;
    var it = res;
    while (it) |info| : (it = info.next) {
        if (info.family == std.posix.AF.INET or info.family == std.posix.AF.INET6) {
            count += 1;
        }
    }

    const addrs = try arena_allocator.alloc(IpAddress, count);
    var i: usize = 0;
    it = res;
    while (it) |info| : (it = info.next) {
        if (info.family == std.posix.AF.INET) {
            const addr_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(info.addr));
            addrs[i] = .{ .in = addr_in.* };
            i += 1;
        } else if (info.family == std.posix.AF.INET6) {
            const addr_in6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(info.addr));
            addrs[i] = .{ .in6 = addr_in6.* };
            i += 1;
        }
    }

    result.addrs = addrs;
    return result;
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

    var last_err: ?anyerror = null;
    for (list.addrs) |addr| {
        return addr.connect(rt) catch |err| {
            last_err = err;
            continue;
        };
    }
    if (last_err) |err| return err;
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

    const runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const GetAddressListTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator) !void {
            const list = try getAddressList(rt, alloc, "localhost", 80);
            defer list.deinit();

            try testing.expect(list.addrs.len > 0);
        }
    };

    try runtime.runUntilComplete(GetAddressListTask.run, .{ runtime, allocator }, .{});
}

test "getAddressList: numeric IP" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const GetAddressListTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator) !void {
            const list = try getAddressList(rt, alloc, "127.0.0.1", 8080);
            defer list.deinit();

            try testing.expectEqual(@as(usize, 1), list.addrs.len);
            try testing.expectEqual(@as(u16, 8080), list.addrs[0].getPort());
        }
    };

    try runtime.runUntilComplete(GetAddressListTask.run, .{ runtime, allocator }, .{});
}

test "tcpConnectToAddress: basic" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            try server_port.send(rt, server.socket.address.ip.getPort());

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

            stream.shutdown(rt, .both) catch {};
        }
    };

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ runtime, &server_port_ch }, .{});
    defer server_task.cancel(runtime);

    var client_task = try runtime.spawn(ClientTask.run, .{ runtime, &server_port_ch }, .{});
    defer client_task.cancel(runtime);

    try runtime.run();

    try server_task.join(runtime);
    try client_task.join(runtime);
}

test "tcpConnectToHost: basic" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *Channel(u16)) !void {
            const addr = try IpAddress.parseIp4("127.0.0.1", 0);
            const server = try addr.listen(rt, .{});
            defer server.close(rt);

            std.debug.print("Server listening on port {}\n", .{server.socket.address.ip.getPort()});

            try server_port.send(rt, server.socket.address.ip.getPort());

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

    const runtime = try Runtime.init(std.testing.allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    var server_port_buf: [1]u16 = undefined;
    var server_port_ch = Channel(u16).init(&server_port_buf);

    var server_task = try runtime.spawn(ServerTask.run, .{ runtime, &server_port_ch }, .{});
    defer server_task.cancel(runtime);

    var client_task = try runtime.spawn(ClientTask.run, .{ runtime, &server_port_ch }, .{});
    defer client_task.cancel(runtime);

    try runtime.run();

    try server_task.join(runtime);
    try client_task.join(runtime);
}
