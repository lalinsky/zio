const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn addNumbers(a: i32, b: i32) i32 {
    return a + b;
}

fn delayedReturn(runtime: *zio.Runtime) !i32 {
    runtime.sleep(100) catch return error.SleepFailed;
    return 42;
}

fn printMessage(runtime: *zio.Runtime, msg: []const u8) void {
    runtime.sleep(50) catch return;
    print("Message: {s}\n", .{msg});
}

fn mainCoroutine(runtime: *zio.Runtime) void {
    print("=== Task(T) Demo ===\n", .{});

    // Test with i32 return type
    const task1 = runtime.spawn(addNumbers, .{ 10, 20 }, .{}) catch {
        print("Failed to spawn task1\n", .{});
        return;
    };
    defer task1.deinit();
    print("Spawned task1 (returns i32)\n", .{});

    // Test with error union return type
    const task2 = runtime.spawn(delayedReturn, .{runtime}, .{}) catch {
        print("Failed to spawn task2\n", .{});
        return;
    };
    defer task2.deinit();
    print("Spawned task2 (returns !i32)\n", .{});

    // Test with void return type
    const task3 = runtime.spawn(printMessage, .{ runtime, "Hello from task!" }, .{}) catch {
        print("Failed to spawn task3\n", .{});
        return;
    };
    defer task3.deinit();
    print("Spawned task3 (returns void)\n", .{});

    // Wait for results using the typed wait() method
    print("Waiting for task1 result...\n", .{});
    const result1 = task1.wait();
    print("Task1 result: {}\n", .{result1});

    print("Waiting for task2 result...\n", .{});
    const result2 = task2.wait() catch |err| {
        print("Task2 failed with error: {}\n", .{err});
        print("Continuing to task3...\n", .{});
        task3.wait();
        print("Task3 completed\n", .{});
        return;
    };
    print("Task2 result: {}\n", .{result2});

    print("Waiting for task3 to complete...\n", .{});
    task3.wait(); // void return type
    print("Task3 completed\n", .{});

    print("All tasks completed!\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    // Spawn the main coroutine
    const main_task = try runtime.spawn(mainCoroutine, .{&runtime}, .{});
    defer main_task.deinit();

    // Run the runtime to execute all tasks
    try runtime.run();
}