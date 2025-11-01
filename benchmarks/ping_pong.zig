// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const zio = @import("zio");

const NUM_ROUNDS = 1_000_0000;

fn pinger(rt: *zio.Runtime, ping_tx: *zio.Channel(u32), pong_rx: *zio.Channel(u32), rounds: u32) !void {
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        try ping_tx.send(rt, i);
        _ = try pong_rx.receive(rt);
    }
}

fn ponger(rt: *zio.Runtime, ping_rx: *zio.Channel(u32), pong_tx: *zio.Channel(u32), rounds: u32) !void {
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        const value = try ping_rx.receive(rt);
        try pong_tx.send(rt, value);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{ .num_executors = 1 });
    defer runtime.deinit();

    // Create channels for ping-pong communication
    var ping_buffer: [1]u32 = undefined;
    var pong_buffer: [1]u32 = undefined;
    var ping_channel = zio.Channel(u32).init(&ping_buffer);
    var pong_channel = zio.Channel(u32).init(&pong_buffer);

    std.debug.print("Running ping-pong benchmark with {} rounds...\n", .{NUM_ROUNDS});

    var timer = try std.time.Timer.start();

    // Spawn pinger and ponger tasks
    var pinger_task = try runtime.spawn(pinger, .{ runtime, &ping_channel, &pong_channel, NUM_ROUNDS }, .{});
    defer pinger_task.cancel(runtime);

    var ponger_task = try runtime.spawn(ponger, .{ runtime, &ping_channel, &pong_channel, NUM_ROUNDS }, .{});
    defer ponger_task.cancel(runtime);

    // Run until both tasks complete
    try runtime.run();

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const elapsed_s = elapsed_ms / 1000.0;

    const total_messages = NUM_ROUNDS * 2; // Each round involves 2 messages (ping + pong)
    const messages_per_sec = @as(f64, @floatFromInt(total_messages)) / elapsed_s;
    const ns_per_round = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(NUM_ROUNDS));

    // Get metrics
    const metrics = runtime.getMetrics();

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total rounds: {}\n", .{NUM_ROUNDS});
    std.debug.print("  Total time: {d:.2} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("  Time per round: {d:.0} ns\n", .{ns_per_round});
    std.debug.print("  Messages/sec: {d:.0}\n", .{messages_per_sec});
    std.debug.print("  Rounds/sec: {d:.0}\n", .{messages_per_sec / 2.0});
    std.debug.print("\nMetrics:\n", .{});
    std.debug.print("  Total yields: {}\n", .{metrics.yields});
    std.debug.print("  Tasks spawned: {}\n", .{metrics.tasks_spawned});
    std.debug.print("  Tasks completed: {}\n", .{metrics.tasks_completed});
    std.debug.print("  Avg yields per round: {d:.1}\n", .{@as(f64, @floatFromInt(metrics.yields)) / @as(f64, @floatFromInt(NUM_ROUNDS))});
}
