// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    for (0..10) |_| {
        std.log.info("Sleeping...", .{});
        try rt.sleep(.fromSeconds(1));
    }
}
