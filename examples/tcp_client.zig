const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 8080);
    std.log.info("Connecting to {f}...", .{&addr});

    var stream = try addr.connect(rt, .{});
    defer stream.close(rt);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(rt, &write_buffer);

    try writer.interface.writeAll("Hello, server!\n");
    try writer.interface.flush();

    try stream.shutdown(rt, .send);

    const message = try reader.interface.takeDelimiterExclusive('\n');
    std.log.info("Received: {s}", .{message});
}
