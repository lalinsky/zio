const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn clientTask(rt: *zio.Runtime) !void {
    std.log.info("Connecting to 127.0.0.1:8080...", .{});
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    var stream = try addr.connect(rt);
    defer stream.close(rt);

    defer stream.shutdown(rt, .both) catch |err| std.log.err("Shutdown error: {}", .{err});

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);
    var writer = stream.writer(rt, &write_buffer);

    const message = "Hello, server!";

    try writer.interface.writeAll(message);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    std.log.info("Sent: {s}", .{message});

    // Use new Reader delimiter method to read until newline
    const message2 = try reader.interface.takeDelimiterExclusive('\n');

    std.log.info("Received: {s}", .{message2});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Enable thread pool for DNS resolution
    var runtime = try zio.Runtime.init(allocator, .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    var task = try runtime.spawn(clientTask, .{runtime}, .{});
    defer task.deinit();

    try runtime.run();
}
