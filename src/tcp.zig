const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const StreamReader = @import("stream.zig").StreamReader;
const StreamWriter = @import("stream.zig").StreamWriter;
const Runtime = @import("runtime.zig").Runtime;
const AnyTask = @import("runtime.zig").AnyTask;
const Executor = @import("runtime.zig").Executor;
const resumeTask = @import("runtime.zig").resumeTask;
const Cancelable = @import("runtime.zig").Cancelable;
const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;
const ResetEvent = @import("sync.zig").ResetEvent;

const TEST_PORT = 45001;

fn echoServer(rt: *Runtime, ready_event: *ResetEvent) !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
    var listener = try TcpListener.init(addr);
    defer listener.close(rt);

    try listener.bind(addr);
    try listener.listen(1);

    ready_event.set(rt);

    var stream = try listener.accept(rt);
    defer {
        stream.shutdown(rt) catch {};
        stream.close(rt);
    }

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(rt, &read_buffer);
    var writer = stream.writer(rt, &write_buffer);

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

    pub fn init(addr: std.net.Address) !TcpListener {
        return TcpListener{
            .xev_tcp = try xev.TCP.init(addr),
        };
    }

    pub fn bind(self: TcpListener, addr: std.net.Address) !void {
        try self.xev_tcp.bind(addr);
    }

    pub fn listen(self: TcpListener, backlog: u31) !void {
        try self.xev_tcp.listen(backlog);
    }

    pub fn accept(self: TcpListener, rt: *Runtime) !TcpStream {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
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
                resumeTask(result_data.task, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .task = task };

        self.xev_tcp.accept(
            &executor.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        try executor.waitForXevCompletion(&completion);

        const accepted_tcp = result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
        return TcpStream{
            .xev_tcp = accepted_tcp,
        };
    }

    pub fn close(self: TcpListener, rt: *Runtime) void {
        // Shield close operation from cancellation
        rt.beginShield();
        defer rt.endShield();

        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
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
                resumeTask(result_data.task, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .task = task };

        self.xev_tcp.close(
            &executor.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        // Shield ensures this never returns error.Canceled
        executor.waitForXevCompletion(&completion) catch unreachable;

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }
};

pub const TcpStream = struct {
    xev_tcp: xev.TCP,

    pub const ReadError = anyerror;
    pub const WriteError = anyerror;

    /// Establishes a TCP connection to the specified address.
    /// Returns a connected TcpStream on success.
    pub fn connect(rt: *Runtime, addr: std.net.Address) !TcpStream {
        const runtime = rt;
        var tcp = try xev.TCP.init(addr);
        const task = runtime.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
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
                resumeTask(result_data.task, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .task = task };

        tcp.connect(
            &executor.loop,
            &completion,
            addr,
            Result,
            &result_data,
            Result.callback,
        );

        try executor.waitForXevCompletion(&completion);

        result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };

        return TcpStream{
            .xev_tcp = tcp,
        };
    }

    /// Reads data from the stream into the provided buffer.
    /// Returns the number of bytes read, which may be less than buffer.len.
    /// A return value of 0 indicates end-of-stream.
    pub fn read(self: TcpStream, rt: *Runtime, buffer: []u8) !usize {
        var buf: xev.ReadBuffer = .{ .slice = buffer };
        return self.readBuf(rt, &buf) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => err,
        };
    }

    /// Returns the number of bytes read. If the number read is smaller than
    /// `buffer.len`, it means the stream reached the end. Reaching the end of
    /// a stream is not an error condition.
    pub fn readAll(self: TcpStream, rt: *Runtime, buffer: []u8) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            const n = try self.read(rt, buffer[index..]);
            if (n == 0) break;
            index += n;
        }
        return index;
    }

    /// Writes data to the stream. Returns the number of bytes written,
    /// which may be less than the length of data.
    pub fn write(self: TcpStream, rt: *Runtime, data: []const u8) !usize {
        return self.writeBuf(rt, .{ .slice = data });
    }

    /// Writes all data to the stream, looping until the entire buffer is written.
    /// Returns when all bytes have been written successfully.
    pub fn writeAll(self: TcpStream, rt: *Runtime, data: []const u8) !void {
        var offset: usize = 0;

        while (offset < data.len) {
            const bytes_written = try self.write(rt, data[offset..]);
            offset += bytes_written;
        }
    }

    /// Reads into multiple buffers using vectored I/O.
    /// Returns total bytes read. xev supports max 2 buffers.
    pub fn readVec(self: TcpStream, rt: *Runtime, iovecs: [][]u8) std.io.Reader.Error!usize {
        if (iovecs.len == 0) return 0;

        return self.readBuf(rt, xev.ReadBuffer.fromSlices(iovecs));
    }

    /// Writes from multiple buffers using vectored I/O.
    /// xev supports max 2 buffers.
    pub fn writeVec(self: TcpStream, rt: *Runtime, iovecs: []const []const u8) std.io.Writer.Error!usize {
        if (iovecs.len == 0) return 0;

        return self.writeBuf(rt, xev.WriteBuffer.fromSlices(iovecs));
    }

    /// Shuts down the write side of the TCP connection.
    /// This sends a FIN packet to signal that no more data will be sent.
    pub fn shutdown(self: TcpStream, rt: *Runtime) !void {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
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
                resumeTask(result_data.task, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .task = task };

        self.xev_tcp.shutdown(
            &executor.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        try executor.waitForXevCompletion(&completion);

        result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
    }

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.io.Writer compatible errors.
    pub fn writeBuf(self: TcpStream, rt: *Runtime, buffer: xev.WriteBuffer) (Cancelable || std.io.Writer.Error)!usize {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
            result: xev.WriteError!usize = undefined,
        };
        var result_data: Result = .{ .task = task };

        self.xev_tcp.write(
            &executor.loop,
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
                    resumeTask(r.task, .local);
                    return .disarm;
                }
            }).callback,
        );

        try executor.waitForXevCompletion(&completion);

        return result_data.result catch return error.WriteFailed;
    }

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.io.Reader compatible errors.
    pub fn readBuf(self: TcpStream, rt: *Runtime, buffer: *xev.ReadBuffer) (Cancelable || std.io.Reader.Error)!usize {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
            buffer: *xev.ReadBuffer,
            result: xev.ReadError!usize = undefined,
        };
        var result_data: Result = .{ .task = task, .buffer = buffer };

        self.xev_tcp.read(
            &executor.loop,
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
                    resumeTask(r.task, .local);
                    return .disarm;
                }
            }).callback,
        );

        try executor.waitForXevCompletion(&completion);

        const n = result_data.result catch |err| switch (err) {
            error.EOF => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;
        return n;
    }

    /// Closes the TCP stream and releases associated resources.
    /// This operation is asynchronous but returns immediately.
    pub fn close(self: TcpStream, rt: *Runtime) void {
        // Shield close operation from cancellation
        rt.beginShield();
        defer rt.endShield();

        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        var completion: xev.Completion = undefined;

        const Result = struct {
            task: *AnyTask,
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
                resumeTask(result_data.task, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .task = task };

        self.xev_tcp.close(
            &executor.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        // Shield ensures this never returns error.Canceled
        executor.waitForXevCompletion(&completion) catch unreachable;

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }

    // Zig 0.15+ streaming interface
    pub const Reader = StreamReader(*const TcpStream);
    pub const Writer = StreamWriter(*const TcpStream);

    // Zig 0.15+ interface methods
    pub fn reader(self: *const TcpStream, rt: *Runtime, buffer: []u8) Reader {
        return Reader.init(self, rt, buffer);
    }

    pub fn writer(self: *const TcpStream, rt: *Runtime, buffer: []u8) Writer {
        return Writer.init(self, rt, buffer);
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
            defer stream.close(rt);

            const test_data = "Hello, TCP!";
            try stream.writeAll(rt, test_data);
            try stream.shutdown(rt);

            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(rt, &buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
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
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            // Test splat: "ba" + "na" repeated 3 times = "bananana"
            var data = [_][]const u8{ "ba", "na" };
            const splat: usize = 3;
            try writer.interface.writeSplatAll(&data, splat);
            try writer.interface.flush();
            try stream.shutdown(rt);

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(rt, &read_buffer);

            const expected = "bananana";
            try testing.expectEqualStrings(expected, read_buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
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
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            // Test single element splat: "hello" repeated 3 times
            var data = [_][]const u8{"hello"};
            const splat: usize = 3;
            try writer.interface.writeSplatAll(&data, splat);
            try writer.interface.flush();
            try stream.shutdown(rt);

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(rt, &read_buffer);

            const expected = "hellohellohello";
            try testing.expectEqualStrings(expected, read_buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
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
            defer stream.close(rt);

            var write_buffer: [256]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            // Test single-character splat optimization: "x" repeated 50 times
            var data = [_][]const u8{"x"};
            const splat: usize = 50;
            try writer.interface.writeSplatAll(&data, splat);
            try writer.interface.flush();
            try stream.shutdown(rt);

            // Read back echoed data
            var read_buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(rt, &read_buffer);

            const expected = "x" ** 50;
            try testing.expectEqualStrings(expected, read_buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(echoServer, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
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
            var listener = try TcpListener.init(addr);
            defer listener.close(rt);

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept(rt);
            defer {
                stream.shutdown(rt) catch {};
                stream.close(rt);
            }

            var read_buffer: [1024]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);
            var writer = stream.writer(rt, &write_buffer);

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
            defer stream.close(rt);

            // Send RESP PING command
            const test_data = "*1\r\n$4\r\nPING\r\n";
            try stream.writeAll(rt, test_data);
            try stream.shutdown(rt);

            // Read back echoed data
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.readAll(rt, &buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
        }
    };

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_ready }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_ready }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
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
            var listener = try TcpListener.init(addr);
            defer listener.close(rt);

            try listener.bind(addr);
            try listener.listen(1);

            ready_event.set(rt);

            var stream = try listener.accept(rt);
            defer {
                stream.shutdown(rt) catch {};
                stream.close(rt);
            }

            // Send test data: "Hello World!"
            const test_data = "Hello World!";
            try stream.writeAll(rt, test_data);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, ready_event: *ResetEvent) !void {
            try ready_event.wait(rt);

            const addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.close(rt);

            // Test 1: ReadBuffer with .slice
            {
                var buffer: [5]u8 = undefined;
                var read_buf: xev.ReadBuffer = .{ .slice = &buffer };
                const n = try stream.readBuf(rt, &read_buf);
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
                const n = try stream.readBuf(rt, &read_buf);
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
                const n = try stream.readBuf(rt, &read_buf);
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

    try server_task.join();
    try client_task.join();
}
