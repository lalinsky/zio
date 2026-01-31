const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    var stdout = zio.File.stdout();

    var buffer: [100]u8 = undefined;
    var writer = stdout.writer(rt, &buffer);

    try writer.interface.writeAll("Hello, world!\n");
    try writer.interface.flush();
}
