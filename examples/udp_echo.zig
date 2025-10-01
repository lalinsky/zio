const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn getTimestamp() u64 {
    return @intCast(std.time.milliTimestamp());
}

var start_time: u64 = 0;

fn udpEchoServer(rt: *zio.Runtime, port: u16) !void {
    print("[Server] Starting UDP echo server on port {}\n", .{port});

    const bind_addr = try zio.Address.parseIp4("127.0.0.1", port);
    var socket = try zio.UdpSocket.init(rt, bind_addr);
    defer socket.deinit();

    try socket.bind(bind_addr);
    print("[Server] Bound to 127.0.0.1:{}\n", .{port});

    // Handle multiple echo requests
    for (0..5) |i| {
        print("[Server] Waiting for message {} ...\n", .{i + 1});

        var buffer: [1024]u8 = undefined;
        const recv_result = try socket.recvFrom(&buffer);

        const elapsed = getTimestamp() - start_time;
        print("[{}ms] [Server] Received '{s}' from {}\n", .{ elapsed, buffer[0..recv_result.bytes_read], recv_result.sender_addr });

        // Echo back to sender
        const bytes_sent = try socket.sendTo(buffer[0..recv_result.bytes_read], recv_result.sender_addr);

        print("[Server] Echoed {} bytes back\n", .{bytes_sent});
    }

    try socket.close();
    print("[Server] Server shutting down\n", .{});
}

fn udpClient(rt: *zio.Runtime, server_port: u16, client_id: u32, message: []const u8) !void {
    // Give server time to start
    rt.sleep(50 * client_id);

    const elapsed_start = getTimestamp() - start_time;
    print("[{}ms] [Client-{}] Starting\n", .{ elapsed_start, client_id });

    const client_addr = try zio.Address.parseIp4("127.0.0.1", 0); // Bind to any available port
    var socket = try zio.UdpSocket.init(rt, client_addr);
    defer socket.deinit();

    try socket.bind(client_addr);

    const server_addr = try zio.Address.parseIp4("127.0.0.1", server_port);

    // Send message to server
    const bytes_sent = try socket.sendTo(message, server_addr);
    const elapsed_sent = getTimestamp() - start_time;
    print("[{}ms] [Client-{}] Sent '{s}' ({} bytes)\n", .{ elapsed_sent, client_id, message, bytes_sent });

    // Wait for echo response
    var buffer: [1024]u8 = undefined;
    const recv_result = try socket.recvFrom(&buffer);

    const elapsed_recv = getTimestamp() - start_time;
    print("[{}ms] [Client-{}] Received echo: '{s}'\n", .{ elapsed_recv, client_id, buffer[0..recv_result.bytes_read] });

    // Verify echo is correct
    if (!std.mem.eql(u8, message, buffer[0..recv_result.bytes_read])) {
        print("[Client-{}] ERROR: Echo mismatch!\n", .{client_id});
        return;
    }

    try socket.close();
    print("[Client-{}] Client finished successfully\n", .{client_id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize zio runtime
    var runtime = try zio.Runtime.init(allocator, .{});
    defer runtime.deinit();

    print("=== ZIO UDP Echo Demo ===\n", .{});
    print("Starting UDP echo server and multiple clients...\n\n", .{});

    start_time = getTimestamp();
    const server_port: u16 = 9000;

    // Start server
    const server_task = try runtime.spawn(udpEchoServer, .{ &runtime, server_port }, .{});
    defer server_task.deinit();

    // Start multiple clients with different messages
    const client_messages = [_][]const u8{
        "Hello from Client 1!",
        "UDP is awesome!",
        "Message #3 here",
        "Fourth message",
        "Final message",
    };

    var client_tasks: [client_messages.len]@TypeOf(try runtime.spawn(udpClient, .{ &runtime, server_port, @as(u32, 1), "test" }, .{})) = undefined;

    for (client_messages, 0..) |message, i| {
        client_tasks[i] = try runtime.spawn(udpClient, .{ &runtime, server_port, @as(u32, @intCast(i + 1)), message }, .{});
    }
    defer for (client_tasks) |*task| task.deinit();

    // Run the event loop
    try runtime.run();

    print("\nAll tasks completed!\n", .{});
}
