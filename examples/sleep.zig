const std = @import("std");
const zio = @import("zio");

fn sleepTask(rt: *zio.Runtime) void {
    for (0..10) |_| {
        std.log.info("Sleeping...", .{});
        rt.sleep(1000);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(sleepTask, .{&runtime}, .{});
}
