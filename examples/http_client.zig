const std = @import("std");
const Zio = @import("zio");

pub const std_options_debug_io = Zio.debug_io;

pub fn main(init: std.process.Init) !void {
    var zio = try Zio.Runtime.init(init.gpa, .{ .thread_pool = .{ .min_threads = 1 } });
    defer zio.deinit();

    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = zio.io() };
    defer http_client.deinit();

    std.debug.print("TEST http client: {any}\n", .{http_client});

    var request = try http_client.request(.GET, try std.Uri.parse("https://httpbin.org/get"), .{});
    defer request.deinit();

    std.debug.print("TEST request headers: {any}\n", .{request.headers});

    try request.sendBodiless();

    std.debug.print("TEST request body\n", .{});

    var redirect_buffer: [1024]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);

    std.log.info("received {d} {s}", .{ response.head.status, response.head.reason });
}
