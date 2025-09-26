const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    std.log.info("=== TLS Demo with zio.tls ===", .{});

    const TlsTask = struct {
        fn run(rt: *zio.Runtime) !void {
            // Connect to example.com (reliable HTTPS)
            const addr = try zio.Address.parseIp4("93.184.216.34", 443); // example.com
            var stream = try zio.TcpStream.connect(rt, addr);
            defer stream.close();

            std.log.info("Connected to example.com:443", .{});

            // Initialize TLS client
            var tls_client = try std.crypto.tls.Client.init(stream, .{
                .host = .{ .explicit = "example.com" },
                .ca = .no_verification, // For demo purposes - in production use proper CA verification
            });

            std.log.info("TLS handshake completed successfully!", .{});

            // Send HTTPS request
            const request = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: zio.tls-demo\r\nConnection: close\r\n\r\n";

            std.log.info("Sending HTTPS request...", .{});
            const bytes_written = try tls_client.write(stream, request);
            std.log.info("Sent {} bytes over TLS", .{bytes_written});

            // Read HTTPS response
            var buffer: [4096]u8 = undefined;
            const bytes_read = try tls_client.read(stream, &buffer);
            std.log.info("Received {} bytes over TLS", .{bytes_read});

            // Print first part of response
            std.log.info("HTTPS Response:", .{});
            std.log.info("{s}", .{buffer[0..@min(500, bytes_read)]});
        }
    };

    var tls_task = try runtime.spawn(TlsTask.run, .{&runtime}, .{});
    defer tls_task.deinit();

    try runtime.run();

    try tls_task.result();
}