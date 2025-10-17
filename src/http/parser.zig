const std = @import("std");
const c = @cImport({
    @cInclude("llhttp.h");
});

pub const Method = enum(u8) {
    DELETE = c.HTTP_DELETE,
    GET = c.HTTP_GET,
    HEAD = c.HTTP_HEAD,
    POST = c.HTTP_POST,
    PUT = c.HTTP_PUT,
    CONNECT = c.HTTP_CONNECT,
    OPTIONS = c.HTTP_OPTIONS,
    TRACE = c.HTTP_TRACE,
    PATCH = c.HTTP_PATCH,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .DELETE => "DELETE",
            .GET => "GET",
            .HEAD => "HEAD",
            .POST => "POST",
            .PUT => "PUT",
            .CONNECT => "CONNECT",
            .OPTIONS => "OPTIONS",
            .TRACE => "TRACE",
            .PATCH => "PATCH",
        };
    }
};

pub const ParseError = error{
    InvalidMethod,
    InvalidUrl,
    InvalidHeaderToken,
    InvalidHeaderValue,
    InvalidVersion,
    InvalidStatus,
    InvalidChunkSize,
    UnexpectedContentLength,
    ClosedConnection,
    ParseFailed,
};

/// Request Parser wraps llhttp and manages the parsing state for HTTP requests
/// Stores slices directly into the read buffer for zero-copy parsing
pub const Parser = struct {
    parser: c.llhttp_t,
    settings: c.llhttp_settings_t,

    // Parsing state - stores slices into the read buffer
    method: ?Method = null,
    url: []const u8 = "",

    // Current header being built (llhttp may call callbacks multiple times per header)
    current_header_field_start: ?[*]const u8 = null,
    current_header_field_len: usize = 0,
    current_header_value_start: ?[*]const u8 = null,
    current_header_value_len: usize = 0,

    // Headers storage - keys and values are slices into read buffer
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    // Flags
    headers_complete: bool = false,
    message_complete: bool = false,

    pub fn init(self: *Parser, allocator: std.mem.Allocator) !void {
        self.* = Parser{
            .parser = undefined,
            .settings = undefined,
            .headers = .{},
            .allocator = allocator,
        };

        // Initialize settings to zero - this sets all callbacks to null
        self.settings = std.mem.zeroes(c.llhttp_settings_t);

        // Set up only the callbacks we need
        self.settings.on_url = onUrl;
        self.settings.on_header_field = onHeaderField;
        self.settings.on_header_value = onHeaderValue;
        self.settings.on_headers_complete = onHeadersComplete;
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_REQUEST, &self.settings);

        // Set stable pointers now that Parser won't move
        self.parser.data = @ptrCast(self);
        self.parser.settings = @ptrCast(&self.settings);
    }

    pub fn deinit(self: *Parser) void {
        // No need to free slices - they point into the read buffer which is stack allocated
        // Just clean up the hashmap structure itself
        self.headers.deinit(self.allocator);
    }

    pub fn reset(self: *Parser) void {
        self.url = "";
        self.current_header_field_start = null;
        self.current_header_field_len = 0;
        self.current_header_value_start = null;
        self.current_header_value_len = 0;

        // Clear headers (slices don't need freeing)
        self.headers.clearRetainingCapacity();

        self.method = null;
        self.headers_complete = false;
        self.message_complete = false;

        c.llhttp_reset(&self.parser);
    }

    pub fn execute(self: *Parser, data: []const u8) !void {
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);

        if (err != c.HPE_OK and err != c.HPE_PAUSED) {
            return self.mapError(err);
        }
    }

    pub fn finish(self: *Parser) !void {
        const err = c.llhttp_finish(&self.parser);
        if (err != c.HPE_OK) {
            return self.mapError(err);
        }
    }

    pub fn getMethod(self: *Parser) ?Method {
        if (self.method == null) {
            const method_num = c.llhttp_get_method(&self.parser);
            self.method = @enumFromInt(method_num);
        }
        return self.method;
    }

    pub fn shouldKeepAlive(self: *Parser) bool {
        return c.llhttp_should_keep_alive(&self.parser) != 0;
    }

    fn mapError(self: *Parser, err: c.llhttp_errno_t) ParseError {
        _ = self;
        return switch (err) {
            c.HPE_INVALID_METHOD => ParseError.InvalidMethod,
            c.HPE_INVALID_URL => ParseError.InvalidUrl,
            c.HPE_INVALID_HEADER_TOKEN => ParseError.InvalidHeaderToken,
            c.HPE_INVALID_VERSION => ParseError.InvalidVersion,
            c.HPE_INVALID_STATUS => ParseError.InvalidStatus,
            c.HPE_INVALID_CHUNK_SIZE => ParseError.InvalidChunkSize,
            c.HPE_UNEXPECTED_CONTENT_LENGTH => ParseError.UnexpectedContentLength,
            c.HPE_CLOSED_CONNECTION => ParseError.ClosedConnection,
            else => ParseError.ParseFailed,
        };
    }

    fn saveCurrentHeader(self: *Parser) !void {
        if (self.current_header_field_start != null and self.current_header_value_start != null) {
            const field_start = self.current_header_field_start.?;
            const value_start = self.current_header_value_start.?;

            const field = field_start[0..self.current_header_field_len];
            const value = value_start[0..self.current_header_value_len];

            try self.headers.put(self.allocator, field, value);

            // Reset for next header
            self.current_header_field_start = null;
            self.current_header_field_len = 0;
            self.current_header_value_start = null;
            self.current_header_value_len = 0;
        }
    }

    // Callbacks - store slices directly without copying
    fn onUrl(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *Parser = @ptrCast(@alignCast(parser.?.data));

        // llhttp may call this multiple times for a single URL if it spans buffer boundaries
        // For our use case with large enough buffers, we expect single calls
        if (self.url.len == 0) {
            self.url = at[0..length];
        } else {
            // URL spans multiple callbacks - this shouldn't happen with our buffer size
            // but handle it by keeping the first chunk (or we could return error)
            // For proper handling we'd need to track this differently
        }
        return 0;
    }

    fn onHeaderField(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *Parser = @ptrCast(@alignCast(parser.?.data));

        // If we have a completed previous header (field + value), save it
        if (self.current_header_value_start != null and self.current_header_field_start != null) {
            self.saveCurrentHeader() catch return -1;
        }

        // Track the field - may be called multiple times for same header if it spans chunks
        if (self.current_header_field_start == null) {
            self.current_header_field_start = at;
            self.current_header_field_len = length;
        } else {
            // Continuation of same field
            self.current_header_field_len += length;
        }

        return 0;
    }

    fn onHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *Parser = @ptrCast(@alignCast(parser.?.data));

        // Track the value - may be called multiple times if it spans chunks
        if (self.current_header_value_start == null) {
            self.current_header_value_start = at;
            self.current_header_value_len = length;
        } else {
            // Continuation of same value
            self.current_header_value_len += length;
        }

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *Parser = @ptrCast(@alignCast(parser.?.data));

        // Save the last header
        self.saveCurrentHeader() catch return -1;

        self.headers_complete = true;
        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *Parser = @ptrCast(@alignCast(parser.?.data));
        self.message_complete = true;
        return 0;
    }
};

