const std = @import("std");
const zio = @import("zio");

const NUM_CLIENTS = 10;
const MESSAGES_PER_CLIENT = 10_000;
const MESSAGE_SIZE = 64; // bytes

const ResetEvent = zio.ResetEvent;

fn handleClient(in_stream: zio.TcpStream) !void {
    var stream = in_stream;
    defer stream.close();
    defer stream.shutdown() catch {};

    var buffer: [MESSAGE_SIZE]u8 = undefined;

    while (true) {
        const n = stream.read(&buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        if (n == 0) break;

        try stream.writeAll(buffer[0..n]);
    }
}

fn serverTask(rt: *zio.Runtime, ready: *ResetEvent, done: *ResetEvent) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 45678);

    var listener = try zio.TcpListener.init(rt, addr);
    defer listener.close();

    try listener.bind(addr);
    try listener.listen(128);

    ready.set(rt);

    var clients_handled: usize = 0;
    while (clients_handled < NUM_CLIENTS) : (clients_handled += 1) {
        var stream = try listener.accept();
        errdefer stream.close();

        var task = try rt.spawn(handleClient, .{stream}, .{});
        task.deinit();
    }

    // Wait for signal that all clients are done before shutting down
    try done.wait(rt);
}

fn clientTask(
    rt: *zio.Runtime,
    ready: *ResetEvent,
    latencies: []u64,
    client_id: usize,
) !void {
    try ready.wait(rt);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 45678);
    var stream = try zio.net.tcpConnectToAddress(rt, addr);
    defer stream.close();
    defer stream.shutdown() catch {};

    var send_buffer: [MESSAGE_SIZE]u8 = undefined;
    var recv_buffer: [MESSAGE_SIZE]u8 = undefined;

    // Fill send buffer with some data
    for (&send_buffer, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    var i: usize = 0;
    const start_idx = client_id * MESSAGES_PER_CLIENT;
    while (i < MESSAGES_PER_CLIENT) : (i += 1) {
        const msg_start = std.time.nanoTimestamp();

        try stream.writeAll(&send_buffer);

        var bytes_received: usize = 0;
        while (bytes_received < MESSAGE_SIZE) {
            const n = try stream.read(recv_buffer[bytes_received..]);
            if (n == 0) return error.UnexpectedEndOfStream;
            bytes_received += n;
        }

        const msg_end = std.time.nanoTimestamp();
        latencies[start_idx + i] = @intCast(msg_end - msg_start);
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
    var server_ready = ResetEvent.init;
    var server_done = ResetEvent.init;

    // Allocate latency tracking
    const total_messages = NUM_CLIENTS * MESSAGES_PER_CLIENT;
    const latencies = try allocator.alloc(u64, total_messages);
    defer allocator.free(latencies);

    // Spawn server
    var server = try rt.spawn(serverTask, .{ rt, &server_ready, &server_done }, .{});
    defer server.deinit();

    // Wait for server to be ready
    try server_ready.wait(rt);

    const start = std.time.nanoTimestamp();

    // Spawn all clients
    const client_tasks = try allocator.alloc(zio.JoinHandle(void), NUM_CLIENTS);
    defer allocator.free(client_tasks);

    for (client_tasks, 0..) |*task, i| {
        task.* = try rt.spawn(clientTask, .{ rt, &server_ready, latencies, i }, .{});
    }

    // Wait for all clients to complete
    for (client_tasks) |*task| {
        defer task.deinit();
        try task.join();
    }

    const end = std.time.nanoTimestamp();

    // Signal server to shut down
    server_done.set(rt);
    try server.join();

    // Calculate statistics
    const elapsed_ns = @as(u64, @intCast(end - start));
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

    // Get runtime metrics
    const metrics = rt.getMetrics();

    std.debug.print("Results:\n", .{});
    std.debug.print("  Total time: {d:.2} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("  Messages/sec: {d:.0}\n", .{messages_per_sec});
    std.debug.print("  Throughput: {d:.2} MB/s (rx+tx)\n", .{throughput_mbps});
    std.debug.print("\nLatency (round-trip):\n", .{});
    std.debug.print("  Average: {d:.1} µs\n", .{@as(f64, @floatFromInt(avg)) / 1000.0});
    std.debug.print("  p50: {d:.1} µs\n", .{@as(f64, @floatFromInt(p50)) / 1000.0});
    std.debug.print("  p95: {d:.1} µs\n", .{@as(f64, @floatFromInt(p95)) / 1000.0});
    std.debug.print("  p99: {d:.1} µs\n", .{@as(f64, @floatFromInt(p99)) / 1000.0});
    std.debug.print("\nMetrics:\n", .{});
    std.debug.print("  Tasks spawned: {}\n", .{metrics.tasks_spawned});
    std.debug.print("  Tasks completed: {}\n", .{metrics.tasks_completed});
    std.debug.print("  Total yields: {}\n", .{metrics.yields});
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

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(benchmarkTask, .{ &runtime, allocator }, .{});
}
