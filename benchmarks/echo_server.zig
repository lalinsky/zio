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

    var server = try addr.listen(rt, .{});
    defer server.close(rt);

    ready.set();

    var clients_handled: usize = 0;
    while (clients_handled < NUM_CLIENTS) : (clients_handled += 1) {
        var stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.detach(rt);
    }

    // Wait for signal that all clients are done before shutting down
    try done.wait(rt);
}

fn clientTask(
    rt: *zio.Runtime,
    ready: *zio.ResetEvent,
    latencies: []u64,
    client_id: usize,
) !void {
    try ready.wait(rt);

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 45678);
    var stream = try addr.connect(rt);
    defer stream.close(rt);
    defer stream.shutdown(rt, .both) catch {};

    var send_buffer: [MESSAGE_SIZE]u8 = undefined;
    var recv_buffer: [MESSAGE_SIZE]u8 = undefined;

    // Fill send buffer with some data
    for (&send_buffer, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    var i: usize = 0;
    const start_idx = client_id * MESSAGES_PER_CLIENT;
    while (i < MESSAGES_PER_CLIENT) : (i += 1) {
        var timer = try std.time.Timer.start();

        try stream.writeAll(rt, &send_buffer);

        var bytes_received: usize = 0;
        while (bytes_received < MESSAGE_SIZE) {
            const n = try stream.read(rt, recv_buffer[bytes_received..]);
            if (n == 0) return error.UnexpectedEndOfStream;
            bytes_received += n;
        }

        latencies[start_idx + i] = timer.read();
    }
}

fn calculatePercentile(sorted_latencies: []u64, percentile: f64) u64 {
    const idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted_latencies.len)) * percentile));
    return sorted_latencies[@min(idx, sorted_latencies.len - 1)];
}

fn benchmarkTask(
    rt: *zio.Runtime,
    allocator: std.mem.Allocator,
) !void {
    var server_ready = zio.ResetEvent.init;
    var server_done = zio.ResetEvent.init;

    // Allocate latency tracking
    const total_messages = NUM_CLIENTS * MESSAGES_PER_CLIENT;
    const latencies = try allocator.alloc(u64, total_messages);
    defer allocator.free(latencies);

    // Spawn server
    var server = try rt.spawn(serverTask, .{ rt, &server_ready, &server_done }, .{});
    defer server.cancel(rt);

    // Wait for server to be ready
    try server_ready.wait(rt);

    var timer = try std.time.Timer.start();

    // Spawn all clients
    const client_tasks = try allocator.alloc(zio.JoinHandle(anyerror!void), NUM_CLIENTS);
    defer allocator.free(client_tasks);

    for (client_tasks, 0..) |*task, i| {
        const handle = try rt.spawn(clientTask, .{ rt, &server_ready, latencies, i }, .{});
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

    // Sort latencies for percentile calculation
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));

    const p50 = calculatePercentile(latencies, 0.50);
    const p95 = calculatePercentile(latencies, 0.95);
    const p99 = calculatePercentile(latencies, 0.99);

    var sum: u64 = 0;
    for (latencies) |lat| sum += lat;
    const avg = sum / latencies.len;

    std.debug.print("Results:\n", .{});
    std.debug.print("  Total time: {d:.2} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("  Messages/sec: {d:.0}\n", .{messages_per_sec});
    std.debug.print("  Throughput: {d:.2} MB/s (rx+tx)\n", .{throughput_mbps});
    std.debug.print("\nLatency (round-trip):\n", .{});
    std.debug.print("  Average: {d:.1} µs\n", .{@as(f64, @floatFromInt(avg)) / 1000.0});
    std.debug.print("  p50: {d:.1} µs\n", .{@as(f64, @floatFromInt(p50)) / 1000.0});
    std.debug.print("  p95: {d:.1} µs\n", .{@as(f64, @floatFromInt(p95)) / 1000.0});
    std.debug.print("  p99: {d:.1} µs\n", .{@as(f64, @floatFromInt(p99)) / 1000.0});
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

    var runtime = try zio.Runtime.init(allocator, .{ .num_executors = 0 });
    defer runtime.deinit();

    var handle = try runtime.spawn(benchmarkTask, .{ runtime, allocator }, .{});
    try handle.join(runtime);
}
