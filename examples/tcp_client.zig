const std = @import("std");
const zio = @import("zio");

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    std.log.info("Connecting to {f}...", .{&addr});

    var stream = try addr.connect(.{});
    defer stream.close();

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(&write_buffer);

    try writer.interface.writeAll("Hello, server!\n");
    try writer.interface.flush();

    try stream.shutdown(.send);

    const message = try reader.interface.takeDelimiterExclusive('\n');
    std.log.info("Received: {s}", .{message});
}
