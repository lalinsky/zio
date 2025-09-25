const std = @import("std");
const print = std.debug.print;
const zio = @import("zio");

fn handleClient(_: *zio.Runtime, stream: *zio.TcpStream, client_id: u32) !void {
    defer stream.deinit();

    print("Client {}: Connected\n", .{client_id});

    var buffer: [1024]u8 = undefined;

    while (true) {
        const bytes_read = stream.read(&buffer) catch |err| {
            print("Client {}: Read error: {}\n", .{ client_id, err });
            return err;
        };

        if (bytes_read == 0) {
            print("Client {}: Connection closed by client\n", .{client_id});
            break;
        }

        print("Client {}: Received {} bytes: {s}\n", .{ client_id, bytes_read, buffer[0..bytes_read] });

        const bytes_written = try stream.write(buffer[0..bytes_read]);
        print("Client {}: Echoed {} bytes\n", .{ client_id, bytes_written });
    }

    try stream.shutdown();
    try stream.close();

    print("Client {}: Disconnected\n", .{client_id});
}

fn serverTask(rt: *zio.Runtime) !void {
    const addr = try zio.Address.parseIp4("127.0.0.1", 8080);
    var listener = try zio.TcpListener.init(rt, addr);
    defer listener.deinit();

    try listener.bind(addr);
    try listener.listen(10);

    print("TCP Echo Server listening on 127.0.0.1:8080\n", .{});
    print("Press Ctrl+C to stop the server\n\n", .{});

    var client_counter: u32 = 0;

    while (true) {
        var stream = try listener.accept();
        client_counter += 1;

        // Spawn a new task to handle each client
        const task = try rt.spawn(handleClient, .{ rt, &stream, client_counter }, .{});
        defer task.deinit();

        // Don't wait for the client handler to finish - let it run concurrently
        // The task will clean up the stream when it's done
    }

    try listener.close();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zio.Runtime.init(allocator);
    defer runtime.deinit();

    const server = try runtime.spawn(serverTask, .{&runtime}, .{});
    defer server.deinit();

    try runtime.run();

    try server.result();
}