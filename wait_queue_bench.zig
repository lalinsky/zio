// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const wait_queue = @import("src/utils/wait_queue.zig");
const SimpleWaitQueue = wait_queue.SimpleWaitQueue;
const WaitQueue = wait_queue.WaitQueue;
const CompactWaitQueue = wait_queue.CompactWaitQueue;

const NUM_THREADS = 8;
const OPS_PER_THREAD = 100_000;
const TOTAL_OPS = NUM_THREADS * OPS_PER_THREAD;

const TestNode = struct {
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
    userdata: usize = 0,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
    value: usize,
};

const BenchResult = struct {
    name: []const u8,
    total_ops: usize,
    elapsed_ns: u64,
    ops_per_sec: f64,
    ns_per_op: f64,
};

fn printResult(result: BenchResult) void {
    std.debug.print("  {s}:\n", .{result.name});
    std.debug.print("    Total ops:    {}\n", .{result.total_ops});
    std.debug.print("    Total time:   {d:.2} ms\n", .{@as(f64, @floatFromInt(result.elapsed_ns)) / 1_000_000.0});
    std.debug.print("    Time per op:  {d:.0} ns\n", .{result.ns_per_op});
    std.debug.print("    Ops/sec:      {d:.0}\n", .{result.ops_per_sec});
}

fn benchmarkWaitQueuePushPop(allocator: std.mem.Allocator) !BenchResult {
    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    // Allocate all nodes upfront
    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    // Phase 1: All threads push concurrently
    var push_threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        push_threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(q: *Queue, items: []TestNode) void {
                for (items) |*item| {
                    q.push(item);
                }
            }
        }.pushItems, .{ &queue, nodes[start..end] });
    }

    for (push_threads) |t| {
        t.join();
    }

    // Phase 2: All threads pop concurrently
    var pop_count = std.atomic.Value(usize).init(0);
    var pop_threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        pop_threads[i] = try std.Thread.spawn(.{}, struct {
            fn popItems(q: *Queue, count: *std.atomic.Value(usize)) void {
                var local_count: usize = 0;
                while (q.pop()) |_| {
                    local_count += 1;
                }
                _ = count.fetchAdd(local_count, .monotonic);
            }
        }.popItems, .{ &queue, &pop_count });
    }

    for (pop_threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_ops_done = pop_count.load(.monotonic);

    return .{
        .name = "WaitQueue push/pop",
        .total_ops = total_ops_done,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops_done)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops_done)),
    };
}

fn benchmarkCompactWaitQueuePushPop(allocator: std.mem.Allocator) !BenchResult {
    const Queue = CompactWaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    var push_threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        push_threads[i] = try std.Thread.spawn(.{}, struct {
            fn pushItems(q: *Queue, items: []TestNode) void {
                for (items) |*item| {
                    q.push(item);
                }
            }
        }.pushItems, .{ &queue, nodes[start..end] });
    }

    for (push_threads) |t| {
        t.join();
    }

    var pop_count = std.atomic.Value(usize).init(0);
    var pop_threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        pop_threads[i] = try std.Thread.spawn(.{}, struct {
            fn popItems(q: *Queue, count: *std.atomic.Value(usize)) void {
                var local_count: usize = 0;
                while (q.pop()) |_| {
                    local_count += 1;
                }
                _ = count.fetchAdd(local_count, .monotonic);
            }
        }.popItems, .{ &queue, &pop_count });
    }

    for (pop_threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_ops_done = pop_count.load(.monotonic);

    return .{
        .name = "CompactWaitQueue push/pop",
        .total_ops = total_ops_done,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops_done)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops_done)),
    };
}

