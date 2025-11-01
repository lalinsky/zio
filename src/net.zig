// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

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

pub const IpAddressIterator = struct {
    head: ?*std.posix.addrinfo,
    current: ?*std.posix.addrinfo,

    pub fn next(self: *IpAddressIterator) ?IpAddress {
        while (self.current) |info| {
            self.current = info.next;
            const addr = info.addr orelse continue;
            // Skip unsupported address families
            if (addr.family != std.posix.AF.INET and addr.family != std.posix.AF.INET6) continue;
            return IpAddress.initPosix(addr, @intCast(info.addrlen));
        }
        return null;
    }

    pub fn deinit(self: *IpAddressIterator) void {
        if (self.head) |head| {
            if (builtin.os.tag == .windows) {
                std.os.windows.ws2_32.freeaddrinfo(head);
            } else {
                std.posix.system.freeaddrinfo(head);
            }
        }
    }
};

pub const LookupHostError = error{
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
    ProcessFdQuotaExceeded,
    SystemResources,
} || std.posix.UnexpectedError;

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `IpAddressIterator.deinit()` on the result when done.
pub fn lookupHost(
    runtime: *Runtime,
    name: []const u8,
    port: u16,
) LookupHostError!IpAddressIterator {
    var task = try runtime.spawnBlocking(
        lookupHostBlocking,
        .{ name, port },
    );
    defer task.cancel(runtime);

    return try task.join(runtime);
}

fn lookupHostBlocking(
    name: []const u8,
    port: u16,
) LookupHostError!IpAddressIterator {
    // Use stack buffer for temporary allocations
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const name_c = try allocator.dupeZ(u8, name);
    const port_c = try std.fmt.allocPrintSentinel(allocator, "{d}", .{port}, 0);

    const hints: std.posix.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.STREAM,
        .protocol = std.posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };

    var res: ?*std.posix.addrinfo = null;

    if (builtin.os.tag == .windows) {
        var first = true;
        while (true) {
            const rc = std.os.windows.ws2_32.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res);
            switch (@as(std.os.windows.ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(rc))))) {
                @as(std.os.windows.ws2_32.WinsockError, @enumFromInt(0)) => break,
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
                    try std.os.windows.callWSAStartup();
                    continue;
                },
                else => |err| return std.os.windows.unexpectedWSAError(err),
            }
        }
    } else {
        switch (std.posix.system.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res)) {
            @as(std.posix.system.EAI, @enumFromInt(0)) => {},
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
            .SYSTEM => switch (std.posix.errno(-1)) {
                else => |e| return std.posix.unexpectedErrno(e),
            },
            else => unreachable,
        }
    }

    return .{
        .head = res,
        .current = res,
    };
}

pub fn tcpConnectToHost(
    rt: *Runtime,
    name: []const u8,
    port: u16,
) !Stream {
    var iter = try lookupHost(rt, name, port);
    defer iter.deinit();

    var last_err: ?anyerror = null;
    while (iter.next()) |addr| {
        return addr.connect(rt) catch |err| {
            last_err = err;
            continue;
        };
    }
    if (last_err) |err| return err;
    return error.UnknownHostName;
}

pub fn tcpConnectToAddress(rt: *Runtime, addr: IpAddress) !Stream {
    return addr.connect(rt);
}

test {
    std.testing.refAllDecls(@This());
}

test "lookupHost: localhost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const LookupHostTask = struct {
        fn run(rt: *Runtime) !void {
            var iter = try lookupHost(rt, "localhost", 80);
            defer iter.deinit();

            var count: usize = 0;
            while (iter.next()) |_| {
                count += 1;
            }
            try testing.expect(count > 0);
        }
    };

    try runtime.runUntilComplete(LookupHostTask.run, .{runtime}, .{});
}

test "lookupHost: numeric IP" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    const LookupHostTask = struct {
        fn run(rt: *Runtime) !void {
            var iter = try lookupHost(rt, "127.0.0.1", 8080);
            defer iter.deinit();

            var count: usize = 0;
            var first_addr: ?IpAddress = null;
            while (iter.next()) |addr| {
                if (first_addr == null) first_addr = addr;
                count += 1;
            }
            try testing.expectEqual(1, count);
            try testing.expectEqual(8080, first_addr.?.getPort());
        }
    };

    try runtime.runUntilComplete(LookupHostTask.run, .{runtime}, .{});
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

            var stream = try tcpConnectToHost(rt, "localhost", port);
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
