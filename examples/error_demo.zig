const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn voidTask(runtime: *zio.Runtime, name: []const u8) void {
    print("{s}: Starting (void return)\n", .{name});

    runtime.sleep(500) catch |err| {
        print("{s}: Sleep error: {}\n", .{ name, err });
        return;
    };

    print("{s}: Completed successfully\n", .{name});
}

fn errorTask(runtime: *zio.Runtime, name: []const u8, should_fail: bool) !void {
    print("{s}: Starting (error return)\n", .{name});

    try runtime.sleep(300);

    if (should_fail) {
        print("{s}: Returning error\n", .{name});
        return error.TestError;
    }

    print("{s}: Completed successfully\n", .{name});
}

fn intTask(runtime: *zio.Runtime, name: []const u8, value: i32) i32 {
    print("{s}: Starting (int return)\n", .{name});

    runtime.sleep(400) catch |err| {
        print("{s}: Sleep error: {}\n", .{ name, err });
        return -1;
    };

    print("{s}: Returning value {}\n", .{ name, value });
    return value * 2;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zio runtime
    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    print("=== ZIO Error Handling Demo ===\n\n", .{});

    // Spawn different types of coroutines
    const task1 = try runtime.spawn(voidTask, .{ &runtime, "VoidTask" }, .{});
    defer task1.deinit();
    const task2 = try runtime.spawn(errorTask, .{ &runtime, "SuccessTask", false }, .{});
    defer task2.deinit();
    const task3 = try runtime.spawn(errorTask, .{ &runtime, "FailTask", true }, .{});
    defer task3.deinit();
    const task4 = try runtime.spawn(intTask, .{ &runtime, "IntTask", @as(i32, 42) }, .{});
    defer task4.deinit();

    print("Spawned {} coroutines\n\n", .{4});

    // Run the event loop
    try runtime.run();

    print("\n=== Results ===\n", .{});

    // Wait for results using the typed wait() method
    print("Task {}: ", .{task1.task.data.id});
    task1.wait(); // void return
    print("Success (void)\n", .{});

    print("Task {}: ", .{task2.task.data.id});
    task2.wait() catch |err| {
        print("Failed with {}\n", .{err});
        // Jump to next task since this one failed
        print("Task {}: ", .{task3.task.data.id});
        task3.wait() catch |err3| {
            print("Failed with {}\n", .{err3});
        };

        print("Task {}: ", .{task4.task.data.id});
        const result = task4.wait();
        print("Success, returned: {}\n", .{result});
        return;
    };
    print("Success (!void)\n", .{});

    print("Task {}: ", .{task3.task.data.id});
    task3.wait() catch |err| {
        print("Failed with {}\n", .{err});
        // Continue to next task since this one failed as expected
        print("Task {}: ", .{task4.task.data.id});
        const result = task4.wait();
        print("Success, returned: {}\n", .{result});
        return;
    };

    print("Task {}: ", .{task4.task.data.id});
    const result = task4.wait();
    print("Success, returned: {}\n", .{result});

    print("\nAll coroutines completed!\n", .{});
}
