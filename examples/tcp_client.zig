const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn clientTask(rt: *zio.Runtime, client_id: u32, message: []const u8) !void {
    print("Client {}: Connecting to server...\n", .{client_id});

    const addr = try zio.Address.parseIp4("127.0.0.1", 8080);
    var stream = zio.TcpStream.connect(rt, addr) catch |err| {
        print("Client {}: Connection failed: {}\n", .{ client_id, err });
        return err;
    };
    defer stream.deinit();

    print("Client {}: Connected to server\n", .{client_id});

    // Send message
    const bytes_written = stream.write(message) catch |err| {
        print("Client {}: Write error: {}\n", .{ client_id, err });
        return err;
    };

    print("Client {}: Sent {} bytes: {s}\n", .{ client_id, bytes_written, message });

    // Read response
    var buffer: [1024]u8 = undefined;
    const bytes_read = stream.read(&buffer) catch |err| {
        print("Client {}: Read error: {}\n", .{ client_id, err });
        return err;
    };

    print("Client {}: Received {} bytes: {s}\n", .{ client_id, bytes_read, buffer[0..bytes_read] });

    // Verify echo
    if (std.mem.eql(u8, message, buffer[0..bytes_read])) {
        print("Client {}: Echo verified ✓\n", .{client_id});
    } else {
        print("Client {}: Echo mismatch ✗\n", .{client_id});
        return error.EchoMismatch;
    }

    // Graceful shutdown
    stream.shutdown() catch |err| {
        print("Client {}: Shutdown error: {}\n", .{ client_id, err });
    };

    stream.close() catch |err| {
        print("Client {}: Close error: {}\n", .{ client_id, err });
    };

    print("Client {}: Disconnected\n", .{client_id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    print("=== TCP Client Demo ===\n", .{});
    print("Connecting to echo server at 127.0.0.1:8080\n\n", .{});

    // Test messages to send
    const messages = [_][]const u8{
        "Hello, TCP Server!",
        "Testing echo functionality",
        "Short msg",
        "This is a longer message to test the echo server's ability to handle various message lengths correctly.",
        "🚀 Unicode test! 🎉",
    };

    // Spawn multiple client tasks
    var tasks: [messages.len]@TypeOf(try runtime.spawn(clientTask, .{ &runtime, @as(u32, 1), messages[0] }, .{})) = undefined;

    for (messages, 0..) |message, i| {
        tasks[i] = try runtime.spawn(clientTask, .{ &runtime, @as(u32, @intCast(i + 1)), message }, .{});
    }
    defer for (tasks) |task| task.deinit();

    // Add small delays between client connections
    const delay_task = try runtime.spawn(struct {
        fn run(rt: *zio.Runtime) void {
            for (0..messages.len) |_| {
                rt.sleep(100); // 100ms between connections
            }
        }
    }.run, .{&runtime}, .{});
    defer delay_task.deinit();

    try runtime.run();

    // Check all results
    for (tasks, 0..) |task, i| {
        task.result() catch |err| {
            print("Client {} failed: {}\n", .{ i + 1, err });
            return err;
        };
    }

    print("\nAll clients completed successfully! 🎉\n", .{});
}