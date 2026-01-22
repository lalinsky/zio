// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    std.log.info("Connecting to {f}...", .{&addr});

    var stream = try addr.connect(rt, .none);
    defer stream.close(rt);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);
    var writer = stream.writer(rt, &write_buffer);

    const message = "Hello, server!";

    try writer.interface.writeAll(message);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    try stream.shutdown(rt, .send);

    std.log.info("Sent: {s}", .{message});

    const message2 = try reader.interface.takeDelimiterExclusive('\n');

    std.log.info("Received: {s}", .{message2});
}
