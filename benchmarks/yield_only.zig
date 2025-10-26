const std = @import("std");
const zio = @import("zio");

const NUM_ROUNDS = 1_000_000;

fn yielder(rt: *zio.Runtime, rounds: u32) !void {
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        try rt.yield();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    std.debug.print("Running yield-only benchmark with {} total yields...\n", .{NUM_ROUNDS * 2});

    const start = std.time.nanoTimestamp();

    // Spawn two tasks that just yield back and forth
    var task1 = try runtime.spawn(yielder, .{ runtime, NUM_ROUNDS }, .{});
    defer task1.deinit();

    var task2 = try runtime.spawn(yielder, .{ runtime, NUM_ROUNDS }, .{});
    defer task2.deinit();

    try runtime.run();

    const end = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end - start));
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    const total_yields = NUM_ROUNDS * 2;
    const ns_per_yield = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_yields));

    const metrics = runtime.getMetrics();

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total time: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Total yields (measured): {}\n", .{metrics.yields});
    std.debug.print("  Time per yield: {d:.1} ns\n", .{ns_per_yield});
    std.debug.print("  Yields/sec: {d:.0}\n", .{@as(f64, @floatFromInt(total_yields)) / (elapsed_ms / 1000.0)});
}
