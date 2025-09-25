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

    pub fn close(self: *TcpListener) !void {
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

        return result_data.result;
    }

    pub fn deinit(self: *const TcpListener) void {
        _ = self;
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

    pub fn read(self: *TcpStream, buffer: []u8) !usize {
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

    pub fn write(self: *TcpStream, data: []const u8) !usize {
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

    pub fn close(self: *TcpStream) !void {
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

        return result_data.result;
    }

    pub fn deinit(self: *const TcpStream) void {
        _ = self;
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
            defer stream.deinit();

            // Read and echo back
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            const bytes_written = try stream.write(buffer[0..bytes_read]);
            try testing.expect(bytes_written == bytes_read);

            try stream.shutdown();
            try stream.close();
            try listener.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime) !void {
            rt.sleep(10); // Give server time to start

            const addr = try Address.parseIp4("127.0.0.1", 8080);
            var stream = try TcpStream.connect(rt, addr);
            defer stream.deinit();

            // Send test data
            const test_data = "Hello, TCP!";
            const bytes_written = try stream.write(test_data);
            try testing.expect(bytes_written == test_data.len);

            // Read response
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stream.read(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);

            try stream.shutdown();
            try stream.close();
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