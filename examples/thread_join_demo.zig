const std = @import("std");
const zio = @import("zio");

fn workerTask(rt: *zio.Runtime) u32 {
    _ = rt;
    std.log.info("Worker task running in coroutine", .{});
    std.time.sleep(10 * std.time.ns_per_ms);
    return 42;
}

fn runRuntimeInThread(runtime: *zio.Runtime) !void {
    try runtime.run();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    // Spawn a task
    var task = try runtime.spawn(workerTask, .{&runtime}, .{});
    defer task.deinit();

    std.log.info("Main thread: spawned task, now starting runtime in background thread", .{});

    // Run the runtime in a background thread
    const runtime_thread = try std.Thread.spawn(.{}, runRuntimeInThread, .{&runtime});

    // Wait for a moment to let the runtime start
    std.time.sleep(5 * std.time.ns_per_ms);

    std.log.info("Main thread: calling task.join() from main thread (NOT a coroutine)", .{});

    // This is the key feature: join() works from a regular thread!
    const result = task.join();

    std.log.info("Main thread: task.join() returned: {}", .{result});

    // Wait for runtime thread to finish
    runtime_thread.join();

    std.log.info("Success! task.join() worked from main thread", .{});
}
