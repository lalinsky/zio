const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const io = @import("io.zig");
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

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.io.Writer compatible errors.
    pub fn writeBuf(self: *const TcpStream, buffer: xev.WriteBuffer) std.io.Writer.Error!usize {
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

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.io.Reader compatible errors.
    pub fn readBuf(self: *const TcpStream, buffer: *xev.ReadBuffer) std.io.Reader.Error!usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            buffer: *xev.ReadBuffer,
            result: xev.ReadError!usize = undefined,
        };
        var result_data: Result = .{ .waiter = waiter, .buffer = buffer };

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
                    r.waiter.markReady();
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
            ready_event.wait(rt);

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

    var server_ready = ResetEvent.init;

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            ready_event.wait(rt);

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
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
            ready_event.wait(rt);

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
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
            ready_event.wait(rt);

            const addr = try Address.parseIp4("127.0.0.1", TEST_PORT);
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
