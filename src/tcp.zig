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
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.WriteError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                buffer_inner: xev.WriteBuffer,
                result: xev.WriteError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_tcp.write(
            &self.runtime.loop,
            &completion,
            .{ .slice = data },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
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

    /// Writes data from the provided iovecs to the stream.
    /// Returns the number of bytes written from the first non-empty buffer.
    /// See https://github.com/ziglang/zig/issues/7699
    pub fn writev(self: *const TcpStream, iovecs: []const std.posix.iovec_const) anyerror!usize {
        // Find the first non-empty buffer
        for (iovecs) |iovec| {
            if (iovec.len == 0) continue;

            const buffer = iovec.base[0..iovec.len];
            return try self.write(buffer);
        }
        return 0; // All iovecs are empty
    }

    /// Writes all data from the provided iovecs to the stream, looping until
    /// all buffers are completely written.
    /// See https://github.com/ziglang/zig/issues/7699
    /// See equivalent function: `std.fs.File.writevAll`.
    pub fn writevAll(self: *const TcpStream, iovecs: []const std.posix.iovec_const) anyerror!void {
        for (iovecs) |iovec| {
            var buffer = iovec.base[0..iovec.len];
            while (buffer.len > 0) {
                const bytes_written = try self.write(buffer);
                buffer = buffer[bytes_written..];
            }
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
    pub fn writeVec(self: *const TcpStream, iovecs: []const []const u8) !usize {
        if (iovecs.len == 0) return 0;

        const usable = @min(iovecs.len, 2);
        const write_buf = xev.WriteBuffer.fromSlices(iovecs[0..usable]);

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
            write_buf,
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

        return result_data.result;
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

            // First flush any buffered data
            if (buffered.len > 0) {
                const n = w.tcp_stream.write(buffered) catch return error.WriteFailed;

                if (n < buffered.len) {
                    // Partial write - shift remaining data to front
                    std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                    io_writer.end = buffered.len - n;
                    return 0;
                }

                io_writer.end = 0;
            }

            // Write from data slices (all but last)
            for (data[0 .. data.len - 1]) |slice| {
                if (slice.len == 0) continue;
                return w.tcp_stream.write(slice) catch return error.WriteFailed;
            }

            // Handle splat pattern (last element repeated)
            const pattern = data[data.len - 1];
            if (pattern.len == 0 or splat == 0) return 0;

            return w.tcp_stream.write(pattern) catch return error.WriteFailed;
        }

        fn flush(io_writer: *std.io.Writer) std.io.Writer.Error!void {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_writer));

            while (io_writer.end > 0) {
                const buffered = io_writer.buffered();
                const n = w.tcp_stream.write(buffered) catch return error.WriteFailed;

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

test "TCP: writev writes first buffer only" {
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

            const data1 = "Hello";
            const data2 = ", ";
            const data3 = "World!";

            var iovecs = [_]std.posix.iovec_const{
                .{ .base = data1.ptr, .len = data1.len },
                .{ .base = data2.ptr, .len = data2.len },
                .{ .base = data3.ptr, .len = data3.len },
            };

            const bytes_written = try stream.writev(&iovecs);
            try stream.shutdown();
            try testing.expectEqual(5, bytes_written);

            var buffer: [20]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            try testing.expect(bytes_read >= 5);
            try testing.expectEqualStrings("Hello", buffer[0..5]);
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

test "TCP: writevAll writes all buffers" {
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

            const data1 = "Hello";
            const data2 = ", ";
            const data3 = "World!";

            var iovecs = [_]std.posix.iovec_const{
                .{ .base = data1.ptr, .len = data1.len },
                .{ .base = data2.ptr, .len = data2.len },
                .{ .base = data3.ptr, .len = data3.len },
            };

            try stream.writevAll(&iovecs);
            try stream.shutdown();

            var buffer: [20]u8 = undefined;
            var total_read: usize = 0;
            while (total_read < 13) {
                const n = try stream.read(buffer[total_read..]);
                if (n == 0) break;
                total_read += n;
            }
            try testing.expectEqual(13, total_read);
            try testing.expectEqualStrings("Hello, World!", buffer[0..total_read]);
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
