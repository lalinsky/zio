const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const TcpListener = @import("../tcp.zig").TcpListener;
const TcpStream = @import("../tcp.zig").TcpStream;
const Request = @import("Request.zig").Request;
const Response = @import("Response.zig").Response;
const parser = @import("parser.zig");

pub const HandlerFn = *const fn (*Request, *Response) anyerror!void;

/// Maximum size for HTTP request headers (excluding body)
/// This limits memory usage per connection
const max_http_headers_size = 8 * 1024; // 8KB

/// Buffer size - slightly larger than max headers to have working room
const read_buffer_size = max_http_headers_size + 1024;

/// Simple HTTP Server
pub const Server = struct {
    listener: TcpListener,
    runtime: *Runtime,
    handler: HandlerFn,
    allocator: std.mem.Allocator,

    pub fn init(
        runtime: *Runtime,
        allocator: std.mem.Allocator,
        addr: std.net.Address,
        handler: HandlerFn,
    ) !Server {
        var listener = try TcpListener.init(runtime, addr);
        errdefer listener.close();

        try listener.bind(addr);
        try listener.listen(128);

        return Server{
            .listener = listener,
            .runtime = runtime,
            .handler = handler,
            .allocator = allocator,
        };
    }

    pub fn close(self: *Server) void {
        self.listener.close();
    }

    /// Accept loop - handles connections
    pub fn listen(self: *Server) !void {
        while (true) {
            var stream = try self.listener.accept();
            errdefer stream.close();

            std.debug.print("Accepted connection\n", .{});

            // Spawn a coroutine to handle this connection
            var task = try self.runtime.spawn(
                handleConnection,
                .{ self.allocator, stream, self.handler },
                .{},
            );
            task.deinit();
        }
    }
};

/// Handle a single HTTP connection (may serve multiple requests with keep-alive)
fn handleConnection(
    allocator: std.mem.Allocator,
    stream: TcpStream,
    handler: HandlerFn,
) !void {
    var s = stream;
    defer s.close();
    defer s.shutdown() catch {};

    // Allocate buffers on heap to avoid stack overflow with many concurrent connections
    const read_buffer = try allocator.alloc(u8, read_buffer_size);
    defer allocator.free(read_buffer);

    const write_buffer = try allocator.alloc(u8, 4096);
    defer allocator.free(write_buffer);

    var reader = s.reader(read_buffer);

    // Arena allocator for per-request allocations (Request headers, etc.)
    // Reset between requests for efficient memory reuse
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Initialize parser once for the connection
    // Use arena allocator since parser's hashmap will be moved to Request
    var p: parser.Parser = undefined;
    try p.init(arena_allocator);
    defer p.deinit();

    // Keep-alive loop: handle multiple requests on the same connection
    while (true) {
        // Track how much data we've parsed so far
        var parsed_len: usize = 0;

        // Parse request headers
        while (!p.headers_complete) {
            const buffered_data = reader.interface.buffered();
            const unparsed = buffered_data[parsed_len..];

            if (unparsed.len == 0) {
                // Check if buffer is full - if so, headers are too large
                if (reader.interface.bufferedLen() >= max_http_headers_size) {
                    // TODO: Send 431 Request Header Fields Too Large
                    return error.HttpHeadersTooLarge;
                }

                // Try to read more data
                reader.interface.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (parsed_len == 0) {
                            // Clean connection close - normal end of keep-alive
                            return;
                        } else {
                            return error.IncompleteRequest;
                        }
                    },
                    else => return err,
                };
                continue;
            }

            // Feed unparsed data to llhttp
            try p.execute(unparsed);

            // Track how much total data we have now (llhttp callbacks have stored slices)
            parsed_len = reader.interface.bufferedLen();
        }

        // Headers are complete - create Request
        // IMPORTANT: The Request holds slices into read_buffer, so we can't rebase() yet
        var req = try Request.init(arena_allocator, &p);
        defer req.deinit();

        // Create Response (defaults to .close)
        var res = Response.init(allocator, &s, write_buffer);

        // Set handover to keepalive only if parser says it's OK
        if (p.shouldKeepAlive()) {
            res.setHandover(.keepalive);
        }

        // Call user handler
        handler(&req, &res) catch |err| {
            std.log.err("Handler error: {}", .{err});

            // Try to send error response if headers not yet written
            if (!res.status_written) {
                res.writeStatus(500) catch {};
                res.writeHeader("Content-Type", "text/plain") catch {};
                res.writeBody("Internal Server Error") catch {};
            }
        };

        // Ensure headers are finished if body wasn't written
        if (!res.headers_written) {
            try res.finishHeaders();
        }

        // Flush response
        try res.flush();

        // Check handover to decide what to do with connection
        if (res.handover == .close) {
            return;
        }

        // Clear the internal read buffer and prepare for the next request
        reader.interface.tossBuffered();
        try reader.interface.rebase(max_http_headers_size);

        // Reset arena and parser for next request
        _ = arena.reset(.retain_capacity);
        p.reset();
    }
}

fn dummyHandler(req: *Request, res: *Response) !void {
    _ = req;
    _ = res;
}

test "Server: basic initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator) !void {
            const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            var server = try Server.init(rt, alloc, addr, dummyHandler);
            defer server.close();
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{ &runtime, allocator }, .{});
}

const TEST_HTTP_PORT = 45002;

test "Server: HTTP/1.1 keep-alive" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const ResetEvent = @import("../sync.zig").ResetEvent;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ServerTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator, ready_event: *ResetEvent) !void {
            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_HTTP_PORT);

            // Handler that responds with "OK"
            const handler = struct {
                fn handle(req: *Request, res: *Response) !void {
                    _ = req;
                    try res.writeStatus(200);
                    try res.writeHeader("Content-Type", "text/plain");
                    try res.writeHeader("Content-Length", "2");
                    try res.writeBody("OK");
                }
            }.handle;

            var server = try Server.init(rt, alloc, addr, handler);
            defer server.close();

            ready_event.set(rt);

            // Accept only one connection for test
            var stream = try server.listener.accept();
            errdefer stream.close();
            var task = try server.runtime.spawn(handleConnection, .{ server.allocator, stream, server.handler }, .{});
            task.deinit();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, alloc: std.mem.Allocator, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_HTTP_PORT);
            const Client = @import("Client.zig").Client;

            // Connect to server using HTTP client
            var client = try Client.connect(rt, alloc, addr, "localhost");
            defer client.deinit();

            // First request
            var resp1 = try client.get("/");
            defer resp1.deinit();
            try testing.expectEqual(@as(u16, 200), resp1.status);
            try testing.expectEqualStrings("2", resp1.headerIgnoreCase("Content-Length").?);

            // Second request on same connection
            var resp2 = try client.get("/");
            defer resp2.deinit();
            try testing.expectEqual(@as(u16, 200), resp2.status);
            try testing.expectEqualStrings("2", resp2.headerIgnoreCase("Content-Length").?);
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, allocator, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, allocator, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}
