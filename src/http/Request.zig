const std = @import("std");
const parser = @import("parser.zig");

pub const Method = parser.Method;

/// HTTP Request represents a parsed HTTP request
/// Holds slices directly into the read buffer for zero-copy operation
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    /// Initialize a Request from parser state
    /// Takes ownership of the parser's headers hashmap
    /// IMPORTANT: The slices point into the read buffer which must remain valid
    /// during the entire request handling
    pub fn init(allocator: std.mem.Allocator, p: *parser.Parser) !Request {
        const method = p.getMethod() orelse return error.InvalidMethod;

        // Move the headers hashmap from parser to request (zero-copy)
        const headers = p.headers.move();

        return Request{
            .method = method,
            .url = p.url,
            .headers = headers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        // No need to free slices - they point into the stack-allocated read buffer
        // Just clean up the hashmap structure
        self.headers.deinit(self.allocator);
    }

    /// Get header value by name (case-sensitive)
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Get header value by name (case-insensitive)
    pub fn headerIgnoreCase(self: *const Request, name: []const u8) ?[]const u8 {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }
};

test "Request: init from parser" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var p: parser.Parser = undefined;
    try p.init(allocator);
    defer p.deinit();

    const raw_request = "GET /hello?name=world HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: test\r\n\r\n";
    try p.execute(raw_request);

    var req = try Request.init(allocator, &p);
    defer req.deinit();

    try testing.expectEqual(Method.GET, req.method);
    try testing.expectEqualStrings("/hello?name=world", req.url);
    try testing.expectEqualStrings("localhost:8080", req.header("Host").?);
    try testing.expectEqualStrings("test", req.header("User-Agent").?);
}

test "Request: headerIgnoreCase" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var p: parser.Parser = undefined;
    try p.init(allocator);
    defer p.deinit();

    const raw_request = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
    try p.execute(raw_request);

    var req = try Request.init(allocator, &p);
    defer req.deinit();

    try testing.expectEqualStrings("application/json", req.headerIgnoreCase("content-type").?);
    try testing.expectEqualStrings("application/json", req.headerIgnoreCase("CONTENT-TYPE").?);
    try testing.expectEqualStrings("application/json", req.headerIgnoreCase("Content-Type").?);
}
