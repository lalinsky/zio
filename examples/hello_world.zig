const std = @import("std");
const zio = @import("zio");

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var out = zio.stdout().writer(&.{});
    try out.interface.writeAll("Hello, world!\n");
    try out.interface.flush();
}
