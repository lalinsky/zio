// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// Test with: echo "hello" | nc -u -w1 127.0.0.1 8080

const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const socket = try addr.bind(rt, .{});
    defer socket.close(rt);

    std.log.info("UDP echo server listening on {f}", .{socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    const timeout: zio.Timeout = .none;
    var buffer: [1024]u8 = undefined;

    while (true) {
        const result = try socket.receiveFrom(rt, &buffer, timeout);
        std.log.info("Received {d} bytes from {f}", .{ result.len, result.from });
        const sent = try socket.sendTo(rt, result.from, buffer[0..result.len], timeout);
        std.debug.assert(sent == result.len);
    }
}
