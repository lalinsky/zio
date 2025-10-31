const std = @import("std");
const zio = @import("zio");

const SharedData = struct {
    counter: i32 = 0,
    mutex: zio.Mutex,
};

fn incrementTask(rt: *zio.Runtime, data: *SharedData, id: u32) !void {
    for (0..1000) |_| {
        try data.mutex.lock(rt);
        defer data.mutex.unlock(rt);

        const old = data.counter;
        try rt.yield(); // Yield to simulate preemption
        data.counter = old + 1;

        if (@rem(data.counter, 100) == 0) {
            std.log.info("Task {}: counter = {}", .{ id, data.counter });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = try zio.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();

    var shared_data = SharedData{
        .mutex = zio.Mutex.init,
    };

    // Spawn multiple tasks that increment shared counter
    var task0 = try runtime.spawn(incrementTask, .{ runtime, &shared_data, 0 }, .{});
    defer task0.cancel(runtime);
    var task1 = try runtime.spawn(incrementTask, .{ runtime, &shared_data, 1 }, .{});
    defer task1.cancel(runtime);
    var task2 = try runtime.spawn(incrementTask, .{ runtime, &shared_data, 2 }, .{});
    defer task2.cancel(runtime);
    var task3 = try runtime.spawn(incrementTask, .{ runtime, &shared_data, 3 }, .{});
    defer task3.cancel(runtime);

    try runtime.run();

    std.log.info("Final counter value: {} (expected: {})", .{ shared_data.counter, 4000 });
}
