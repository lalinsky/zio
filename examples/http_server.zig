const std = @import("std");
const zio = @import("zio");

fn handleRequest(req: *zio.http.Request, res: *zio.http.Response) !void {
    std.log.info("{s} {s}", .{ @tagName(req.method), req.url });

    // Simple router
    if (std.mem.eql(u8, req.url, "/")) {
        try res.writeStatus(200);
        try res.writeHeader("Content-Type", "text/html");
        try res.writeBody(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>ZIO HTTP Server</title></head>
            \\<body>
            \\  <h1>Hello from ZIO HTTP Server!</h1>
            \\  <p>This is a simple HTTP server built with ZIO and llhttp.</p>
            \\  <ul>
            \\    <li><a href="/hello">Hello endpoint</a></li>
            \\    <li><a href="/api/status">API status</a></li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    } else if (std.mem.eql(u8, req.url, "/hello")) {
        try res.writeStatus(200);
        try res.writeHeader("Content-Type", "text/plain");
        try res.writeBody("Hello, World!");
    } else if (std.mem.startsWith(u8, req.url, "/api/status")) {
        try res.writeStatus(200);
        try res.writeHeader("Content-Type", "text/plain");
        try res.writeBody("OK - Server is running");
    } else {
        try res.writeStatus(404);
        try res.writeHeader("Content-Type", "text/plain");
        try res.writeBody("404 Not Found");
    }
}

pub fn asyncMain(rt: *zio.Runtime, allocator: std.mem.Allocator) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);

    std.log.info("Starting HTTP server on http://127.0.0.1:8080", .{});
    std.log.info("Press Ctrl+C to stop", .{});

    var server = try zio.http.Server.init(rt, allocator, addr, handleRequest);
    defer server.close();

    try server.listen();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.runUntilComplete(asyncMain, .{ &runtime, allocator }, .{});
}