test "Parser: basic GET request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parser: Parser = undefined;
    try parser.init(allocator);
    defer parser.deinit();

    const request = "GET /hello HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n";
    try parser.execute(request);

    try testing.expectEqual(Method.GET, parser.getMethod().?);
    try testing.expectEqualStrings("/hello", parser.url);
    try testing.expect(parser.headers_complete);
    try testing.expect(parser.message_complete);

    try testing.expectEqualStrings("localhost", parser.headers.get("Host").?);
    try testing.expectEqualStrings("test", parser.headers.get("User-Agent").?);
}

test "Parser: POST with multiple headers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parser: Parser = undefined;
    try parser.init(allocator);
    defer parser.deinit();

    const request = "POST /api/users HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"id\": 123}";
    try parser.execute(request);

    try testing.expectEqual(Method.POST, parser.getMethod().?);
    try testing.expectEqualStrings("/api/users", parser.url);
    try testing.expectEqualStrings("example.com", parser.headers.get("Host").?);
    try testing.expectEqualStrings("application/json", parser.headers.get("Content-Type").?);
    try testing.expectEqualStrings("13", parser.headers.get("Content-Length").?);
}

/// Response Parser wraps llhttp and manages the parsing state for HTTP responses
/// Stores slices directly into the read buffer for zero-copy parsing
pub const ResponseParser = struct {
    parser: c.llhttp_t,
    settings: c.llhttp_settings_t,

    // Parsing state - stores slices into the read buffer
    status_code: ?u16 = null,

    // Current header being built (llhttp may call callbacks multiple times per header)
    current_header_field_start: ?[*]const u8 = null,
    current_header_field_len: usize = 0,
    current_header_value_start: ?[*]const u8 = null,
    current_header_value_len: usize = 0,

    // Headers storage - keys and values are slices into read buffer
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    // Flags
    headers_complete: bool = false,
    message_complete: bool = false,

    pub fn init(self: *ResponseParser, allocator: std.mem.Allocator) !void {
        self.* = ResponseParser{
            .parser = undefined,
            .settings = undefined,
            .headers = .{},
            .allocator = allocator,
        };

        // Initialize settings to zero - this sets all callbacks to null
        self.settings = std.mem.zeroes(c.llhttp_settings_t);

        // Set up only the callbacks we need
        self.settings.on_header_field = onResponseHeaderField;
        self.settings.on_header_value = onResponseHeaderValue;
        self.settings.on_headers_complete = onResponseHeadersComplete;
        self.settings.on_message_complete = onResponseMessageComplete;
        self.settings.on_status_complete = onResponseStatusComplete;

        c.llhttp_init(&self.parser, c.HTTP_RESPONSE, &self.settings);

        // Set stable pointers now that ResponseParser won't move
        self.parser.data = @ptrCast(self);
        self.parser.settings = @ptrCast(&self.settings);
    }

    pub fn deinit(self: *ResponseParser) void {
        // No need to free slices - they point into the read buffer which is stack allocated
        // Just clean up the hashmap structure itself
        self.headers.deinit(self.allocator);
    }

    pub fn reset(self: *ResponseParser) void {
        self.status_code = null;
        self.current_header_field_start = null;
        self.current_header_field_len = 0;
        self.current_header_value_start = null;
        self.current_header_value_len = 0;

        // Headers should have been moved to ClientResponse, but ensure it's empty
        // (move() leaves the hashmap in an empty state)
        self.headers.clearRetainingCapacity();

        self.headers_complete = false;
        self.message_complete = false;

        c.llhttp_reset(&self.parser);
    }

    pub fn execute(self: *ResponseParser, data: []const u8) !void {
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);

        if (err != c.HPE_OK and err != c.HPE_PAUSED) {
            return self.mapError(err);
        }
    }

    pub fn finish(self: *ResponseParser) !void {
        const err = c.llhttp_finish(&self.parser);
        if (err != c.HPE_OK) {
            return self.mapError(err);
        }
    }

    pub fn shouldKeepAlive(self: *ResponseParser) bool {
        return c.llhttp_should_keep_alive(&self.parser) != 0;
    }

    fn mapError(self: *ResponseParser, err: c.llhttp_errno_t) ParseError {
        _ = self;
        return switch (err) {
            c.HPE_INVALID_METHOD => ParseError.InvalidMethod,
            c.HPE_INVALID_URL => ParseError.InvalidUrl,
            c.HPE_INVALID_HEADER_TOKEN => ParseError.InvalidHeaderToken,
            c.HPE_INVALID_VERSION => ParseError.InvalidVersion,
            c.HPE_INVALID_STATUS => ParseError.InvalidStatus,
            c.HPE_INVALID_CHUNK_SIZE => ParseError.InvalidChunkSize,
            c.HPE_UNEXPECTED_CONTENT_LENGTH => ParseError.UnexpectedContentLength,
            c.HPE_CLOSED_CONNECTION => ParseError.ClosedConnection,
            else => ParseError.ParseFailed,
        };
    }

    fn saveCurrentHeader(self: *ResponseParser) !void {
        if (self.current_header_field_start != null and self.current_header_value_start != null) {
            const field_start = self.current_header_field_start.?;
            const value_start = self.current_header_value_start.?;

            const field = field_start[0..self.current_header_field_len];
            const value = value_start[0..self.current_header_value_len];

            try self.headers.put(self.allocator, field, value);

            // Reset for next header
            self.current_header_field_start = null;
            self.current_header_field_len = 0;
            self.current_header_value_start = null;
            self.current_header_value_len = 0;
        }
    }

    // Callbacks - store slices directly without copying
    fn onResponseStatusComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @ptrCast(@alignCast(parser.?.data));
        self.status_code = @intCast(c.llhttp_get_status_code(parser));
        return 0;
    }

    fn onResponseHeaderField(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @ptrCast(@alignCast(parser.?.data));

        // If we have a completed previous header (field + value), save it
        if (self.current_header_value_start != null and self.current_header_field_start != null) {
            self.saveCurrentHeader() catch return -1;
        }

        // Track the field - may be called multiple times for same header if it spans chunks
        if (self.current_header_field_start == null) {
            self.current_header_field_start = at;
            self.current_header_field_len = length;
        } else {
            // Continuation of same field
            self.current_header_field_len += length;
        }

        return 0;
    }

    fn onResponseHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @ptrCast(@alignCast(parser.?.data));

        // Track the value - may be called multiple times if it spans chunks
        if (self.current_header_value_start == null) {
            self.current_header_value_start = at;
            self.current_header_value_len = length;
        } else {
            // Continuation of same value
            self.current_header_value_len += length;
        }

        return 0;
    }

    fn onResponseHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @ptrCast(@alignCast(parser.?.data));

        // Save the last header
        self.saveCurrentHeader() catch return -1;

        self.headers_complete = true;
        return 0;
    }

    fn onResponseMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @ptrCast(@alignCast(parser.?.data));
        self.message_complete = true;
        return 0;
    }
};

test "ResponseParser: basic 200 OK response" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var parser: ResponseParser = undefined;
    try parser.init(allocator);
    defer parser.deinit();

    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK";
    try parser.execute(response);

    try testing.expectEqual(@as(u16, 200), parser.status_code.?);
    try testing.expect(parser.headers_complete);
    try testing.expect(parser.message_complete);

    try testing.expectEqualStrings("text/plain", parser.headers.get("Content-Type").?);
    try testing.expectEqualStrings("2", parser.headers.get("Content-Length").?);
}
