const std = @import("std");
const zio = @import("zio");

fn task1() void {
    std.debug.print("Task 1 start\n", .{});
    zio.yield();
    std.debug.print("Task 1 middle\n", .{});
    zio.yield();
    std.debug.print("Task 1 end\n", .{});
}

fn task2() void {
    std.debug.print("Task 2 start\n", .{});
    zio.yield();
    std.debug.print("Task 2 middle\n", .{});
    zio.yield();
    std.debug.print("Task 2 end\n", .{});
}

fn task3() void {
    std.debug.print("Task 3 start\n", .{});
    zio.yield();
    std.debug.print("Task 3 end\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    zio.init(allocator);
    defer zio.deinit();

    std.debug.print("Starting virtual thread demo\n", .{});

    try zio.spawn(task1);
    try zio.spawn(task2);
    try zio.spawn(task3);

    zio.run();

    std.debug.print("All tasks completed\n", .{});
}
