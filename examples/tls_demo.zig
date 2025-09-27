const std = @import("std");
const zio = @import("zio");

fn runTlsTask(rt: *zio.Runtime) !void {
    std.log.info("Starting TLS connection...", .{});

    // Connect to httpbin.org (reliable HTTPS API)
    // TODO: Add DNS resolution support instead of hardcoded IP address
    const addr = try zio.Address.parseIp4("52.2.107.230", 443); // httpbin.org
    std.log.info("Attempting TCP connection to httpbin.org:443...", .{});

    var stream = try zio.TcpStream.connect(rt, addr);
    defer stream.close();

    std.log.info("TCP connected to httpbin.org:443 successfully!", .{});
    std.log.info("Starting TLS handshake...", .{});

    // Initialize TLS client
    var tls_client = std.crypto.tls.Client.init(stream, .{
        .host = .{ .explicit = "httpbin.org" },
        .ca = .no_verification, // For demo purposes - in production use proper CA verification
    }) catch |err| {
        std.log.err("TLS handshake failed: {}", .{err});
        return;
    };

    std.log.info("TLS handshake completed successfully!", .{});

    // Send HTTPS request
    const request = "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nUser-Agent: zio.tls-demo\r\nConnection: close\r\n\r\n";

    std.log.info("Sending HTTPS request...", .{});
    try tls_client.writeAll(stream, request);
    std.log.info("Sent {} bytes over TLS", .{request.len});

    // Read HTTPS response
    var buffer: [4096]u8 = undefined;
    const bytes_read = try tls_client.read(stream, &buffer);
    std.log.info("Received {} bytes over TLS", .{bytes_read});

    // Print first part of response
    std.log.info("HTTPS Response:", .{});
    std.log.info("{s}", .{buffer[0..@min(500, bytes_read)]});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    var tls_task = try runtime.spawn(runTlsTask, .{&runtime}, .{ .stack_size = 4 * 1024 * 1024 }); // Test 4MB stack
    defer tls_task.deinit();

    try runtime.run();

    try tls_task.result();
}
