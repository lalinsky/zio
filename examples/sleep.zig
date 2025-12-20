// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

fn sleepTask(rt: *zio.Runtime) !void {
    for (0..10) |_| {
        std.log.info("Sleeping...", .{});
        try rt.sleep(1000);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var task = try runtime.spawn(sleepTask, .{runtime}, .{});
    try task.join(runtime);
}
