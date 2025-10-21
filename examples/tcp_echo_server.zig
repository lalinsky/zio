const std = @import("std");
const zio = @import("zio");

fn handleClient(rt: *zio.Runtime, stream: zio.net.Stream) !void {
    defer stream.close(rt);

    defer stream.shutdown(rt) catch |err| {
        std.log.err("Failed to shutdown client connection: {}", .{err});
    };

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    while (true) {
        // Use new Reader delimiter method to read lines
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        std.log.info("Received: {s}", .{line});
        try writer.interface.writeAll(line);
        try writer.interface.flush();
    }
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);

    var listener = try zio.TcpListener.init(addr);
    defer listener.close(rt);

    try listener.bind(addr);
    try listener.listen(10);

    std.log.info("TCP echo server listening on 127.0.0.1:8080", .{});
    std.log.info("Press Ctrl+C to stop the server", .{});

    while (true) {
        const stream = try listener.accept(rt);
        errdefer stream.close(rt);

        var task = try rt.spawn(handleClient, .{ rt, stream }, .{});
        task.deinit();
    }

    listener.close(rt);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server = try runtime.spawn(serverTask, .{&runtime}, .{});
    defer server.deinit();

    try runtime.run();

    try server.join();
}
