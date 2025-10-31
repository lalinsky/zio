// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const zio = @import("zio");
const Runtime = zio.Runtime;
const WaitQueue = zio.util.WaitQueue;

const StandardNode = struct {
    next: ?*@This() = null,
    prev: ?*@This() = null,
    in_list: bool = false,
    value: usize,
};

fn benchmarkStandardQueue(allocator: std.mem.Allocator, num_operations: usize) !u64 {
    const Queue = WaitQueue(StandardNode);
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

fn benchmarkStandardQueueConcurrent(allocator: std.mem.Allocator, num_threads: usize, ops_per_thread: usize) !u64 {
    const Queue = WaitQueue(StandardNode);
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

    const runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const num_operations = 10_000;
    const iterations = 100;

    std.debug.print("=== WaitQueue Benchmark ===\n\n", .{});
    std.debug.print("Queue size: {d} bytes\n", .{@sizeOf(WaitQueue(StandardNode))});
    std.debug.print("Node size:  {d} bytes\n\n", .{@sizeOf(StandardNode)});

    std.debug.print("Single-threaded ({d} operations, {d} iterations):\n\n", .{ num_operations, iterations });

    try runBenchmark("WaitQueue", allocator, benchmarkStandardQueue, num_operations, iterations);

    const num_threads = try std.Thread.getCpuCount();
    const ops_per_thread = 2_500;
    const concurrent_iterations = 50;

    std.debug.print("Concurrent ({d} threads × {d} ops, {d} iterations):\n\n", .{ num_threads, ops_per_thread, concurrent_iterations });

    try runConcurrentBenchmark("WaitQueue (concurrent)", allocator, benchmarkStandardQueueConcurrent, num_threads, ops_per_thread, concurrent_iterations);
}
