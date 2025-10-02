const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Waiter = @import("runtime.zig").Waiter;
const Address = @import("address.zig").Address;
const ResetEvent = @import("sync.zig").ResetEvent;

const TEST_PORT = 45001;

fn echoServer(rt: *Runtime, ready_event: *ResetEvent) !void {
    const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
    var listener = try TcpListener.init(rt, addr);
    defer listener.close();

    try listener.bind(addr);
    try listener.listen(1);

    ready_event.set();

    var stream = try listener.accept();
    defer {
        stream.shutdown() catch {};
        stream.close();
    }

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    var writer = stream.writer(&write_buffer);

    while (true) {
        _ = reader.interface.stream(&writer.interface, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    try writer.interface.flush();
}

pub const TcpListener = struct {
    xev_tcp: xev.TCP,
    runtime: *Runtime,

    pub fn init(runtime: *Runtime, addr: Address) !TcpListener {
        return TcpListener{
            .xev_tcp = try xev.TCP.init(addr),
            .runtime = runtime,
        };
    }

    pub fn bind(self: *TcpListener, addr: Address) !void {
        try self.xev_tcp.bind(addr);
    }

    pub fn listen(self: *TcpListener, backlog: u31) !void {
        try self.xev_tcp.listen(backlog);
    }

    pub fn accept(self: *TcpListener) !TcpStream {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.AcceptError!xev.TCP = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                result: xev.AcceptError!xev.TCP,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.accept(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        const accepted_tcp = try result_data.result;
        return TcpStream{
            .xev_tcp = accepted_tcp,
            .runtime = self.runtime,
        };
    }

    pub fn close(self: *TcpListener) void {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.CloseError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }

    pub fn deinit(self: *TcpListener) void {
        self.close();
    }
};

pub const TcpStream = struct {
    xev_tcp: xev.TCP,
    runtime: *Runtime,

    pub const ReadError = anyerror;
    pub const WriteError = anyerror;

    /// Establishes a TCP connection to the specified address.
    /// Returns a connected TcpStream on success.
    pub fn connect(runtime: *Runtime, addr: Address) !TcpStream {
        var tcp = try xev.TCP.init(addr);
        var waiter = runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ConnectError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                result: xev.ConnectError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        tcp.connect(
            &runtime.loop,
            &completion,
            addr,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        try result_data.result;

        return TcpStream{
            .xev_tcp = tcp,
            .runtime = runtime,
        };
    }

    /// Reads data from the stream into the provided buffer.
    /// Returns the number of bytes read, which may be less than buffer.len.
    /// A return value of 0 indicates end-of-stream.
    pub fn read(self: *const TcpStream, buffer: []u8) !usize {
        return self.readBuf(.{ .slice = buffer }) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => err,
        };
    }

    /// Returns the number of bytes read. If the number read is smaller than
    /// `buffer.len`, it means the stream reached the end. Reaching the end of
    /// a stream is not an error condition.
    pub fn readAll(self: *const TcpStream, buffer: []u8) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            const n = try self.read(buffer[index..]);
            if (n == 0) break;
            index += n;
        }
        return index;
    }

    /// Writes data to the stream. Returns the number of bytes written,
    /// which may be less than the length of data.
    pub fn write(self: *const TcpStream, data: []const u8) !usize {
        return self.writeBuf(.{ .slice = data });
    }

    /// Writes all data to the stream, looping until the entire buffer is written.
    /// Returns when all bytes have been written successfully.
    pub fn writeAll(self: *const TcpStream, data: []const u8) !void {
        var offset: usize = 0;

        while (offset < data.len) {
            const bytes_written = try self.write(data[offset..]);
            offset += bytes_written;
        }
    }

    /// Reads into multiple buffers using vectored I/O.
    /// Returns total bytes read. xev supports max 2 buffers.
    pub fn readVec(self: *const TcpStream, iovecs: [][]u8) std.io.Reader.Error!usize {
        if (iovecs.len == 0) return 0;

        return self.readBuf(xev.ReadBuffer.fromSlices(iovecs));
    }

    /// Writes from multiple buffers using vectored I/O.
    /// xev supports max 2 buffers.
    pub fn writeVec(self: *const TcpStream, iovecs: []const []const u8) std.io.Writer.Error!usize {
        if (iovecs.len == 0) return 0;

        return self.writeBuf(xev.WriteBuffer.fromSlices(iovecs));
    }

    /// Shuts down the write side of the TCP connection.
    /// This sends a FIN packet to signal that no more data will be sent.
    pub fn shutdown(self: *TcpStream) !void {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ShutdownError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                result: xev.ShutdownError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.shutdown(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
    }

    /// Private low-level write function that all other write operations use.
    /// Accepts xev.WriteBuffer directly and returns std.io.Writer compatible errors.
    fn writeBuf(self: *const TcpStream, buffer: xev.WriteBuffer) std.io.Writer.Error!usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.WriteError!usize = undefined,
        };
        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.write(
            &self.runtime.loop,
            &completion,
            buffer,
            Result,
            &result_data,
            (struct {
                fn callback(
                    result_ptr: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.TCP,
                    _: xev.WriteBuffer,
                    result: xev.WriteError!usize,
                ) xev.CallbackAction {
                    result_ptr.?.result = result;
                    result_ptr.?.waiter.markReady();
                    return .disarm;
                }
            }).callback,
        );

        waiter.waitForReady();

        return result_data.result catch return error.WriteFailed;
    }

    /// Private low-level read function that all other read operations use.
    /// Accepts xev.ReadBuffer directly and returns std.io.Reader compatible errors.
    fn readBuf(self: *const TcpStream, buffer: xev.ReadBuffer) std.io.Reader.Error!usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ReadError!usize = undefined,
        };
        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.read(
            &self.runtime.loop,
            &completion,
            buffer,
            Result,
            &result_data,
            (struct {
                fn callback(
                    result_ptr: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.TCP,
                    _: xev.ReadBuffer,
                    result: xev.ReadError!usize,
                ) xev.CallbackAction {
                    result_ptr.?.result = result;
                    result_ptr.?.waiter.markReady();
                    return .disarm;
                }
            }).callback,
        );

        waiter.waitForReady();

        const n = result_data.result catch |err| switch (err) {
            error.EOF => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        return n;
    }

    /// Closes the TCP stream and releases associated resources.
    /// This operation is asynchronous but returns immediately.
    pub fn close(self: *TcpStream) void {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.CloseError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }

    // New Zig 0.15 streaming interface
    pub const Reader = struct {
        tcp_stream: *const TcpStream,
        interface: std.io.Reader,

        pub fn init(tcp_stream: *const TcpStream, buffer: []u8) Reader {
            return .{
                .tcp_stream = tcp_stream,
                .interface = .{
                    .vtable = &.{
                        .stream = Reader.stream,
                        .discard = Reader.discard,
                        .readVec = Reader.readVec,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(io_reader: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
            const dest = limit.slice(try w.writableSliceGreedy(1));

            const n = try r.tcp_stream.readBuf(.{ .slice = dest });

            w.advance(n);
            return n;
        }

        fn discard(io_reader: *std.io.Reader, limit: std.io.Limit) std.io.Reader.Error!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
            // Use the buffer as temporary storage for discarded data
            var total_discarded: usize = 0;
            const remaining = @intFromEnum(limit);

            while (total_discarded < remaining) {
                const to_read = @min(remaining - total_discarded, io_reader.buffer.len);
                const n = r.tcp_stream.readBuf(.{ .slice = io_reader.buffer[0..to_read] }) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return error.ReadFailed,
                };
                total_discarded += n;
            }
            return total_discarded;
        }

        fn readVec(io_reader: *std.io.Reader, data: [][]u8) std.io.Reader.Error!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));

            var buf: xev.ReadBuffer = .{ .vectors = .{ .data = undefined, .len = 0 } };
            const dest_n, const data_size = if (builtin.os.tag == .windows)
                try io_reader.writableVectorWsa(&buf.vectors.data, data)
            else
                try io_reader.writableVectorPosix(&buf.vectors.data, data);

            buf.vectors.len = dest_n;
            if (dest_n == 0) return 0;

            const n = try r.tcp_stream.readBuf(buf);

            // Update buffer end pointer if we read into internal buffer
            if (n > data_size) {
                io_reader.end += n - data_size;
                return data_size;
            }
            return n;
        }
    };

    pub const Writer = struct {
        tcp_stream: *const TcpStream,
        interface: std.io.Writer,

        pub fn init(tcp_stream: *const TcpStream, buffer: []u8) Writer {
            return .{
                .tcp_stream = tcp_stream,
                .interface = .{
                    .vtable = &.{
                        .drain = Writer.drain,
                        .flush = Writer.flush,
                    },
                    .buffer = buffer,
                    .end = 0,
                },
            };
        }

        fn drain(io_writer: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_writer));
            const buffered = io_writer.buffered();

            // Build write buffer using vectored I/O
            // xev supports max 2 vectors, so we need to handle this carefully
            var vecs: [2][]const u8 = undefined;
            var vec_count: usize = 0;

            // Strategy: Try to include buffered data + first data slice in vecs[0],
            // then pattern (potentially repeated) in vecs[1]

            if (buffered.len > 0) {
                vecs[vec_count] = buffered;
                vec_count += 1;
            }

            // Try to add first non-empty data slice
            var first_slice_idx: ?usize = null;
            for (data[0 .. data.len - 1], 0..) |slice, i| {
                if (slice.len == 0) continue;
                first_slice_idx = i;
                if (vec_count < 2) {
                    vecs[vec_count] = slice;
                    vec_count += 1;
                }
                break;
            }

            const pattern = data[data.len - 1];

            // Add pattern for splat if we have room
            if (splat > 0 and pattern.len > 0 and vec_count < 2) {
                vecs[vec_count] = pattern;
                vec_count += 1;
            }

            // If we have vectors to write, do the write
            if (vec_count > 0) {
                const write_buf = xev.WriteBuffer.fromSlices(vecs[0..vec_count]);

                const n = try w.tcp_stream.writeBuf(write_buf);

                // Handle partial write of buffered data
                if (buffered.len > 0) {
                    if (n < buffered.len) {
                        std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                        io_writer.end = buffered.len - n;
                        return 0;
                    }
                    io_writer.end = 0;
                    const consumed = n - buffered.len;
                    if (consumed == 0) return 0;

                    // Check if we wrote into first data slice
                    if (first_slice_idx) |idx| {
                        const slice = data[idx];
                        if (consumed < slice.len) {
                            // Partial write of first slice - can't continue from here
                            return consumed;
                        }
                        // Wrote full first slice, check pattern
                        if (consumed >= slice.len and pattern.len > 0) {
                            const pattern_written = consumed - slice.len;
                            if (pattern_written > 0) {
                                // Wrote some of pattern, need to track splat progress
                                // For simplicity, return what we wrote
                                return consumed;
                            }
                        }
                    }
                    return consumed;
                }

                // No buffered data - wrote directly from data slices
                return n;
            }

            // No vectors written - handle remaining slices and splat sequentially
            // This handles case where we need to write multiple data slices or splat > 1

            var written: usize = 0;

            // Write remaining data slices
            for (data[0 .. data.len - 1]) |slice| {
                if (slice.len == 0) continue;
                const n = try w.tcp_stream.writeBuf(.{ .slice = slice });
                written += n;
                if (n < slice.len) return written; // Partial write
            }

            // Handle splat - write pattern splat times
            if (pattern.len > 0) {
                for (0..splat) |_| {
                    const n = try w.tcp_stream.writeBuf(.{ .slice = pattern });
                    written += n;
                    if (n < pattern.len) return written; // Partial write
                }
            }

            return written;
        }

        fn flush(io_writer: *std.io.Writer) std.io.Writer.Error!void {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_writer));

            while (io_writer.end > 0) {
                const buffered = io_writer.buffered();
                const n = try w.tcp_stream.writeBuf(.{ .slice = buffered });

                if (n == 0) return error.WriteFailed; // No progress

                if (n < buffered.len) {
                    // Partial write - shift remaining
                    std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                    io_writer.end -= n;
                } else {
                    io_writer.end = 0;
                }
            }
        }
    };

    // Zig 0.15+ interface methods
    pub fn reader(self: *const TcpStream, buffer: []u8) Reader {
        return Reader.init(self, buffer);
    }

    pub fn writer(self: *const TcpStream, buffer: []u8) Writer {
        return Writer.init(self, buffer);
    }
};

test "TCP: basic echo server and client" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init(&runtime);

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            ready_event.wait();

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            const test_data = "Hello, TCP!";
            try stream.writeAll(test_data);
            try stream.shutdown();

            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}

test "TCP: Writer splat handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init(&runtime);

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            ready_event.wait();

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Test splat: "ba" + "na" repeated 3 times = "bananana"
            const data: []const []const u8 = &.{ "ba", "na" };
            const splat: usize = 3;
            _ = try writer.interface.writeSplat(data, splat);
            try writer.interface.flush();
            try stream.shutdown();

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(&read_buffer);

            const expected = "bananana";
            try testing.expectEqualStrings(expected, read_buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}

test "TCP: Writer splat with single element" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init(&runtime);

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            ready_event.wait();

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Test single element splat: "hello" repeated 3 times
            const data: []const []const u8 = &.{"hello"};
            const splat: usize = 3;
            _ = try writer.interface.writeSplat(data, splat);
            try writer.interface.flush();
            try stream.shutdown();

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(&read_buffer);

            const expected = "hellohellohello";
            try testing.expectEqualStrings(expected, read_buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}
