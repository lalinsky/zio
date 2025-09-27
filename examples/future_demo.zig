const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn cpuIntensiveWork(name: []const u8, iterations: u32) i32 {
    print("{s}: Starting CPU work with {} iterations\n", .{ name, iterations });

    var sum: i32 = 0;
    for (0..iterations) |i| {
        // Simulate some CPU-intensive work
        sum +%= @intCast(i % 1000); // Use wrapping add to prevent overflow
        if (i % 500000 == 0) {
            print("{s}: Progress {}/{}...\n", .{ name, i, iterations });
        }
    }

    print("{s}: Completed! Sum = {}\n", .{ name, sum });
    return sum;
}

fn errorWork(should_fail: bool) !i32 {
    if (should_fail) {
        return error.WorkFailed;
    }
    print("Error work completed successfully\n", .{});
    return 42;
}

fn voidWork(message: []const u8) void {
    print("Void work: {s}\n", .{message});
}

fn futureDemo(runtime: *zio.Runtime) !void {
    print("FutureDemo: Starting future demonstration\n", .{});

    // Spawn multiple CPU-intensive tasks
    const future1 = try runtime.spawnInThread(cpuIntensiveWork, .{ "Task-1", @as(u32, 2000000) });
    const future2 = try runtime.spawnInThread(cpuIntensiveWork, .{ "Task-2", @as(u32, 1500000) });
    const future3 = try runtime.spawnInThread(cpuIntensiveWork, .{ "Task-3", @as(u32, 1000000) });

    // Spawn error work futures
    const future4 = try runtime.spawnInThread(errorWork, .{false});
    const future5 = try runtime.spawnInThread(errorWork, .{true});

    // Spawn void work future
    const future6 = try runtime.spawnInThread(voidWork, .{"Hello from future!"});

    print("Spawned 6 futures, now doing other work while they run...\n", .{});

    // Do some other work while futures are running
    try runtime.sleep(100);
    print("Did some intermediate work, checking futures...\n", .{});

    // Check which futures are ready without blocking
    print("Future 1 ready: {}\n", .{future1.isReady()});
    print("Future 2 ready: {}\n", .{future2.isReady()});
    print("Future 3 ready: {}\n", .{future3.isReady()});

    // Wait for results - this will block until each future completes
    print("Waiting for results...\n", .{});

    const result1 = try future1.wait();
    print("Future 1 result: {}\n", .{result1});

    const result2 = try future2.wait();
    print("Future 2 result: {}\n", .{result2});

    const result3 = try future3.wait();
    print("Future 3 result: {}\n", .{result3});

    // Handle error future
    if (future4.wait()) |result4| {
        print("Future 4 result: {}\n", .{result4});
    } else |err| {
        print("Future 4 error: {}\n", .{err});
    }

    // Handle failing future
    if (future5.wait()) |result5| {
        print("Future 5 result: {}\n", .{result5});
    } else |err| {
        print("Future 5 error: {}\n", .{err});
    }

    // Wait for void future
    try future6.wait();
    print("Future 6 (void) completed\n", .{});

    print("FutureDemo: All futures completed!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zio runtime
    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    print("=== ZIO Future Demo ===\n\n", .{});

    // Spawn the demo coroutine
    _ = try runtime.spawn(futureDemo, .{&runtime});

    print("Spawned future demo coroutine\n\n", .{});

    // Run the event loop
    runtime.run();

    print("\nFuture demo completed!\n", .{});
}