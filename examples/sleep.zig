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

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(sleepTask, .{rt}, .{});
    try task.join(rt);
}
