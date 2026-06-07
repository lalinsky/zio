// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

pub const std_options_debug_io = zio.debug_io;

const SharedData = struct {
    counter: i32 = 0,
    mutex: zio.Mutex,
};

fn incrementTask(data: *SharedData, id: u32) !void {
    for (0..1000) |_| {
        try data.mutex.lock();
        defer data.mutex.unlock();

        const old = data.counter;
        try zio.yield(); // Yield to simulate preemption
        data.counter = old + 1;

        if (@rem(data.counter, 100) == 0) {
            std.log.info("Task {}: counter = {}", .{ id, data.counter });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var shared_data = SharedData{
        .mutex = zio.Mutex.init,
    };

    // Spawn multiple tasks that increment shared counter
    var group: zio.Group = .init;
    defer group.cancel();

    for (0..4) |i| {
        try group.spawn(incrementTask, .{ &shared_data, @intCast(i) });
    }

    try group.wait();

    std.log.info("Final counter value: {} (expected: {})", .{ shared_data.counter, 4000 });
}
