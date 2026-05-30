// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    for (0..10) |_| {
        std.log.info("Sleeping...", .{});
        try zio.sleep(.fromSeconds(1));
    }
}
