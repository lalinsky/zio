const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const io = @import("io.zig");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("runtime.zig").Cancelable;
const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;
const ResetEvent = @import("sync.zig").ResetEvent;

const TEST_PORT = 45001;

fn echoServer(rt: *Runtime, ready_event: *ResetEvent) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
    var listener = try TcpListener.init(rt, addr);
    defer listener.close();

    try listener.bind(addr);
    try listener.listen(1);

    ready_event.set(rt);

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

    pub fn init(runtime: *Runtime, addr: std.net.Address) !TcpListener {
        return TcpListener{
            .xev_tcp = try xev.TCP.init(addr),
            .runtime = runtime,
        };
    }

    pub fn bind(self: *TcpListener, addr: std.net.Address) !void {
        try self.xev_tcp.bind(addr);
    }

    pub fn listen(self: *TcpListener, backlog: u31) !void {
        try self.xev_tcp.listen(backlog);
    }

    pub fn accept(self: *TcpListener) !TcpStream {
        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
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
                Runtime.fromCoroutine(result_data.coro).markReady(result_data.coro);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_tcp.accept(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        try self.runtime.waitForXevCompletion(&completion);

        const accepted_tcp = result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
        return TcpStream{
            .xev_tcp = accepted_tcp,
            .runtime = self.runtime,
        };
    }

    pub fn close(self: *TcpListener) void {
        // Shield close operation from cancellation
        self.runtime.beginShield();
        defer self.runtime.endShield();

        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
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
                Runtime.fromCoroutine(result_data.coro).markReady(result_data.coro);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_tcp.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        // Shield ensures this never returns error.Canceled
        self.runtime.waitForXevCompletion(&completion) catch unreachable;

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
    pub fn connect(runtime: *Runtime, addr: std.net.Address) !TcpStream {
        var tcp = try xev.TCP.init(addr);
        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
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
                Runtime.fromCoroutine(result_data.coro).markReady(result_data.coro);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        tcp.connect(
            &runtime.loop,
            &completion,
            addr,
            Result,
            &result_data,
            Result.callback,
        );

        try runtime.waitForXevCompletion(&completion);

        result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };

        return TcpStream{
            .xev_tcp = tcp,
            .runtime = runtime,
        };
    }

    /// Reads data from the stream into the provided buffer.
    /// Returns the number of bytes read, which may be less than buffer.len.
    /// A return value of 0 indicates end-of-stream.
    pub fn read(self: *const TcpStream, buffer: []u8) !usize {
        var buf: xev.ReadBuffer = .{ .slice = buffer };
        return self.readBuf(&buf) catch |err| switch (err) {
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
        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
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
                Runtime.fromCoroutine(result_data.coro).markReady(result_data.coro);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_tcp.shutdown(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        try self.runtime.waitForXevCompletion(&completion);

        result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
    }

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.io.Writer compatible errors.
    pub fn writeBuf(self: *const TcpStream, buffer: xev.WriteBuffer) (Cancelable || std.io.Writer.Error)!usize {
        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
            result: xev.WriteError!usize = undefined,
        };
        var result_data: Result = .{ .coro = coro };

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
                    const r = result_ptr.?;
                    r.result = result;
                    Runtime.fromCoroutine(r.coro).markReady(r.coro);
                    return .disarm;
                }
            }).callback,
        );

        try self.runtime.waitForXevCompletion(&completion);

        return result_data.result catch return error.WriteFailed;
    }

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.io.Reader compatible errors.
    pub fn readBuf(self: *const TcpStream, buffer: *xev.ReadBuffer) (Cancelable || std.io.Reader.Error)!usize {
        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
            buffer: *xev.ReadBuffer,
            result: xev.ReadError!usize = undefined,
        };
        var result_data: Result = .{ .coro = coro, .buffer = buffer };

        self.xev_tcp.read(
            &self.runtime.loop,
            &completion,
            buffer.*,
            Result,
            &result_data,
            (struct {
                fn callback(
                    result_ptr: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.TCP,
                    buf: xev.ReadBuffer,
                    result: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const r = result_ptr.?;
                    r.result = result;
                    // Copy array data back to caller's buffer
                    if (buf == .array) {
                        r.buffer.array = buf.array;
                    }
                    Runtime.fromCoroutine(r.coro).markReady(r.coro);
                    return .disarm;
                }
            }).callback,
        );

        try self.runtime.waitForXevCompletion(&completion);

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
        // Shield close operation from cancellation
        self.runtime.beginShield();
        defer self.runtime.endShield();

        const coro = coroutines.getCurrent().?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
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
                Runtime.fromCoroutine(result_data.coro).markReady(result_data.coro);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_tcp.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        // Shield ensures this never returns error.Canceled
        self.runtime.waitForXevCompletion(&completion) catch unreachable;

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }

    // Zig 0.15+ streaming interface
    pub const Reader = io.StreamReader(TcpStream);
    pub const Writer = io.StreamWriter(TcpStream);

    // Zig 0.15+ interface methods
    pub fn reader(self: *const TcpStream, buffer: []u8) Reader {
        return Reader.init(@constCast(self), buffer);
    }

    pub fn writer(self: *const TcpStream, buffer: []u8) Writer {
        return Writer.init(@constCast(self), buffer);
    }
};

