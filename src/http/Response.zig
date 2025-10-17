const std = @import("std");
const TcpStream = @import("../tcp.zig").TcpStream;
const StreamWriter = @import("../stream.zig").StreamWriter;

/// What to do with the connection after the response
pub const Handover = enum {
    close,
    keepalive,
};

/// HTTP Response writer
pub const Response = struct {
    stream: *TcpStream,
    writer: StreamWriter(TcpStream),
    status_written: bool = false,
    headers_written: bool = false,
    content_length_written: bool = false,
    handover: Handover = .close,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, stream: *TcpStream, buffer: []u8) Response {
        return Response{
            .stream = stream,
            .writer = stream.writer(buffer),
            .allocator = allocator,
        };
    }

    /// Set what to do with the connection after this response
    pub fn setHandover(self: *Response, handover: Handover) void {
        self.handover = handover;
    }

    /// Write HTTP status line
    pub fn writeStatus(self: *Response, code: u16) !void {
        if (self.status_written) return error.StatusAlreadyWritten;

        const reason = statusReason(code);
        try self.writer.interface.writeAll("HTTP/1.1 ");

        // Write status code
        var buf: [16]u8 = undefined;
        const code_str = try std.fmt.bufPrint(&buf, "{d}", .{code});
        try self.writer.interface.writeAll(code_str);

        try self.writer.interface.writeAll(" ");
        try self.writer.interface.writeAll(reason);
        try self.writer.interface.writeAll("\r\n");

        self.status_written = true;
    }

    /// Write a single header
    pub fn writeHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (!self.status_written) return error.StatusNotWritten;
        if (self.headers_written) return error.HeadersAlreadyWritten;

        // Track if Content-Length is being written
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            self.content_length_written = true;
        }

        try self.writer.interface.writeAll(name);
        try self.writer.interface.writeAll(": ");
        try self.writer.interface.writeAll(value);
        try self.writer.interface.writeAll("\r\n");
    }

    /// Finish writing headers (writes empty line)
    pub fn finishHeaders(self: *Response) !void {
        if (!self.status_written) return error.StatusNotWritten;
        if (self.headers_written) return;

        // If keep-alive was requested but no Content-Length was written,
        // we must close the connection (no chunked encoding support yet)
        if (self.handover == .keepalive and !self.content_length_written) {
            self.handover = .close;
        }

        // Always write Connection header based on handover
        switch (self.handover) {
            .close => try self.writer.interface.writeAll("Connection: close\r\n"),
            .keepalive => try self.writer.interface.writeAll("Connection: keep-alive\r\n"),
        }

        try self.writer.interface.writeAll("\r\n");
        self.headers_written = true;
    }

    /// Write response body
    pub fn writeBody(self: *Response, data: []const u8) !void {
        if (!self.headers_written) {
            try self.finishHeaders();
        }

        try self.writer.interface.writeAll(data);
    }

    /// Flush the response
    pub fn flush(self: *Response) !void {
        try self.writer.interface.flush();
    }

    fn statusReason(code: u16) []const u8 {
        return switch (code) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }
};

test "Response: statusReason" {
    const testing = std.testing;

    try testing.expectEqualStrings("OK", Response.statusReason(200));
    try testing.expectEqualStrings("Not Found", Response.statusReason(404));
    try testing.expectEqualStrings("Internal Server Error", Response.statusReason(500));
}
