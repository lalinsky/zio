const std = @import("std");
const print = std.debug.print;
const builtin = @import("builtin");
const zio = @import("zio");

fn getTimestamp() u64 {
    return @intCast(std.time.milliTimestamp());
}

var start_time: u64 = 0;

fn task1() void {
    const elapsed = getTimestamp() - start_time;
    print("[{}ms] Task 1: Starting\n", .{elapsed});

    zio.sleep(1000) catch |err| {
        print("Task 1: Sleep error: {}\n", .{err});
        return;
    };

    const elapsed2 = getTimestamp() - start_time;
    print("[{}ms] Task 1: After 1 second sleep\n", .{elapsed2});

    zio.sleep(500) catch |err| {
        print("Task 1: Sleep error: {}\n", .{err});
        return;
    };

    const elapsed3 = getTimestamp() - start_time;
    print("[{}ms] Task 1: Finished\n", .{elapsed3});
}

fn task2(name: []const u8, sleep_ms: u64) void {
    print("{s}: Starting\n", .{name});

    for (0..3) |i| {
        print("{s}: Iteration {}\n", .{ name, i });

        zio.sleep(sleep_ms) catch |err| {
            print("{s}: Sleep error: {}\n", .{ name, err });
            return;
        };
    }

    print("{s}: Finished\n", .{name});
}

fn quickTask(id: u32) void {
    print("Quick task {}: Running\n", .{id});

    zio.sleep(200) catch |err| {
        print("Quick task {}: Sleep error: {}\n", .{ id, err });
        return;
    };

    print("Quick task {}: Done\n", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zio runtime
    try zio.init(allocator);
    defer zio.deinit();

    print("=== ZIO Sleep Demo ===\n", .{});
    print("Platform: {s} {s}\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    print("Starting coroutines with async sleep...\n\n", .{});

    start_time = getTimestamp();

    // Spawn various coroutines with different sleep patterns
    _ = try zio.spawn(task1, .{});
    _ = try zio.spawn(task2, .{ "Worker-A", @as(u64, 800) });
    _ = try zio.spawn(task2, .{ "Worker-B", @as(u64, 600) });

    // Spawn several quick tasks
    for (1..4) |i| {
        _ = try zio.spawn(quickTask, .{@as(u32, @intCast(i))});
    }

    // Run the event loop
    zio.run();

    print("\nAll coroutines completed!\n", .{});
}