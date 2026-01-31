const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    var out = zio.stdout().writer(rt, &.{});
    try out.interface.writeAll("Hello, world!\n");
    try out.interface.flush();
}