test "TCP: basic echo server and client" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
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

    var server_ready = ResetEvent.init;

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Test splat: "ba" + "na" repeated 3 times = "bananana"
            var data = [_][]const u8{ "ba", "na" };
            const splat: usize = 3;
            try writer.interface.writeSplatAll(&data, splat);
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

    var server_ready = ResetEvent.init;

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Test single element splat: "hello" repeated 3 times
            var data = [_][]const u8{"hello"};
            const splat: usize = 3;
            try writer.interface.writeSplatAll(&data, splat);
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

test "TCP: Writer splat with single character" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            // Test single-character splat optimization: "x" repeated 50 times
            var data = [_][]const u8{"x"};
            const splat: usize = 50;
            try writer.interface.writeSplatAll(&data, splat);
            try writer.interface.flush();
            try stream.shutdown();

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(&read_buffer);

            const expected = "x" ** 50;
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

test "TCP: Reader takeByte with RESP protocol" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ServerTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var listener = try TcpListener.init(rt, addr);
            defer listener.close();

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept();
            defer {
                stream.shutdown() catch {};
                stream.close();
            }

            var read_buffer: [1024]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = stream.reader(&read_buffer);
            var writer = stream.writer(&write_buffer);

            // Read RESP protocol data using takeByte
            const first_byte = try reader.interface.takeByte();
            try testing.expectEqual(@as(u8, '*'), first_byte);

            const line1 = try reader.interface.takeDelimiterExclusive('\r');
            try testing.expectEqualStrings("1", line1);
            _ = try reader.interface.takeDelimiterExclusive('\n');

            const line2 = try reader.interface.takeDelimiterExclusive('\r');
            try testing.expectEqualStrings("$4", line2);
            _ = try reader.interface.takeDelimiterExclusive('\n');

            const line3 = try reader.interface.takeDelimiterExclusive('\r');
            try testing.expectEqualStrings("PING", line3);
            _ = try reader.interface.takeDelimiterExclusive('\n');

            // Echo back
            try writer.interface.writeAll(&[_]u8{first_byte});
            try writer.interface.writeAll(line1);
            try writer.interface.writeAll("\r\n");
            try writer.interface.writeAll(line2);
            try writer.interface.writeAll("\r\n");
            try writer.interface.writeAll(line3);
            try writer.interface.writeAll("\r\n");
            try writer.interface.flush();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            // Send RESP PING command
            const test_data = "*1\r\n$4\r\nPING\r\n";
            try stream.writeAll(test_data);
            try stream.shutdown();

            // Read back echoed data
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}

test "TCP: readBuf with different ReadBuffer variants" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    var server_ready = ResetEvent.init;

    const ServerTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var listener = try TcpListener.init(rt, addr);
            defer listener.close();

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept();
            defer {
                stream.shutdown() catch {};
                stream.close();
            }

            // Send test data: "Hello World!"
            const test_data = "Hello World!";
            try stream.writeAll(test_data);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close();

            // Test 1: ReadBuffer with .slice
            {
                var buffer: [5]u8 = undefined;
                var read_buf: xev.ReadBuffer = .{ .slice = &buffer };
                const n = try stream.readBuf(&read_buf);
                try testing.expectEqual(5, n);
                try testing.expectEqualStrings("Hello", buffer[0..n]);
            }

            // Test 2: ReadBuffer with .vectors containing 1 iovec
            {
                var buffer: [3]u8 = undefined;
                var unused_buffer: [1]u8 = undefined;
                var read_buf: xev.ReadBuffer = .{
                    .vectors = .{
                        .data = if (builtin.os.tag == .windows) .{
                            .{ .buf = &buffer, .len = buffer.len },
                            .{ .buf = &unused_buffer, .len = 0 }, // Second vector unused but must be valid
                        } else .{
                            .{ .base = &buffer, .len = buffer.len },
                            .{ .base = &unused_buffer, .len = 0 }, // Second vector unused but must be valid
                        },
                        .len = 1,
                    },
                };
                const n = try stream.readBuf(&read_buf);
                try testing.expectEqual(3, n);
                try testing.expectEqualStrings(" Wo", buffer[0..n]);
            }

            // Test 3: ReadBuffer with .vectors containing 2 iovecs
            {
                var buffer1: [2]u8 = undefined;
                var buffer2: [2]u8 = undefined;
                var read_buf: xev.ReadBuffer = .{ .vectors = .{ .data = if (builtin.os.tag == .windows) .{
                    .{ .buf = &buffer1, .len = buffer1.len },
                    .{ .buf = &buffer2, .len = buffer2.len },
                } else .{
                    .{ .base = &buffer1, .len = buffer1.len },
                    .{ .base = &buffer2, .len = buffer2.len },
                }, .len = 2 } };
                const n = try stream.readBuf(&read_buf);
                try testing.expectEqual(4, n);
                try testing.expectEqualStrings("rl", buffer1[0..]);
                try testing.expectEqualStrings("d!", buffer2[0..]);
            }
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}
