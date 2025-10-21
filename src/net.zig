const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const TcpStream = @import("tcp.zig").TcpStream;

pub const AddressList = std.net.AddressList;

pub const Stream = TcpStream;

/// Async DNS resolution using the runtime's thread pool.
/// Performs DNS lookup in a blocking task to avoid blocking the event loop.
/// Call `AddressList.deinit()` on the result when done.
pub fn getAddressList(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !*AddressList {
    var blocking_task = try runtime.spawnBlocking(
        std.net.getAddressList,
        .{ allocator, name, port },
    );
    defer blocking_task.deinit();

    return try blocking_task.join();
}

/// Async TCP connection by hostname.
/// Performs DNS resolution followed by connection attempt.
/// All memory allocated with `allocator` will be freed before this function returns.
pub fn tcpConnectToHost(
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    name: []const u8,
    port: u16,
) !TcpStream {
    const list = try getAddressList(runtime, allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddress(runtime, addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return error.ConnectionRefused;
}

/// Async TCP connection to a specific address.
/// This is a convenience wrapper around TcpStream.connect.
pub fn tcpConnectToAddress(runtime: *Runtime, address: std.net.Address) !TcpStream {
    return TcpStream.connect(runtime, address);
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

test "tcpConnectToAddress: basic connection" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const ResetEvent = @import("sync.zig").ResetEvent;

    const TEST_PORT = 45100;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ServerTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            const TcpListener = @import("tcp.zig").TcpListener;
            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var listener = try TcpListener.init(rt, addr);
            defer listener.close();

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept();
            defer stream.close();

            var buffer: [256]u8 = undefined;
            const n = try stream.read(&buffer);
            try testing.expectEqualStrings("hello", buffer[0..n]);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try tcpConnectToAddress(rt, addr);
            defer stream.close();

            try stream.writeAll("hello");
            try stream.shutdown();
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}

test "tcpConnectToHost: localhost connection" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const ResetEvent = @import("sync.zig").ResetEvent;

    const TEST_PORT = 45101;

    var runtime = try Runtime.init(allocator, .{ .thread_pool = .{ .enabled = true } });
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ServerTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            const TcpListener = @import("tcp.zig").TcpListener;
            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var listener = try TcpListener.init(rt, addr);
            defer listener.close();

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept();
            defer stream.close();

            var buffer: [256]u8 = undefined;
            const n = try stream.read(&buffer);
            try testing.expectEqualStrings("hello from host", buffer[0..n]);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent, alloc: std.mem.Allocator) !void {
            try ready_event.wait(rt);

            var stream = try tcpConnectToHost(rt, alloc, "localhost", TEST_PORT);
            defer stream.close();

            try stream.writeAll("hello from host");
            try stream.shutdown();
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready, allocator }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}
