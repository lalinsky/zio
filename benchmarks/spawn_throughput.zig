// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

const NUM_SPAWNS = 1000000;

var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn task(_: *zio.Runtime) !void {
    _ = counter.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{ .executors = .auto });
    defer runtime.deinit();

    std.debug.print("Running spawn throughput benchmark with {} spawns...\n", .{NUM_SPAWNS});

    var timer = zio.time.Stopwatch.start();

    var group: zio.Group = .init;
    defer group.cancel();

    for (0..NUM_SPAWNS) |_| {
        try group.spawn(task, .{runtime});
    }

    try group.wait();

    const elapsed = timer.read();
    const elapsed_ns = elapsed.toNanoseconds();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const spawns_per_sec = @as(f64, @floatFromInt(NUM_SPAWNS)) / elapsed_s;
    const ns_per_spawn = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(NUM_SPAWNS));

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total spawns: {}\n", .{NUM_SPAWNS});
    std.debug.print("  Completed: {}\n", .{counter.load(.monotonic)});
    std.debug.print("  Total time: {d:.2} ms\n", .{elapsed_s * 1000.0});
    std.debug.print("  Time per spawn: {d:.0} ns\n", .{ns_per_spawn});
    std.debug.print("  Spawns/sec: {d:.0}\n", .{spawns_per_sec});
}
