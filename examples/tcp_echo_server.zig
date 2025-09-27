const std = @import("std");
const zio = @import("zio");

fn handleClient(in_stream: zio.TcpStream) !void {
    var stream = in_stream;
    defer stream.close();

    defer stream.shutdown() catch |err| {
        std.log.err("Failed to shutdown client connection: {}", .{err});
    };

    var buffer: [1024]u8 = undefined;

    const reader = stream.reader();
    const writer = stream.writer();

    while (true) {
        const line = try reader.readUntilDelimiterOrEof(&buffer, '\n') orelse break;
        std.log.info("Received: {s}", .{line});
        try writer.writeAll(line);
        try writer.writeAll("\n");
    }
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try zio.Address.parseIp4("127.0.0.1", 8080);

    var listener = try zio.TcpListener.init(rt, addr);
    defer listener.close();

    try listener.bind(addr);
    try listener.listen(10);

    std.log.info("TCP echo server listening on 127.0.0.1:8080", .{});
    std.log.info("Press Ctrl+C to stop the server", .{});

    while (true) {
        var stream = try listener.accept();
        errdefer stream.close();

        var task = try rt.spawn(handleClient, .{stream}, .{});
        task.deinit();
    }

    listener.close();
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

    try server.result();
}
