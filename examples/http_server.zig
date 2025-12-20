// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

// Maximum size of the request headers
const MAX_REQUEST_HEADER_SIZE = 64 * 1024;

fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    defer stream.shutdown(rt, .both) catch |err| {
        std.log.debug("Failed to shutdown client connection: {}", .{err});
    };

    std.log.info("HTTP client connected from {f}", .{stream.socket.address});

    var read_buffer: [MAX_REQUEST_HEADER_SIZE]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    // Initialize HTTP server for this connection
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    // Handle multiple requests on the same connection (keep-alive)
    while (true) {
        // Receive HTTP request headers
        var request = server.receiveHead() catch |err| {
            std.log.debug("Failed to receive request: {}", .{err});
            return err;
        };

        std.log.info("{s} {s}", .{ @tagName(request.head.method), request.head.target });

        // Simple HTML response
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zio HTTP Server</title></head>
            \\<body>
            \\  <h1>Hello from zio!</h1>
            \\  <p>This is a simple HTTP server built with zio async runtime and std.http.Server.</p>
            \\</body>
            \\</html>
        ;

        try request.respond(html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });

        // If the client doesn't want keep-alive, close the connection
        if (!request.head.keep_alive) break;
    }

    std.log.info("HTTP client disconnected", .{});
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(rt, .{});
    defer server.close(rt);

    std.log.info("HTTP server listening on {f}", .{server.socket.address});
    std.log.info("Visit http://{f} in your browser", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    while (true) {
        const stream = try server.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.detach(rt);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var handle = try runtime.spawn(serverTask, .{runtime}, .{});
    try handle.join(runtime);
}
