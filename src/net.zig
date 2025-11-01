// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
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

    pub fn deinit(self: *IpAddressList) void {
        // Here we copy the arena allocator into stack memory, because
        // otherwise it would destroy itself while it was still working.
        var arena = self.arena;
        arena.deinit();
        // self is destroyed
    }
};

pub const GetAddressListError = error{
    HostLacksNetworkAddresses,
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyNotSupported,
    OutOfMemory,
    UnknownHostName,
    ServiceUnavailable,
    Unexpected,
    RuntimeShutdown,
    Closed,
    NoThreadPool,
} || posix.UnexpectedError;

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `IpAddressList.deinit()` on the result when done.
pub fn getAddressList(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) GetAddressListError!*IpAddressList {
    var task = try runtime.spawnBlocking(
        getAddressListBlocking,
        .{ allocator, name, port },
    );
    defer task.cancel(runtime);

    return try task.join(runtime);
}

fn getAddressListBlocking(
    gpa: std.mem.Allocator,
    name: []const u8,
    port: u16,
) GetAddressListError!*IpAddressList {
    const result = blk: {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const result = try arena.allocator().create(IpAddressList);
        result.* = IpAddressList{
            .arena = arena,
            .addrs = undefined,
        };
        break :blk result;
    };
    const arena = result.arena.allocator();
    errdefer result.deinit();

    const name_c = try gpa.dupeZ(u8, name);
    defer gpa.free(name_c);

    const port_c = try std.fmt.allocPrintSentinel(gpa, "{d}", .{port}, 0);
    defer gpa.free(port_c);

    const hints: posix.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = posix.AF.UNSPEC,
        .socktype = posix.SOCK.STREAM,
        .protocol = posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };

    var res: ?*posix.addrinfo = null;

    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        var first = true;
        while (true) {
            const rc = ws2_32.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res);
            switch (@as(windows.ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(rc))))) {
                @as(windows.ws2_32.WinsockError, @enumFromInt(0)) => break,
                .WSATRY_AGAIN => return error.TemporaryNameServerFailure,
                .WSANO_RECOVERY => return error.NameServerFailure,
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSA_NOT_ENOUGH_MEMORY => return error.OutOfMemory,
                .WSAHOST_NOT_FOUND => return error.UnknownHostName,
                .WSATYPE_NOT_FOUND => return error.ServiceUnavailable,
                .WSAEINVAL => unreachable,
                .WSAESOCKTNOSUPPORT => unreachable,
                .WSANOTINITIALISED => {
                    if (!first) return error.Unexpected;
                    first = false;
                    try windows.callWSAStartup();
                    continue;
                },
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        defer ws2_32.freeaddrinfo(res);
    } else {
        switch (posix.system.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res)) {
            @as(posix.system.EAI, @enumFromInt(0)) => {},
            .ADDRFAMILY => return error.HostLacksNetworkAddresses,
            .AGAIN => return error.TemporaryNameServerFailure,
            .BADFLAGS => unreachable, // Invalid hints
            .FAIL => return error.NameServerFailure,
            .FAMILY => return error.AddressFamilyNotSupported,
            .MEMORY => return error.OutOfMemory,
            .NODATA => return error.HostLacksNetworkAddresses,
            .NONAME => return error.UnknownHostName,
            .SERVICE => return error.ServiceUnavailable,
            .SOCKTYPE => unreachable, // Invalid socket type requested in hints
            .SYSTEM => switch (posix.errno(-1)) {
                else => |e| return posix.unexpectedErrno(e),
            },
            else => unreachable,
        }
        defer if (res) |some| posix.system.freeaddrinfo(some);
    }

    const addr_count = blk: {
        var count: usize = 0;
        var it = res;
        while (it) |info| : (it = info.next) {
            if (info.addr != null) {
                count += 1;
            }
        }
        break :blk count;
    };
    result.addrs = try arena.alloc(IpAddress, addr_count);

    var it = res;
    var i: usize = 0;
    while (it) |info| : (it = info.next) {
        const addr = info.addr orelse continue;
        // Skip unsupported address families
        if (addr.family != posix.AF.INET and addr.family != posix.AF.INET6) continue;
        result.addrs[i] = IpAddress.initPosix(addr, info.addrlen);
        i += 1;
    }

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
