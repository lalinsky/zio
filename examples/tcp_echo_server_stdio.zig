// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// Test with: echo "hello" | nc -N 127.0.0.1 8080
//
// This example demonstrates using std.Io interface with zio Runtime.

const std = @import("std");
const zio = @import("zio");

const Io = std.Io;

fn handleClient(io: Io, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(io);

    defer stream.shutdown(io, .both) catch |err| {
        std.log.err("Failed to shutdown client connection: {}", .{err});
    };

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                if (reader.err) |e| {
                    if (e == error.Canceled) return error.Canceled;
                    std.log.err("Read error: {}", .{e});
                }
                return;
            },
            else => {
                std.log.err("Read error: {}", .{err});
                return;
            },
        };

        std.log.info("Received: {s}", .{line});
        writer.interface.writeAll(line) catch {
            if (writer.err) |e| {
                if (e == error.Canceled) return error.Canceled;
                std.log.err("Write error: {}", .{e});
            }
            return;
        };
        writer.interface.flush() catch {
            if (writer.err) |e| {
                if (e == error.Canceled) return error.Canceled;
                std.log.err("Flush error: {}", .{e});
            }
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

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 8080);

    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = try server.accept(io);
        errdefer stream.close(io);

        try group.concurrent(io, handleClient, .{ io, stream });
    }
}
