// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// Test with: echo "hello" | nc -N 127.0.0.1 8080

const std = @import("std");
const zio = @import("zio");

fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    defer stream.shutdown(rt, .both) catch |err| {
        std.log.err("Failed to shutdown client connection: {}", .{err});
    };

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var buffer: [1024]u8 = undefined;

    while (true) {
        const n = try stream.read(rt, &buffer, .none);
        if (n == 0) break;

        std.log.info("Received: {s}", .{buffer[0..n]});
        try stream.writeAll(rt, buffer[0..n], .none);
    }

    std.log.info("Client disconnected", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    var group: zio.Group = .init;
    defer group.cancel(rt);

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        try group.spawn(rt, handleClient, .{ rt, stream });
    }
}
