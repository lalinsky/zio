const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn clientTask(rt: *zio.Runtime) !void {
    const addr = try zio.Address.parseIp4("127.0.0.1", 8080);
    var stream = try zio.TcpStream.connect(rt, addr);
    defer stream.close();

    defer stream.shutdown() catch |err| std.log.err("Shutdown error: {}", .{err});

    var reader = stream.reader();
    var writer = stream.writer();

    const message = "Hello, server!";

    try writer.writeAll(message);
    try writer.writeAll("\n");

    std.log.info("Sent: {s}", .{message});

    var buffer: [1024]u8 = undefined;
    const message2 = try reader.readUntilDelimiter(&buffer, '\n');

    std.log.info("Received: {s}", .{message2});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var task = try runtime.spawn(clientTask, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();
}
