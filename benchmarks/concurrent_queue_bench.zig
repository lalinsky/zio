const std = @import("std");
const zio = @import("zio");
const Runtime = zio.Runtime;
const ConcurrentQueue = @import("zio").ConcurrentQueue;
const CompactConcurrentQueue = @import("zio").CompactConcurrentQueue;

const StandardNode = struct {
    next: ?*@This() = null,
    prev: ?*@This() = null,
    in_list: bool = false,
    value: usize,
};

const CompactNode = struct {
    next: ?*@This() = null,
    prev: ?*@This() = null,
    tail: ?*@This() = null,
    in_list: bool = false,
    value: usize,
};

fn benchmarkStandardQueue(allocator: std.mem.Allocator, num_operations: usize) !u64 {
    const Queue = ConcurrentQueue(StandardNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(StandardNode, num_operations);
    defer allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    // Push all items
    for (nodes) |*n| {
        queue.push(n);
    }

    // Pop all items
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed = timer.read();

    if (count != num_operations) {
        return error.IncorrectCount;
    }

    return elapsed;
}

fn benchmarkCompactQueue(allocator: std.mem.Allocator, num_operations: usize) !u64 {
    const Queue = CompactConcurrentQueue(CompactNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(CompactNode, num_operations);
    defer allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    // Push all items
    for (nodes) |*n| {
        queue.push(n);
    }

    // Pop all items
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed = timer.read();

    if (count != num_operations) {
        return error.IncorrectCount;
    }

    return elapsed;
}

fn benchmarkStandardQueueConcurrent(allocator: std.mem.Allocator, num_threads: usize, ops_per_thread: usize) !u64 {
    const Queue = ConcurrentQueue(StandardNode);
    var queue: Queue = .empty;

    const total_ops = num_threads * ops_per_thread;
    const nodes = try allocator.alloc(StandardNode, total_ops);
    defer allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    // Spawn threads to push items
    for (0..num_threads) |i| {
        const start = i * ops_per_thread;
        const end = (i + 1) * ops_per_thread;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(q: *Queue, items: []StandardNode) void {
                for (items) |*item| {
                    q.push(item);
                }
            }
        }.pushItems, .{ &queue, nodes[start..end] });
    }

    for (threads) |t| {
        t.join();
    }

    // Pop all items in main thread
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed = timer.read();

    if (count != total_ops) {
        return error.IncorrectCount;
    }

    return elapsed;
}

fn benchmarkCompactQueueConcurrent(allocator: std.mem.Allocator, num_threads: usize, ops_per_thread: usize) !u64 {
    const Queue = CompactConcurrentQueue(CompactNode);
    var queue: Queue = .empty;

    const total_ops = num_threads * ops_per_thread;
    const nodes = try allocator.alloc(CompactNode, total_ops);
    defer allocator.free(nodes);

    for (nodes, 0..) |*n, i| {
        n.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    // Spawn threads to push items
    for (0..num_threads) |i| {
        const start = i * ops_per_thread;
        const end = (i + 1) * ops_per_thread;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(q: *Queue, items: []CompactNode) void {
                for (items) |*item| {
                    q.push(item);
                }
            }
        }.pushItems, .{ &queue, nodes[start..end] });
    }

    for (threads) |t| {
        t.join();
    }

    // Pop all items in main thread
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed = timer.read();

    if (count != total_ops) {
        return error.IncorrectCount;
    }

    return elapsed;
}

fn formatNs(ns: u64) void {
    if (ns < 1000) {
        std.debug.print("{d}ns", .{ns});
    } else if (ns < 1_000_000) {
        std.debug.print("{d:.2}µs", .{@as(f64, @floatFromInt(ns)) / 1000.0});
    } else if (ns < 1_000_000_000) {
        std.debug.print("{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        std.debug.print("{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn runBenchmark(comptime name: []const u8, allocator: std.mem.Allocator, comptime bench_fn: fn (std.mem.Allocator, usize) anyerror!u64, num_operations: usize, iterations: usize) !void {
    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    for (0..iterations) |_| {
        const elapsed = try bench_fn(allocator, num_operations);
        total += elapsed;
        if (elapsed < min) min = elapsed;
        if (elapsed > max) max = elapsed;
    }

    const avg = total / iterations;
    const ops_per_sec = @as(f64, @floatFromInt(num_operations)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0);

    std.debug.print("{s}:\n", .{name});
    std.debug.print("  Avg: ", .{});
    formatNs(avg);
    std.debug.print(" ({d:.0} ops/sec)\n", .{ops_per_sec});
    std.debug.print("  Min: ", .{});
    formatNs(min);
    std.debug.print("\n", .{});
    std.debug.print("  Max: ", .{});
    formatNs(max);
    std.debug.print("\n\n", .{});
}

fn runConcurrentBenchmark(comptime name: []const u8, allocator: std.mem.Allocator, comptime bench_fn: fn (std.mem.Allocator, usize, usize) anyerror!u64, num_threads: usize, ops_per_thread: usize, iterations: usize) !void {
    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;

    for (0..iterations) |_| {
        const elapsed = try bench_fn(allocator, num_threads, ops_per_thread);
        total += elapsed;
        if (elapsed < min) min = elapsed;
        if (elapsed > max) max = elapsed;
    }

    const avg = total / iterations;
    const total_ops = num_threads * ops_per_thread;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(avg)) / 1_000_000_000.0);

    std.debug.print("{s}:\n", .{name});
    std.debug.print("  Avg: ", .{});
    formatNs(avg);
    std.debug.print(" ({d:.0} ops/sec)\n", .{ops_per_sec});
    std.debug.print("  Min: ", .{});
    formatNs(min);
    std.debug.print("\n", .{});
    std.debug.print("  Max: ", .{});
    formatNs(max);
    std.debug.print("\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const num_operations = 10_000;
    const iterations = 100;

    std.debug.print("=== ConcurrentQueue Benchmark ===\n\n", .{});
    std.debug.print("Queue sizes:\n", .{});
    std.debug.print("  Standard:    {d} bytes\n", .{@sizeOf(ConcurrentQueue(StandardNode))});
    std.debug.print("  Compact:     {d} bytes\n\n", .{@sizeOf(CompactConcurrentQueue(CompactNode))});

    std.debug.print("Node sizes:\n", .{});
    std.debug.print("  Standard:    {d} bytes\n", .{@sizeOf(StandardNode)});
    std.debug.print("  Compact:     {d} bytes\n\n", .{@sizeOf(CompactNode)});

    std.debug.print("Single-threaded ({d} operations, {d} iterations):\n\n", .{ num_operations, iterations });

    try runBenchmark("Standard Queue", allocator, benchmarkStandardQueue, num_operations, iterations);
    try runBenchmark("Compact Queue", allocator, benchmarkCompactQueue, num_operations, iterations);

    const num_threads = 4;
    const ops_per_thread = 2_500;
    const concurrent_iterations = 50;

    std.debug.print("Concurrent ({d} threads × {d} ops, {d} iterations):\n\n", .{ num_threads, ops_per_thread, concurrent_iterations });

    try runConcurrentBenchmark("Standard Queue (concurrent)", allocator, benchmarkStandardQueueConcurrent, num_threads, ops_per_thread, concurrent_iterations);
    try runConcurrentBenchmark("Compact Queue (concurrent)", allocator, benchmarkCompactQueueConcurrent, num_threads, ops_per_thread, concurrent_iterations);
}
