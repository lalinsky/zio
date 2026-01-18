// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

const NUM_CLIENTS = 10;
const MESSAGES_PER_CLIENT = 50_000;
const MESSAGE_SIZE = 64; // bytes

fn handleClient(rt: *zio.Runtime, in_stream: zio.net.Stream) !void {
    var stream = in_stream;
    defer stream.close(rt);

    var buffer: [MESSAGE_SIZE]u8 = undefined;

    while (true) {
        const n = try stream.read(rt, &buffer);
        if (n == 0) break;
        try stream.writeAll(rt, buffer[0..n]);
    }
}

fn serverTask(rt: *zio.Runtime, ready: *zio.ResetEvent, done: *zio.ResetEvent) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 45678);

    var server = try addr.listen(rt, .{ .reuse_address = true });
    defer server.close(rt);

    ready.set();

    var clients_handled: usize = 0;
    while (clients_handled < NUM_CLIENTS) : (clients_handled += 1) {
        var stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream });
        task.detach(rt);
    }

    // Wait for signal that all clients are done before shutting down
    try done.wait(rt);
}

fn clientTask(
    rt: *zio.Runtime,
    ready: *zio.ResetEvent,
) !void {
    try ready.wait(rt);

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 45678);
    var stream = try addr.connect(rt);
    defer stream.close(rt);
    defer stream.shutdown(rt, .both) catch {};
    try stream.socket.setNoDelay(true);

    var send_buffer: [MESSAGE_SIZE]u8 = undefined;
    var recv_buffer: [MESSAGE_SIZE]u8 = undefined;

    // Fill send buffer with some data
    for (&send_buffer, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    var i: usize = 0;
    while (i < MESSAGES_PER_CLIENT) : (i += 1) {
        try stream.writeAll(rt, &send_buffer);

        var bytes_received: usize = 0;
        while (bytes_received < MESSAGE_SIZE) {
            const n = try stream.read(rt, recv_buffer[bytes_received..]);
            if (n == 0) return error.UnexpectedEndOfStream;
            bytes_received += n;
        }
    }
}

fn benchmarkTask(
    rt: *zio.Runtime,
    allocator: std.mem.Allocator,
) !void {
    var server_ready = zio.ResetEvent.init;
    var server_done = zio.ResetEvent.init;

    const total_messages = NUM_CLIENTS * MESSAGES_PER_CLIENT;

    // Spawn server
    var server = try rt.spawn(serverTask, .{ rt, &server_ready, &server_done });
    defer server.cancel(rt);

    // Wait for server to be ready
    try server_ready.wait(rt);

    var timer = try std.time.Timer.start();

    // Spawn all clients
    const client_tasks = try allocator.alloc(zio.JoinHandle(anyerror!void), NUM_CLIENTS);
    defer allocator.free(client_tasks);

    for (client_tasks) |*task| {
        const handle = try rt.spawn(clientTask, .{ rt, &server_ready });
        task.* = handle.cast(anyerror!void);
    }

    // Wait for all clients to complete
    for (client_tasks) |*task| {
        defer task.detach(rt);
        try task.join(rt);
    }

    const elapsed_ns = timer.read();

    // Signal server to shut down
    server_done.set();
    try server.join(rt);

    // Calculate statistics
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const elapsed_s = elapsed_ms / 1000.0;

    const messages_per_sec = @as(f64, @floatFromInt(total_messages)) / elapsed_s;
    const throughput_mbps = (@as(f64, @floatFromInt(total_messages * MESSAGE_SIZE * 2)) / elapsed_s) / (1024.0 * 1024.0);

    std.debug.print("Results:\n", .{});
    std.debug.print("  Total time: {d:.2} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("  Messages/sec: {d:.0}\n", .{messages_per_sec});
    std.debug.print("  Throughput: {d:.2} MB/s (rx+tx)\n", .{throughput_mbps});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Echo Server Benchmark\n", .{});
    std.debug.print("  Clients: {}\n", .{NUM_CLIENTS});
    std.debug.print("  Messages per client: {}\n", .{MESSAGES_PER_CLIENT});
    std.debug.print("  Message size: {} bytes\n", .{MESSAGE_SIZE});
    std.debug.print("  Total messages: {}\n\n", .{NUM_CLIENTS * MESSAGES_PER_CLIENT});

    var runtime = try zio.Runtime.init(allocator, .{ .executors = .auto });
    defer runtime.deinit();

    var handle = try runtime.spawn(benchmarkTask, .{ runtime, allocator });
    try handle.join(runtime);
}
