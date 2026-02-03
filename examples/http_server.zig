const std = @import("std");
const zio = @import("zio");

// Maximum size of the request headers
const MAX_REQUEST_HEADER_SIZE = 64 * 1024;

fn handleClient(stream: zio.net.Stream) !void {
    defer stream.close();

    std.log.info("HTTP client connected from {f}", .{stream.socket.address});

    var read_buffer: [MAX_REQUEST_HEADER_SIZE]u8 = undefined;
    var reader = stream.reader(&read_buffer);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(&write_buffer);

    // --8<-- [start:init]
    // Initialize HTTP server for this connection
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    // --8<-- [end:init]

    // --8<-- [start:loop]
    while (true) {
        // Receive HTTP request headers
        var request = server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => |e| return reader.err orelse e,
            else => |e| return e,
        };
        std.log.info("{t} {s}", .{ request.head.method, request.head.target });

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
        if (!request.head.keep_alive) {
            try stream.shutdown(.both);
            break;
        }
    }
    // --8<-- [end:loop]

    std.log.info("HTTP client disconnected", .{});
}

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(.{});
    defer server.close();

    std.log.info("HTTP server listening on {f}", .{server.socket.address});
    std.log.info("Visit http://{f} in your browser", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    var group: zio.Group = .init;
    defer group.cancel();

    while (true) {
        const stream = try server.accept();
        errdefer stream.close();

        try group.spawn(handleClient, .{stream});
    }
}
