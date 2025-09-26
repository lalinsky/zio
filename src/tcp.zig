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

    pub const ReadError = anyerror;
    pub const WriteError = anyerror;

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

    pub fn readv(self: *const TcpStream, iovecs: []std.posix.iovec) anyerror!usize {
        // Find the first non-empty buffer
        for (iovecs) |iovec| {
            if (iovec.len == 0) continue;

            const buffer = iovec.base[0..iovec.len];
            return try self.read(buffer);
        }
        return 0; // All iovecs are empty
    }

    pub fn readvAll(self: *const TcpStream, iovecs: []std.posix.iovec) anyerror!usize {
        var total_read: usize = 0;

        for (iovecs) |iovec| {
            var buffer = iovec.base[0..iovec.len];

            while (buffer.len > 0) {
                const bytes_read = try self.read(buffer);

                if (bytes_read == 0) {
                    return total_read; // EOF reached
                }

                buffer = buffer[bytes_read..];
                total_read += bytes_read;
            }
        }

        return total_read;
    }

    pub fn readAtLeast(self: *const TcpStream, buffer: []u8, len: usize) anyerror!usize {
        std.debug.assert(len <= buffer.len);
        var index: usize = 0;
        while (index < len) {
            const amt = try self.read(buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
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

    pub fn writev(self: *const TcpStream, iovecs: []const std.posix.iovec_const) anyerror!usize {
        // Find the first non-empty buffer
        for (iovecs) |iovec| {
            if (iovec.len == 0) continue;

            const buffer = iovec.base[0..iovec.len];
            return try self.write(buffer);
        }
        return 0; // All iovecs are empty
    }

    pub fn writevAll(self: *const TcpStream, iovecs: []const std.posix.iovec_const) anyerror!void {
        for (iovecs) |iovec| {
            var buffer = iovec.base[0..iovec.len];

            while (buffer.len > 0) {
                const bytes_written = try self.write(buffer);
                buffer = buffer[bytes_written..];
            }
        }
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

    pub fn reader(self: *const TcpStream) std.io.Reader(*const TcpStream, anyerror, read) {
        return .{ .context = self };
    }

    pub fn writer(self: *const TcpStream) std.io.Writer(*const TcpStream, anyerror, write) {
        return .{ .context = self };
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

test "TCP: readv reads first buffer only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime) !void {
            const addr = try Address.parseIp4("127.0.0.1", 0);
            var listener = try TcpListener.init(rt, addr);

            try listener.bind(addr);
            try listener.listen(1);

            var stream = try listener.accept();
            _ = try stream.write("Hello, World!");

            try stream.shutdown();
            stream.close();
            listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10);

            const addr = try Address.parseIp4("127.0.0.1", 8080);
            var stream = try TcpStream.connect(rt, addr);

            var buf1: [5]u8 = undefined;
            const buf2: [5]u8 = undefined;
            const buf3: [10]u8 = undefined;

            var iovecs = [_]std.posix.iovec{
                .{ .base = buf1.ptr, .len = buf1.len },
                .{ .base = @constCast(buf2.ptr), .len = buf2.len },
                .{ .base = @constCast(buf3.ptr), .len = buf3.len },
            };

            const bytes_read = try stream.readv(&iovecs);
            try testing.expect(bytes_read == 5);
            try testing.expectEqualStrings("Hello", &buf1);

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

test "TCP: readvAll reads all buffers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime) !void {
            const addr = try Address.parseIp4("127.0.0.1", 0);
            var listener = try TcpListener.init(rt, addr);

            try listener.bind(addr);
            try listener.listen(1);

            var stream = try listener.accept();
            _ = try stream.write("Hello, World!");

            try stream.shutdown();
            stream.close();
            listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10);

            const addr = try Address.parseIp4("127.0.0.1", 8081);
            var stream = try TcpStream.connect(rt, addr);

            var buf1: [5]u8 = undefined;
            var buf2: [2]u8 = undefined;
            var buf3: [6]u8 = undefined;

            var iovecs = [_]std.posix.iovec{
                .{ .base = buf1.ptr, .len = buf1.len },
                .{ .base = buf2.ptr, .len = buf2.len },
                .{ .base = buf3.ptr, .len = buf3.len },
            };

            const bytes_read = try stream.readvAll(&iovecs);
            try testing.expect(bytes_read == 13);
            try testing.expectEqualStrings("Hello", &buf1);
            try testing.expectEqualStrings(", ", &buf2);
            try testing.expectEqualStrings("World!", &buf3);

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

test "TCP: writev writes first buffer only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime) !void {
            const addr = try Address.parseIp4("127.0.0.1", 0);
            var listener = try TcpListener.init(rt, addr);

            try listener.bind(addr);
            try listener.listen(1);

            var stream = try listener.accept();

            var buffer: [20]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            try testing.expect(bytes_read == 5);
            try testing.expectEqualStrings("Hello", buffer[0..bytes_read]);

            stream.close();
            listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10);

            const addr = try Address.parseIp4("127.0.0.1", 8082);
            var stream = try TcpStream.connect(rt, addr);

            const data1 = "Hello";
            const data2 = ", ";
            const data3 = "World!";

            var iovecs = [_]std.posix.iovec_const{
                .{ .base = data1.ptr, .len = data1.len },
                .{ .base = data2.ptr, .len = data2.len },
                .{ .base = data3.ptr, .len = data3.len },
            };

            const bytes_written = try stream.writev(&iovecs);
            try testing.expect(bytes_written == 5);

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

test "TCP: writevAll writes all buffers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime) !void {
            const addr = try Address.parseIp4("127.0.0.1", 0);
            var listener = try TcpListener.init(rt, addr);

            try listener.bind(addr);
            try listener.listen(1);

            var stream = try listener.accept();

            var buffer: [20]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            try testing.expect(bytes_read == 13);
            try testing.expectEqualStrings("Hello, World!", buffer[0..bytes_read]);

            stream.close();
            listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10);

            const addr = try Address.parseIp4("127.0.0.1", 8083);
            var stream = try TcpStream.connect(rt, addr);

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

test "TCP: vectored I/O edge cases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const addr = try Address.parseIp4("127.0.0.1", 0);
    var listener = try TcpListener.init(&runtime, addr);
    var server_stream = try TcpStream.connect(&runtime, addr);

    // Test empty iovecs
    var empty_iovecs_read: [0]std.posix.iovec = .{};
    const empty_read = try server_stream.readv(&empty_iovecs_read);
    try testing.expect(empty_read == 0);

    var empty_iovecs_write: [0]std.posix.iovec_const = .{};
    const empty_write = try server_stream.writev(&empty_iovecs_write);
    try testing.expect(empty_write == 0);

    try server_stream.writevAll(&empty_iovecs_write);

    const empty_readall = try server_stream.readvAll(&empty_iovecs_read);
    try testing.expect(empty_readall == 0);

    // Test zero-length buffers
    const zero_buf: [0]u8 = .{};
    var zero_iovecs = [_]std.posix.iovec{
        .{ .base = @constCast(zero_buf.ptr), .len = 0 },
    };
    const zero_read = try server_stream.readv(&zero_iovecs);
    try testing.expect(zero_read == 0);

    server_stream.close();
    listener.close();
}