fn benchmarkWaitQueueMixed(allocator: std.mem.Allocator) !BenchResult {
    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    const ThreadCounts = struct {
        pushed: std.atomic.Value(usize),
        popped: std.atomic.Value(usize),
        removed: std.atomic.Value(usize),
    };
    var threads: [NUM_THREADS]std.Thread = undefined;
    var counts: [NUM_THREADS]ThreadCounts = undefined;

    for (0..NUM_THREADS) |i| {
        counts[i] = .{
            .pushed = std.atomic.Value(usize).init(0),
            .popped = std.atomic.Value(usize).init(0),
            .removed = std.atomic.Value(usize).init(0),
        };
    }

    for (0..NUM_THREADS) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn mixedOps(q: *Queue, my_items: []TestNode, all_items: []TestNode, thread_counts: *ThreadCounts, thread_id: usize) void {
                var local_pushed: usize = 0;
                var local_popped: usize = 0;
                var local_removed: usize = 0;

                // Push all my items first
                for (my_items) |*item| {
                    q.push(item);
                    local_pushed += 1;
                }

                // Now do mixed pop and remove operations
                for (0..my_items.len / 2) |j| {
                    // Try to pop
                    if (q.pop()) |_| {
                        local_popped += 1;
                    }

                    // Try to remove a specific item (based on thread_id to avoid too much collision)
                    const idx = (thread_id * 7919 + j * 31) % all_items.len;
                    if (q.remove(&all_items[idx])) {
                        local_removed += 1;
                    }
                }

                thread_counts.pushed.store(local_pushed, .monotonic);
                thread_counts.popped.store(local_popped, .monotonic);
                thread_counts.removed.store(local_removed, .monotonic);
            }
        }.mixedOps, .{ &queue, nodes[start..end], nodes, &counts[i], i });
    }

    for (threads) |t| {
        t.join();
    }

    // Drain remaining
    var remaining: usize = 0;
    while (queue.pop()) |_| {
        remaining += 1;
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    var total_ops: usize = 0;
    for (&counts) |*c| {
        total_ops += c.pushed.load(.monotonic);
        total_ops += c.popped.load(.monotonic);
        total_ops += c.removed.load(.monotonic);
    }

    return .{
        .name = "WaitQueue mixed ops",
        .total_ops = total_ops,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops)),
    };
}

fn benchmarkCompactWaitQueueMixed(allocator: std.mem.Allocator) !BenchResult {
    const Queue = CompactWaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    const ThreadCounts = struct {
        pushed: std.atomic.Value(usize),
        popped: std.atomic.Value(usize),
        removed: std.atomic.Value(usize),
    };
    var threads: [NUM_THREADS]std.Thread = undefined;
    var counts: [NUM_THREADS]ThreadCounts = undefined;

    for (0..NUM_THREADS) |i| {
        counts[i] = .{
            .pushed = std.atomic.Value(usize).init(0),
            .popped = std.atomic.Value(usize).init(0),
            .removed = std.atomic.Value(usize).init(0),
        };
    }

    for (0..NUM_THREADS) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn mixedOps(q: *Queue, my_items: []TestNode, all_items: []TestNode, thread_counts: *ThreadCounts, thread_id: usize) void {
                var local_pushed: usize = 0;
                var local_popped: usize = 0;
                var local_removed: usize = 0;

                for (my_items) |*item| {
                    q.push(item);
                    local_pushed += 1;
                }

                for (0..my_items.len / 2) |j| {
                    if (q.pop()) |_| {
                        local_popped += 1;
                    }

                    const idx = (thread_id * 7919 + j * 31) % all_items.len;
                    if (q.remove(&all_items[idx])) {
                        local_removed += 1;
                    }
                }

                thread_counts.pushed.store(local_pushed, .monotonic);
                thread_counts.popped.store(local_popped, .monotonic);
                thread_counts.removed.store(local_removed, .monotonic);
            }
        }.mixedOps, .{ &queue, nodes[start..end], nodes, &counts[i], i });
    }

    for (threads) |t| {
        t.join();
    }

    var remaining: usize = 0;
    while (queue.pop()) |_| {
        remaining += 1;
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    var total_ops: usize = 0;
    for (&counts) |*c| {
        total_ops += c.pushed.load(.monotonic);
        total_ops += c.popped.load(.monotonic);
        total_ops += c.removed.load(.monotonic);
    }

    return .{
        .name = "CompactWaitQueue mixed ops",
        .total_ops = total_ops,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops)),
    };
}

// Single-threaded benchmarks
const SINGLE_THREAD_OPS = 1_000_000;

