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
    const id1 = try runtime.spawn(voidTask, .{ &runtime, "VoidTask" });
    const id2 = try runtime.spawn(errorTask, .{ &runtime, "SuccessTask", false });
    const id3 = try runtime.spawn(errorTask, .{ &runtime, "FailTask", true });
    const id4 = try runtime.spawn(intTask, .{ &runtime, "IntTask", @as(i32, 42) });

    print("Spawned {} coroutines\n\n", .{4});

    // Run the event loop
    runtime.run();

    print("\n=== Results ===\n", .{});

    // Check individual results
    if (runtime.getResult(id1)) |result| {
        switch (result) {
            .pending => print("Task {}: Still pending\n", .{id1}),
            .success => print("Task {}: Success\n", .{id1}),
            .failure => |err| print("Task {}: Failed with {}\n", .{ id1, err }),
        }
    }

    if (runtime.getResult(id2)) |result| {
        switch (result) {
            .pending => print("Task {}: Still pending\n", .{id2}),
            .success => print("Task {}: Success\n", .{id2}),
            .failure => |err| print("Task {}: Failed with {}\n", .{ id2, err }),
        }
    }

    if (runtime.getResult(id3)) |result| {
        switch (result) {
            .pending => print("Task {}: Still pending\n", .{id3}),
            .success => print("Task {}: Success\n", .{id3}),
            .failure => |err| print("Task {}: Failed with {}\n", .{ id3, err }),
        }
    }

    if (runtime.getResult(id4)) |result| {
        switch (result) {
            .pending => print("Task {}: Still pending\n", .{id4}),
            .success => print("Task {}: Success\n", .{id4}),
            .failure => |err| print("Task {}: Failed with {}\n", .{ id4, err }),
        }
    }

    print("\nAll coroutines completed!\n", .{});
}