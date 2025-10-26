const std = @import("std");
const zio = @import("zio");

const NUM_ITERATIONS = 100_000;

const SharedState = struct {
    task_a: ?*zio.AnyTask = null,
    task_b: ?*zio.AnyTask = null,
    latencies: []u64,
};

fn taskA(rt: *zio.Runtime, state: *SharedState) !void {
    const executor = zio.Runtime.current_executor.?;
    const current_coro = executor.current_coroutine.?;
    const current_task = zio.AnyTask.fromCoroutine(current_coro);

    state.task_a = current_task;

    // Wait for B to be ready
    while (state.task_b == null) {
        try rt.yield();
    }

    const task_b = state.task_b.?;

    var i: usize = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        // Wait for B to be sleeping
        while (task_b.coro.state.load(.acquire) != .waiting_sync) {
            try rt.yield();
        }

        // Measure sleep time
        const sleep_start = std.time.Instant.now() catch unreachable;

        // Wake B, then go to sleep
        zio.resumeTask(task_b, .maybe_remote);
        executor.yield(.ready, .waiting_sync, .no_cancel);

        // Woken up by B, measure latency
        const sleep_end = std.time.Instant.now() catch unreachable;
        const latency_ns = sleep_end.since(sleep_start);

        state.latencies[i] = latency_ns;

        if (i % 10000 == 0) {
            std.debug.print("Task A: iteration {}\n", .{i});
        }
    }

    // Wake B one last time so it can exit
    zio.resumeTask(task_b, .maybe_remote);

    std.debug.print("Task A: completed\n", .{});
}

fn taskB(rt: *zio.Runtime, state: *SharedState) !void {
    const executor = zio.Runtime.current_executor.?;
    const current_coro = executor.current_coroutine.?;
    const current_task = zio.AnyTask.fromCoroutine(current_coro);

    state.task_b = current_task;

    // Wait for A to be ready
    while (state.task_a == null) {
        try rt.yield();
    }

    const task_a = state.task_a.?;

    // Initial sleep - ready for A to start
    executor.yield(.ready, .waiting_sync, .no_cancel);

    var i: usize = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        // Woken up by A, wait for A to be sleeping before waking it
        while (task_a.coro.state.load(.acquire) != .waiting_sync) {
            try rt.yield();
        }

        // Now wake A back
        zio.resumeTask(task_a, .maybe_remote);

        if (i % 10000 == 0) {
            std.debug.print("Task B: iteration {}\n", .{i});
        }

        // Go to sleep, wait for A to wake us again
        executor.yield(.ready, .waiting_sync, .no_cancel);
    }

    std.debug.print("Task B: completed\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{ .num_executors = 1 });
    defer runtime.deinit();

    std.debug.print("Runtime initialized with {} executors\n", .{runtime.executors.items.len});

    // Allocate latencies array
    const latencies = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(latencies);

    var state = SharedState{
        .latencies = latencies,
    };

    std.debug.print("Running wakeup latency benchmark with {} iterations...\n", .{NUM_ITERATIONS});

    const start = std.time.nanoTimestamp();

    // Spawn tasks
    var task_a_handle = try runtime.spawn(taskA, .{ runtime, &state }, .{});
    defer task_a_handle.deinit();

    var task_b_handle = try runtime.spawn(taskB, .{ runtime, &state }, .{});
    defer task_b_handle.deinit();

    // Run
    std.debug.print("Running runtime...\n", .{});
    try runtime.run();
    std.debug.print("Runtime done...\n", .{});

    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);

    // Calculate statistics
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var sum: u64 = 0;

    for (latencies) |lat| {
        if (lat < min) min = lat;
        if (lat > max) max = lat;
        sum += lat;
    }

    const avg = sum / NUM_ITERATIONS;

    // Count distribution
    var under_1us: u64 = 0;
    var us_1_10: u64 = 0;
    var us_10_100: u64 = 0;
    var us_100_1000: u64 = 0;
    var over_1000us: u64 = 0;

    for (latencies) |lat| {
        const lat_us = lat / 1000;
        if (lat_us < 1) {
            under_1us += 1;
        } else if (lat_us < 10) {
            us_1_10 += 1;
        } else if (lat_us < 100) {
            us_10_100 += 1;
        } else if (lat_us < 1000) {
            us_100_1000 += 1;
        } else {
            over_1000us += 1;
        }
    }

    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const elapsed_s = elapsed_ms / 1000.0;
    const wakeups_per_sec = @as(f64, @floatFromInt(NUM_ITERATIONS)) / elapsed_s;

    std.debug.print("\nResults:\n", .{});
    std.debug.print("  Total iterations: {}\n", .{NUM_ITERATIONS});
    std.debug.print("  Total time: {d:.2} ms ({d:.3} s)\n", .{ elapsed_ms, elapsed_s });
    std.debug.print("  Wakeups/sec: {d:.0}\n", .{wakeups_per_sec});

    std.debug.print("\nWakeup Latency:\n", .{});
    std.debug.print("  Min: {d:.1} µs ({} ns)\n", .{ @as(f64, @floatFromInt(min)) / 1000.0, min });
    std.debug.print("  Avg: {d:.1} µs ({} ns)\n", .{ @as(f64, @floatFromInt(avg)) / 1000.0, avg });
    std.debug.print("  Max: {d:.1} µs ({} ns)\n", .{ @as(f64, @floatFromInt(max)) / 1000.0, max });

    std.debug.print("\nDistribution:\n", .{});
    std.debug.print("  < 1µs:       {} ({d:.1}%)\n", .{ under_1us, @as(f64, @floatFromInt(under_1us)) * 100.0 / @as(f64, @floatFromInt(NUM_ITERATIONS)) });
    std.debug.print("  1-10µs:      {} ({d:.1}%)\n", .{ us_1_10, @as(f64, @floatFromInt(us_1_10)) * 100.0 / @as(f64, @floatFromInt(NUM_ITERATIONS)) });
    std.debug.print("  10-100µs:    {} ({d:.1}%)\n", .{ us_10_100, @as(f64, @floatFromInt(us_10_100)) * 100.0 / @as(f64, @floatFromInt(NUM_ITERATIONS)) });
    std.debug.print("  100-1000µs:  {} ({d:.1}%)\n", .{ us_100_1000, @as(f64, @floatFromInt(us_100_1000)) * 100.0 / @as(f64, @floatFromInt(NUM_ITERATIONS)) });
    std.debug.print("  > 1000µs:    {} ({d:.1}%)\n", .{ over_1000us, @as(f64, @floatFromInt(over_1000us)) * 100.0 / @as(f64, @floatFromInt(NUM_ITERATIONS)) });

    // Get runtime metrics
    const metrics = runtime.getMetrics();
    std.debug.print("\nRuntime Metrics:\n", .{});
    std.debug.print("  Remote wakeups: {}\n", .{metrics.remote_wakeups});
    std.debug.print("  Remote wakeup avg: {d:.1} µs\n", .{metrics.getAvgRemoteWakeupLatencyNs() / 1000.0});
    std.debug.print("  Remote wakeup max: {d:.1} µs\n", .{@as(f64, @floatFromInt(metrics.remote_wakeup_latency_max_ns)) / 1000.0});
}
