// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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

    var rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    var shared_data = SharedData{
        .mutex = zio.Mutex.init,
    };

    // Spawn multiple tasks that increment shared counter
    var group: zio.Group = .init;
    defer group.cancel(rt);

    for (0..4) |i| {
        try group.spawn(rt, incrementTask, .{ rt, &shared_data, @intCast(i) });
    }

    try group.wait(rt);

    std.log.info("Final counter value: {} (expected: {})", .{ shared_data.counter, 4000 });
}
