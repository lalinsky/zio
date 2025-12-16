// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const zio = @import("zio");

fn handleClient(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    while (true) {
        // Use Reader delimiter method to read lines
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                std.log.err("Read error: {any}", .{err});
                return;
            },
        };

        std.log.info("Received: {s}", .{line});
        writer.interface.writeAll(line) catch |err| {
            std.log.err("Write error: {any}", .{err});
            return;
        };
        writer.interface.flush() catch |err| {
            std.log.err("Flush error: {any}", .{err});
            return;
        };
    }

    std.log.info("Client disconnected", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    const io = rt.io();

    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 8080 } };

    var server = try addr.listen(io, .{});
    defer server.socket.close(io);

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        // Spawn a concurrent task into the group to handle the client
        try group.concurrent(io, handleClient, .{ io, stream });
    }
}
