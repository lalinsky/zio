const std = @import("std");
const zio = @import("zio");

const SharedData = struct {
    counter: i32 = 0,
    mutex: zio.Mutex,
};

fn incrementTask(rt: *zio.Runtime, data: *SharedData, id: u32) void {
    for (0..1000) |_| {
        data.mutex.lock();
        defer data.mutex.unlock();

        const old = data.counter;
        rt.yield(); // Yield to simulate preemption
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
        .mutex = zio.Mutex.init(&runtime),
    };

    // Spawn multiple tasks that increment shared counter
    var tasks: [4]*zio.Task(void) = undefined;
    for (0..4) |i| {
        tasks[i] = try runtime.spawn(incrementTask, .{ &runtime, &shared_data, @as(u32, @intCast(i)) }, .{});
    }
    defer for (tasks) |task| task.deinit();

    try runtime.run();

    std.log.info("Final counter value: {} (expected: {})", .{ shared_data.counter, 4000 });
}
