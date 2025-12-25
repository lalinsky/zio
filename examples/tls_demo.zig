// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio = @import("zio");

fn runTlsTask(rt: *zio.Runtime) !void {
    std.log.info("Starting TLS connection...", .{});

    // Connect to httpbin.org (reliable HTTPS API)
    // TODO: Add DNS resolution support instead of hardcoded IP address
    const addr = try zio.net.IpAddress.parseIp4("52.2.107.230", 443); // httpbin.org
    std.log.info("Attempting TCP connection to httpbin.org:443...", .{});

    var stream = try addr.connect(rt);
    defer stream.close(rt);

    std.log.info("TCP connected to httpbin.org:443 successfully!", .{});
    std.log.info("Starting TLS handshake...", .{});

    // Create buffers for TCP stream I/O
    var tcp_read_buffer: [32 * 1024]u8 = undefined;
    var tcp_write_buffer: [32 * 1024]u8 = undefined;

    // Create separate buffers for TLS internal operations
    var tls_read_buffer: [32 * 1024]u8 = undefined;
    var tls_write_buffer: [32 * 1024]u8 = undefined;

    // Initialize TLS client with stream reader/writer interfaces
    var tcp_reader = stream.reader(rt, &tcp_read_buffer);
    var tcp_writer = stream.writer(rt, &tcp_write_buffer);

    var tls_client = std.crypto.tls.Client.init(&tcp_reader.interface, &tcp_writer.interface, .{
        .host = .{ .explicit = "httpbin.org" },
        .ca = .no_verification, // For demo purposes - in production use proper CA verification
        .read_buffer = &tls_read_buffer,
        .write_buffer = &tls_write_buffer,
    }) catch |err| {
        std.log.err("TLS handshake failed: {}", .{err});
        return;
    };

    std.log.info("TLS handshake completed successfully!", .{});

    // Send HTTPS request
    const request = "GET /get HTTP/1.1\r\nHost: httpbin.org\r\nUser-Agent: zio.tls-demo\r\nConnection: close\r\n\r\n";

    std.log.info("Sending HTTPS request...", .{});
    try tls_client.writer.writeAll(request);
    // Need to flush both TLS layer (encrypts data to TCP buffer) and TCP layer (sends over network)
    try tls_client.writer.flush();
    try tcp_writer.interface.flush();
    std.log.info("Sent {} bytes over TLS", .{request.len});

    // Read HTTPS response
    var buffer: [4096]u8 = undefined;
    const bytes_read = try tls_client.reader.readSliceShort(&buffer);
    std.log.info("Received {} bytes over TLS", .{bytes_read});

    // Print first part of response
    std.log.info("HTTPS Response:", .{});
    std.log.info("{s}", .{buffer[0..@min(500, bytes_read)]});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var tls_task = try rt.spawn(runTlsTask, .{rt}, .{});
    defer tls_task.cancel(rt);

    try rt.run();

    try tls_task.join(rt);
}
