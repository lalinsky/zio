const std = @import("std");

var task_state: u32 = 0;

fn zio_spawn(comptime func: fn() void) void {
    func();
}

fn zio_yield() void {
    std.debug.print("  [yield called]\n", .{});
}

fn task1() void {
    std.debug.print("Task 1: Start\n", .{});
    zio_yield();
    std.debug.print("Task 1: Middle\n", .{});
    zio_yield();
    std.debug.print("Task 1: End\n", .{});
}

fn task2() void {
    std.debug.print("Task 2: Start\n", .{});
    zio_yield();
    std.debug.print("Task 2: End\n", .{});
}

pub fn main() !void {
    std.debug.print("=== ZIO Virtual Threads Demo ===\n", .{});
    std.debug.print("(Simplified version showing the API)\n\n", .{});

    std.debug.print("Spawning task 1:\n", .{});
    zio_spawn(task1);

    std.debug.print("\nSpawning task 2:\n", .{});
    zio_spawn(task2);

    std.debug.print("\n=== Demo complete! ===\n", .{});
    std.debug.print("\nThis shows the basic zio.spawn() and zio.yield() API.\n", .{});
    std.debug.print("Next step: Add real context switching between tasks.\n", .{});
}