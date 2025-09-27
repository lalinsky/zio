const std = @import("std");
const zio = @import("zio");
const Runtime = zio.Runtime;

fn computeIntensiveSync(n: u32) u32 {
    // Simulate CPU-intensive work
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        sum += i;
    }
    return sum;
}

fn asyncTask(rt: *Runtime) void {
    std.debug.print("Async task starting\n", .{});
    rt.sleep(100);
    std.debug.print("Async task after sleep\n", .{});
}

fn blockingExample(rt: *Runtime) !void {
    std.debug.print("Starting blocking example\n", .{});

    // Spawn a blocking task that runs in thread pool
    var handle = try rt.spawnBlocking(computeIntensiveSync, .{1000000});
    defer handle.detach();

    // Spawn an async task that should not be blocked
    var async_task = try rt.spawn(asyncTask, .{rt}, .{});
    defer async_task.detach();

    std.debug.print("Waiting for blocking task result...\n", .{});
    const result = handle.join();
    std.debug.print("Blocking task completed with result: {}\n", .{result});

    // Wait for async task to complete
    _ = async_task.join();
    std.debug.print("Both tasks completed\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    _ = try runtime.spawn(blockingExample, .{&runtime}, .{});
    try runtime.run();

    std.debug.print("All done!\n", .{});
}