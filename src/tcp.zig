const std = @import("std");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Waiter = @import("runtime.zig").Waiter;
const Address = @import("address.zig").Address;

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

    };

pub const TcpStream = struct {
    xev_tcp: xev.TCP,
    runtime: *Runtime,

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

    pub fn read(self: *const TcpStream, buffer: []u8) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ReadError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.TCP,
                buffer_inner: xev.ReadBuffer,
                result: xev.ReadError!usize,
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

        self.xev_tcp.read(
            &self.runtime.loop,
            &completion,
            .{ .slice = buffer },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
    }

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
                        .stream = stream,
                        .discard = discard,
                        .readVec = readVec,
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
            const n = r.tcp_stream.read(dest) catch |err| switch (err) {
                error.Canceled => return error.ReadFailed,
                error.ConnectionResetByPeer => return error.ReadFailed,
                error.EOF => return error.EndOfStream,
                error.Unexpected => return error.ReadFailed,
                else => |e| return e,
            };
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
                const n = r.tcp_stream.read(io_reader.buffer[0..to_read]) catch |err| switch (err) {
                    error.Canceled => return error.ReadFailed,
                    error.ConnectionResetByPeer => return error.ReadFailed,
                    error.EOF => return error.EndOfStream,
                    error.Unexpected => return error.ReadFailed,
                    else => |e| return e,
                };
                if (n == 0) break;
                total_discarded += n;
            }
            return total_discarded;
        }

        fn readVec(io_reader: *std.io.Reader, data: [][]u8) std.io.Reader.Error!usize {
            const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));

            if (data.len == 0) return 0;

            // Read into the first (and typically largest) buffer
            const dest = data[0];
            if (dest.len == 0) {
                // If first buffer is empty, use the reader's internal buffer
                const n = r.tcp_stream.read(io_reader.buffer) catch |err| switch (err) {
                    error.Canceled => return error.ReadFailed,
                    error.ConnectionResetByPeer => return error.ReadFailed,
                    error.EOF => return error.EndOfStream,
                    error.Unexpected => return error.ReadFailed,
                    else => |e| return e,
                };
                io_reader.end = n;
                return 0;
            }

            const n = r.tcp_stream.read(dest) catch |err| switch (err) {
                error.Canceled => return error.ReadFailed,
                error.ConnectionResetByPeer => return error.ReadFailed,
                error.EOF => return error.EndOfStream,
                error.Unexpected => return error.ReadFailed,
                else => |e| return e,
            };
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
                        .drain = drain,
                        .flush = flush,
                    },
                    .buffer = buffer,
                    .end = 0,
                },
            };
        }

        fn drain(io_writer: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_writer));

            // First, write any buffered data
            if (io_writer.end > 0) {
                _ = w.tcp_stream.write(io_writer.buffer[0..io_writer.end]) catch |err| switch (err) {
                    error.BrokenPipe => return error.WriteFailed,
                    error.Canceled => return error.WriteFailed,
                    error.ConnectionResetByPeer => return error.WriteFailed,
                    error.Unexpected => return error.WriteFailed,
                    else => |e| return e,
                };
                io_writer.end = 0;
            }

            // Then write the provided data
            var total_written: usize = 0;
            for (data) |slice| {
                for (0..@max(1, splat)) |_| {
                    const n = w.tcp_stream.write(slice) catch |err| switch (err) {
                        error.BrokenPipe => return error.WriteFailed,
                        error.Canceled => return error.WriteFailed,
                        error.ConnectionResetByPeer => return error.WriteFailed,
                        error.Unexpected => return error.WriteFailed,
                        else => |e| return e,
                    };
                    total_written += n;
                    if (n < slice.len) return total_written;
                }
            }
            return total_written;
        }

        fn flush(io_writer: *std.io.Writer) std.io.Writer.Error!void {
            const w: *Writer = @alignCast(@fieldParentPtr("interface", io_writer));

            if (io_writer.end > 0) {
                _ = w.tcp_stream.write(io_writer.buffer[0..io_writer.end]) catch |err| switch (err) {
                    error.BrokenPipe => return error.WriteFailed,
                    error.Canceled => return error.WriteFailed,
                    error.ConnectionResetByPeer => return error.WriteFailed,
                    error.Unexpected => return error.WriteFailed,
                    else => |e| return e,
                };
                io_writer.end = 0;
            }
        }
    };

    // Standard interface methods (following std.fs.File pattern)
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

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime) !void {
            const addr = try Address.parseIp4("127.0.0.1", 0);
            var listener = try TcpListener.init(rt, addr);
            defer listener.deinit();

            try listener.bind(addr);
            try listener.listen(1);

            // Accept one connection
            var stream = try listener.accept();

            // Read and echo back
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            const bytes_written = try stream.write(buffer[0..bytes_read]);
            try testing.expect(bytes_written == bytes_read);

            try stream.shutdown();
            stream.close();
            listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10); // Give server time to start

            const addr = try Address.parseIp4("127.0.0.1", 8080);
            var stream = try TcpStream.connect(rt, addr);

            // Send test data
            const test_data = "Hello, TCP!";
            const bytes_written = try stream.write(test_data);
            try testing.expect(bytes_written == test_data.len);

            // Read response
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);

            try stream.shutdown();
            stream.close();
        }
    };

    const server_task = try runtime.spawn(ServerTask.run, .{&runtime}, .{});
    defer server_task.deinit();

    const client_task = try runtime.spawn(ClientTask.run, .{&runtime}, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}
