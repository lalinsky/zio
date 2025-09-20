const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");
const zio = @import("zio");

fn getTimestamp() u64 {
    return @intCast(std.time.milliTimestamp());
}

var start_time: u64 = 0;

fn task1(runtime: *zio.Runtime) void {
    const elapsed = getTimestamp() - start_time;
    print("[{}ms] Task 1: Starting\n", .{elapsed});

    runtime.sleep(1000) catch |err| {
        print("Task 1: Sleep error: {}\n", .{err});
        return;
    };

    const elapsed2 = getTimestamp() - start_time;
    print("[{}ms] Task 1: After 1 second sleep\n", .{elapsed2});

    runtime.sleep(500) catch |err| {
        print("Task 1: Sleep error: {}\n", .{err});
        return;
    };

    const elapsed3 = getTimestamp() - start_time;
    print("[{}ms] Task 1: Finished\n", .{elapsed3});
}

fn task2(runtime: *zio.Runtime, name: []const u8, sleep_ms: u64) void {
    print("{s}: Starting\n", .{name});

    for (0..3) |i| {
        print("{s}: Iteration {}\n", .{ name, i });

        runtime.sleep(sleep_ms) catch |err| {
            print("{s}: Sleep error: {}\n", .{ name, err });
            return;
        };
    }

    print("{s}: Finished\n", .{name});
}

fn quickTask(runtime: *zio.Runtime, id: u32) void {
    print("Quick task {}: Running\n", .{id});

    runtime.sleep(200) catch |err| {
        print("Quick task {}: Sleep error: {}\n", .{ id, err });
        return;
    };

    print("Quick task {}: Done\n", .{id});
}

pub fn spawnAndWait(runtime: *zio.Runtime) !void {
    const t1 = try runtime.spawn(task1, .{runtime}, .{});
    print("waiting on task t1\n", .{});
    runtime.wait(t1);
    print("done task t1\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zio runtime
    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    print("=== ZIO Sleep Demo ===\n", .{});
    print("Platform: {s} {s}\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    print("Starting coroutines with async sleep...\n\n", .{});

    start_time = getTimestamp();

    // Spawn various coroutines with different sleep patterns
    _ = try runtime.spawn(task1, .{&runtime}, .{});
    _ = try runtime.spawn(task2, .{ &runtime, "Worker-A", @as(u64, 800) }, .{});
    _ = try runtime.spawn(task2, .{ &runtime, "Worker-B", @as(u64, 600) }, .{});

    // Spawn several quick tasks
    for (1..4) |i| {
        _ = try runtime.spawn(quickTask, .{ &runtime, @as(u32, @intCast(i)) }, .{});
    }

    _ = try runtime.spawn(spawnAndWait, .{&runtime}, .{});
    // Run the event loop
    runtime.run();

    print("\nAll coroutines completed!\n", .{});
}
