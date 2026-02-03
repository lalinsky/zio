const std = @import("std");
const zio = @import("zio");

// --8<-- [start:handleClient]
fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close();

    std.log.info("Client connected from {f}", .{stream.socket.address});

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(&write_buffer);

    while (true) {
        // Read a line from the client
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => |e| return reader.err orelse e,
            else => |e| return e,
        };
        std.log.info("Received: {s}", .{line});

        // Delay the response a little bit
        try rt.sleep(.fromMilliseconds(1000));

        // Echo the line back
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }

    std.log.info("Client disconnected", .{});
}
// --8<-- [end:handleClient]

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    // --8<-- [start:setup]
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);

    const server = try addr.listen(.{});
    // --8<-- [end:setup]
    defer server.close();

    std.log.info("TCP echo server listening on {f}", .{server.socket.address});
    std.log.info("Press Ctrl+C to stop the server", .{});

    // --8<-- [start:group]
    var group: zio.Group = .init;
    defer group.cancel();
    // --8<-- [end:group]

    // --8<-- [start:accept]
    while (true) {
        const stream = try server.accept();
        errdefer stream.close();

        try group.spawn(rt, handleClient, .{ rt, stream });
    }
    // --8<-- [end:accept]
}
