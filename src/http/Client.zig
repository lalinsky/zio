const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const TcpStream = @import("../tcp.zig").TcpStream;
const StreamReader = @import("../stream.zig").StreamReader;
const StreamWriter = @import("../stream.zig").StreamWriter;
const parser = @import("parser.zig");
const Method = parser.Method;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HTTP/1.1 Client
/// Maintains a persistent connection for multiple requests (keep-alive)
pub const Client = struct {
    stream: TcpStream,
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    reader: StreamReader(TcpStream),
    writer: StreamWriter(TcpStream),
    host: []const u8, // owned by allocator

    /// Connect to an HTTP server
    pub fn connect(
        runtime: *Runtime,
        allocator: std.mem.Allocator,
        addr: std.net.Address,
        host: []const u8,
    ) !Client {
        var stream = try TcpStream.connect(runtime, addr);
        errdefer stream.close();

        const read_buffer = try allocator.alloc(u8, 8192);
        errdefer allocator.free(read_buffer);

        const write_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buffer);

        const owned_host = try allocator.dupe(u8, host);
        errdefer allocator.free(owned_host);

        return Client{
            .stream = stream,
            .runtime = runtime,
            .allocator = allocator,
            .reader = stream.reader(read_buffer),
            .writer = stream.writer(write_buffer),
            .host = owned_host,
        };
    }

    pub fn close(self: *Client) void {
        self.stream.close();
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.host);
        self.allocator.free(self.writer.interface.buffer);
        self.allocator.free(self.reader.interface.buffer);
        self.close();
    }

    /// Make an HTTP request
    pub fn request(
        self: *Client,
        method: Method,
        path: []const u8,
        headers: []const Header,
        body: ?[]const u8,
    ) !ClientResponse {
        // Write request line: METHOD path HTTP/1.1\r\n
        try self.writer.interface.writeAll(method.toString());
        try self.writer.interface.writeAll(" ");
        try self.writer.interface.writeAll(path);
        try self.writer.interface.writeAll(" HTTP/1.1\r\n");

        // Write Host header
        try self.writer.interface.writeAll("Host: ");
        try self.writer.interface.writeAll(self.host);
        try self.writer.interface.writeAll("\r\n");

        // Write Content-Length if body is present
        if (body) |b| {
            var buf: [32]u8 = undefined;
            const len_str = try std.fmt.bufPrint(&buf, "{d}", .{b.len});
            try self.writer.interface.writeAll("Content-Length: ");
            try self.writer.interface.writeAll(len_str);
            try self.writer.interface.writeAll("\r\n");
        }

        // Write user-provided headers
        for (headers) |header| {
            try self.writer.interface.writeAll(header.name);
            try self.writer.interface.writeAll(": ");
            try self.writer.interface.writeAll(header.value);
            try self.writer.interface.writeAll("\r\n");
        }

        // End headers
        try self.writer.interface.writeAll("\r\n");

        // Write body if present
        if (body) |b| {
            try self.writer.interface.writeAll(b);
        }

        // Flush the request
        try self.writer.interface.flush();

        // Now read the response
        return try ClientResponse.read(self.allocator, &self.reader);
    }

    /// Convenience: GET request
    pub fn get(self: *Client, path: []const u8) !ClientResponse {
        return self.request(.GET, path, &.{}, null);
    }

    /// Convenience: POST request
    pub fn post(self: *Client, path: []const u8, body: []const u8) !ClientResponse {
        return self.request(.POST, path, &.{}, body);
    }
};

/// HTTP Response
pub const ClientResponse = struct {
    status: u16,
    headers: std.StringArrayHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    // TODO: Add body reading support

    fn read(allocator: std.mem.Allocator, reader: *StreamReader(TcpStream)) !ClientResponse {
        // Parse response using llhttp in HTTP_RESPONSE mode
        var p: parser.ResponseParser = undefined;
        try p.init(allocator);
        defer p.deinit();

        var parsed_len: usize = 0;

        // Parse response headers
        while (!p.headers_complete) {
            const buffered_data = reader.interface.buffered();
            const unparsed = buffered_data[parsed_len..];

            if (unparsed.len == 0) {
                // Try to read more data
                try reader.interface.fillMore();
                continue;
            }

            // Feed unparsed data to llhttp
            try p.execute(unparsed);

            // Track how much total data we have now
            parsed_len = reader.interface.bufferedLen();
        }

        // Move headers from parser
        const headers = p.headers.move();

        return ClientResponse{
            .status = p.status_code orelse return error.InvalidResponse,
            .headers = headers,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientResponse) void {
        self.headers.deinit(self.allocator);
    }

    /// Get header value by name (case-sensitive)
    pub fn header(self: *const ClientResponse, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Get header value by name (case-insensitive)
    pub fn headerIgnoreCase(self: *const ClientResponse, name: []const u8) ?[]const u8 {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }
};
