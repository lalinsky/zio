const std = @import("std");
const zio = @import("zio");

// Use zio for std.log.* and std.debug.print
pub const std_options_debug_io = zio.debug_io;

// Maximum response body size we are willing to buffer
const MAX_BODY_SIZE = 1 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    // Allow the URL to be passed as the first argument
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const url = if (args.len > 1) args[1] else "https://httpbin.org/get";

    // --8<-- [start:client]
    // The HTTP client drives all I/O through zio's event loop
    var client: std.http.Client = .{ .allocator = gpa, .io = rt.io() };
    defer client.deinit();
    // --8<-- [end:client]

    std.log.info("GET {s}", .{url});

    // --8<-- [start:request]
    // Send the request headers (no request body for a GET)
    var request = try client.request(.GET, try std.Uri.parse(url), .{});
    defer request.deinit();

    try request.sendBodiless();

    // Receive the response headers
    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    // --8<-- [end:request]

    std.log.info("{d} {s}", .{ @intFromEnum(response.head.status), response.head.reason });

    // --8<-- [start:body]
    // Read the (possibly decompressed) response body
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    const body = try reader.allocRemaining(gpa, .limited(MAX_BODY_SIZE));
    defer gpa.free(body);
    // --8<-- [end:body]

    std.log.info("Received {d} bytes:", .{body.len});
    std.debug.print("{s}\n", .{body});
}
