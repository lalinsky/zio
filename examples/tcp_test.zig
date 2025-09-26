const std = @import("std");
const zio = @import("zio");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    std.log.info("=== TCP Test ===", .{});

    const TcpTask = struct {
        fn run(rt: *zio.Runtime) !void {
            // Connect to example.com (port 80 for HTTP)
            const addr = try zio.Address.parseIp4("93.184.216.34", 80); // example.com
            var stream = try zio.TcpStream.connect(rt, addr);
            defer stream.close();

            std.log.info("Connected to example.com:80", .{});

            // Send HTTP request
            const request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
            const bytes_written = try stream.write(request);
            std.log.info("Sent {} bytes", .{bytes_written});

            // Read response
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            std.log.info("Received {} bytes", .{bytes_read});
            std.log.info("Response: {s}", .{buffer[0..@min(200, bytes_read)]});
        }
    };

    var tcp_task = try runtime.spawn(TcpTask.run, .{&runtime}, .{});
    defer tcp_task.deinit();

    try runtime.run();
    try tcp_task.result();
}