fn benchmarkSimpleWaitQueueSingleThreaded(allocator: std.mem.Allocator) !BenchResult {
    const SimpleNode = struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
        value: usize,
    };

    const Queue = SimpleWaitQueue(SimpleNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(SimpleNode, SINGLE_THREAD_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    // Push all
    for (nodes) |*node| {
        queue.push(node);
    }

    // Pop all
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    return .{
        .name = "SimpleWaitQueue (single-threaded)",
        .total_ops = count,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkWaitQueueSingleThreaded(allocator: std.mem.Allocator) !BenchResult {
    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, SINGLE_THREAD_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    for (nodes) |*node| {
        queue.push(node);
    }

    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    return .{
        .name = "WaitQueue (single-threaded)",
        .total_ops = count,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkCompactWaitQueueSingleThreaded(allocator: std.mem.Allocator) !BenchResult {
    const Queue = CompactWaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, SINGLE_THREAD_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    for (nodes) |*node| {
        queue.push(node);
    }

    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    return .{
        .name = "CompactWaitQueue (single-threaded)",
        .total_ops = count,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(count)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(count)),
    };
}

fn benchmarkWaitQueueProducerConsumer(allocator: std.mem.Allocator) !BenchResult {
    const Queue = WaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    // Half threads as producers, half as consumers
    const num_producers = NUM_THREADS / 2;
    const num_consumers = NUM_THREADS - num_producers;

    var threads: [NUM_THREADS]std.Thread = undefined;

    // Producer threads
    for (0..num_producers) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn produce(q: *Queue, items: []TestNode, counter: *std.atomic.Value(usize)) void {
                for (items) |*item| {
                    q.push(item);
                    _ = counter.fetchAdd(1, .monotonic);
                }
            }
        }.produce, .{ &queue, nodes[start..end], &produced });
    }

    // Consumer threads
    for (0..num_consumers) |i| {
        threads[num_producers + i] = try std.Thread.spawn(.{}, struct {
            fn consume(q: *Queue, counter: *std.atomic.Value(usize), target: usize) void {
                while (counter.load(.monotonic) < target) {
                    if (q.pop()) |_| {
                        _ = counter.fetchAdd(1, .monotonic);
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.consume, .{ &queue, &consumed, num_producers * OPS_PER_THREAD });
    }

    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_ops = produced.load(.monotonic) + consumed.load(.monotonic);

    return .{
        .name = "WaitQueue producer/consumer",
        .total_ops = total_ops,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops)),
    };
}

fn benchmarkCompactWaitQueueProducerConsumer(allocator: std.mem.Allocator) !BenchResult {
    const Queue = CompactWaitQueue(TestNode);
    var queue: Queue = .empty;

    const nodes = try allocator.alloc(TestNode, TOTAL_OPS);
    defer allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{ .value = i };
    }

    var timer = try std.time.Timer.start();

    var produced = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    const num_producers = NUM_THREADS / 2;
    const num_consumers = NUM_THREADS - num_producers;

    var threads: [NUM_THREADS]std.Thread = undefined;

    for (0..num_producers) |i| {
        const start = i * OPS_PER_THREAD;
        const end = (i + 1) * OPS_PER_THREAD;
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn produce(q: *Queue, items: []TestNode, counter: *std.atomic.Value(usize)) void {
                for (items) |*item| {
                    q.push(item);
                    _ = counter.fetchAdd(1, .monotonic);
                }
            }
        }.produce, .{ &queue, nodes[start..end], &produced });
    }

    for (0..num_consumers) |i| {
        threads[num_producers + i] = try std.Thread.spawn(.{}, struct {
            fn consume(q: *Queue, counter: *std.atomic.Value(usize), target: usize) void {
                while (counter.load(.monotonic) < target) {
                    if (q.pop()) |_| {
                        _ = counter.fetchAdd(1, .monotonic);
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
            }
        }.consume, .{ &queue, &consumed, num_producers * OPS_PER_THREAD });
    }

    for (threads) |t| {
        t.join();
    }

    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total_ops = produced.load(.monotonic) + consumed.load(.monotonic);

    return .{
        .name = "CompactWaitQueue producer/consumer",
        .total_ops = total_ops,
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(total_ops)) / elapsed_s,
        .ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops)),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== WaitQueue vs CompactWaitQueue Benchmark ===\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Threads:          {}\n", .{NUM_THREADS});
    std.debug.print("  Ops per thread:   {}\n", .{OPS_PER_THREAD});
    std.debug.print("  Total ops:        {}\n", .{TOTAL_OPS});
    std.debug.print("  Single-thread ops: {}\n\n", .{SINGLE_THREAD_OPS});

    std.debug.print("Running benchmarks...\n\n", .{});

    // Scenario 0: Single-threaded (no contention, shows atomic overhead)
    std.debug.print("Scenario 0: Single-threaded push/pop (no contention)\n", .{});
    const simple_single = try benchmarkSimpleWaitQueueSingleThreaded(allocator);
    printResult(simple_single);
    std.debug.print("\n", .{});

    const wq_single = try benchmarkWaitQueueSingleThreaded(allocator);
    printResult(wq_single);
    std.debug.print("\n", .{});

    const cwq_single = try benchmarkCompactWaitQueueSingleThreaded(allocator);
    printResult(cwq_single);

    const overhead_wq = wq_single.ns_per_op / simple_single.ns_per_op;
    const overhead_cwq = cwq_single.ns_per_op / simple_single.ns_per_op;
    std.debug.print("  Atomic overhead:  WaitQueue={d:.2}x, CompactWaitQueue={d:.2}x\n", .{ overhead_wq, overhead_cwq });

    const speedup_single = wq_single.ops_per_sec / cwq_single.ops_per_sec;
    std.debug.print("  Speedup:          {d:.2}x ", .{speedup_single});
    if (speedup_single > 1.0) {
        std.debug.print("(WaitQueue faster)\n\n", .{});
    } else {
        std.debug.print("(CompactWaitQueue faster)\n\n", .{});
    }

    // Scenario 1: Pure push/pop (best case - all operations succeed)
    std.debug.print("Scenario 1: Pure push/pop throughput\n", .{});
    const wq_pushpop = try benchmarkWaitQueuePushPop(allocator);
    printResult(wq_pushpop);
    std.debug.print("\n", .{});

    const cwq_pushpop = try benchmarkCompactWaitQueuePushPop(allocator);
    printResult(cwq_pushpop);
    const speedup_pushpop = wq_pushpop.ops_per_sec / cwq_pushpop.ops_per_sec;
    std.debug.print("  Speedup:          {d:.2}x ", .{speedup_pushpop});
    if (speedup_pushpop > 1.0) {
        std.debug.print("(WaitQueue faster)\n\n", .{});
    } else {
        std.debug.print("(CompactWaitQueue faster)\n\n", .{});
    }

    // Scenario 2: Producer/consumer pattern
    std.debug.print("Scenario 2: Producer/consumer (concurrent push/pop)\n", .{});
    const wq_prodcon = try benchmarkWaitQueueProducerConsumer(allocator);
    printResult(wq_prodcon);
    std.debug.print("\n", .{});

    const cwq_prodcon = try benchmarkCompactWaitQueueProducerConsumer(allocator);
    printResult(cwq_prodcon);
    const speedup_prodcon = wq_prodcon.ops_per_sec / cwq_prodcon.ops_per_sec;
    std.debug.print("  Speedup:          {d:.2}x ", .{speedup_prodcon});
    if (speedup_prodcon > 1.0) {
        std.debug.print("(WaitQueue faster)\n\n", .{});
    } else {
        std.debug.print("(CompactWaitQueue faster)\n\n", .{});
    }

    // Scenario 3: Mixed operations (more realistic with contention)
    std.debug.print("Scenario 3: Mixed push/pop/remove operations\n", .{});
    const wq_mixed = try benchmarkWaitQueueMixed(allocator);
    printResult(wq_mixed);
    std.debug.print("\n", .{});

    const cwq_mixed = try benchmarkCompactWaitQueueMixed(allocator);
    printResult(cwq_mixed);
    const speedup_mixed = wq_mixed.ops_per_sec / cwq_mixed.ops_per_sec;
    std.debug.print("  Speedup:          {d:.2}x ", .{speedup_mixed});
    if (speedup_mixed > 1.0) {
        std.debug.print("(WaitQueue faster)\n\n", .{});
    } else {
        std.debug.print("(CompactWaitQueue faster)\n\n", .{});
    }

    // Summary
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Queue sizes:\n", .{});
    std.debug.print("  SimpleWaitQueue:   16 bytes (non-atomic, needs external lock)\n", .{});
    std.debug.print("  WaitQueue:         16 bytes (atomic head, separate tail)\n", .{});
    std.debug.print("  CompactWaitQueue:  8 bytes (atomic head, tail in head.userdata)\n", .{});
    std.debug.print("\nPerformance comparison (WaitQueue / CompactWaitQueue):\n", .{});
    std.debug.print("  Single-threaded: {d:.2}x\n", .{speedup_single});
    std.debug.print("  Push/pop:        {d:.2}x\n", .{speedup_pushpop});
    std.debug.print("  Producer/cons:   {d:.2}x\n", .{speedup_prodcon});
    std.debug.print("  Mixed ops:       {d:.2}x\n", .{speedup_mixed});
}
