const std = @import("std");
const zio = @import("zio");

pub const std_options: std.Options = .{ .log_level = .debug };
pub const std_options_debug_io = zio.debug_io;

pub fn main(init: std.process.Init) !void {
    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    std.log.info("runtime is up", .{});
}
