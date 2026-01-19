// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

const NUM_SPAWNS = 1000000;

var spawn_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var complete_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn task(runtime: *zio.Runtime) !void {
    // Try to spawn two child tasks
    for (0..2) |_| {
        const prev = spawn_count.fetchAdd(1, .monotonic);
        if (prev < NUM_SPAWNS) {
            var t = try runtime.spawn(task, .{runtime});
            t.detach(runtime);
        }
    }
    _ = complete_count.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{ .executors = .auto });
    defer runtime.deinit();

    std.debug.print("Running spawn tree benchmark with {} spawns...\n", .{NUM_SPAWNS});

    var timer = try std.time.Timer.start();

    var t = try runtime.spawn(task, .{runtime});
    try t.join(runtime);

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_spawned = spawn_count.load(.monotonic);
    const total_completed = complete_count.load(.monotonic);
    const spawns_per_sec = @as(f64, @floatFromInt(total_completed)) / elapsed_s;
    const ns_per_spawn = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_completed));

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total spawns: {}\n", .{total_spawned});
    std.debug.print("  Completed: {}\n", .{total_completed});
    std.debug.print("  Total time: {d:.2} ms\n", .{elapsed_s * 1000.0});
    std.debug.print("  Time per spawn: {d:.0} ns\n", .{ns_per_spawn});
    std.debug.print("  Spawns/sec: {d:.0}\n", .{spawns_per_sec});
}
