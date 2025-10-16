const std = @import("std");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Executor = @import("runtime.zig").Executor;
const resumeTask = @import("runtime.zig").resumeTask;
const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;

const TEST_PORT = 45001;

pub const UdpReadResult = struct {
    bytes_read: usize,
    sender_addr: std.net.Address,
};

pub const UdpSocket = struct {
    xev_udp: xev.UDP,
    runtime: *Runtime,

    pub fn init(runtime: *Runtime, addr: std.net.Address) !UdpSocket {
        return UdpSocket{
            .xev_udp = try xev.UDP.init(addr),
            .runtime = runtime,
        };
    }

    pub fn bind(self: *UdpSocket, addr: std.net.Address) !void {
        try self.xev_udp.bind(addr);
    }

    pub fn read(self: *UdpSocket, buffer: []u8) !UdpReadResult {
        const coro = self.runtime.executor.current_coroutine.?;
        var completion: xev.Completion = undefined;
        var state: xev.UDP.State = undefined;

        const Result = struct {
            coro: *Coroutine,
            result: xev.ReadError!usize = undefined,
            sender_addr: std.net.Address = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                state_inner: *xev.UDP.State,
                addr: std.net.Address,
                socket: xev.UDP,
                buffer_inner: xev.ReadBuffer,
                result: xev.ReadError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = state_inner;
                _ = socket;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.sender_addr = addr;
                resumeTask(result_data.coro, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_udp.read(
            &self.runtime.executor.loop,
            &completion,
            &state,
            .{ .slice = buffer },
            Result,
            &result_data,
            Result.callback,
        );

        try self.runtime.executor.waitForXevCompletion(&completion);

        const bytes_read = result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
        return UdpReadResult{
            .bytes_read = bytes_read,
            .sender_addr = result_data.sender_addr,
        };
    }

    pub fn write(self: *UdpSocket, addr: std.net.Address, data: []const u8) !usize {
        const coro = self.runtime.executor.current_coroutine.?;
        var completion: xev.Completion = undefined;
        var state: xev.UDP.State = undefined;

        const Result = struct {
            coro: *Coroutine,
            result: xev.WriteError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                state_inner: *xev.UDP.State,
                socket: xev.UDP,
                buffer_inner: xev.WriteBuffer,
                result: xev.WriteError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = state_inner;
                _ = socket;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                resumeTask(result_data.coro, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_udp.write(
            &self.runtime.executor.loop,
            &completion,
            &state,
            addr,
            .{ .slice = data },
            Result,
            &result_data,
            Result.callback,
        );

        try self.runtime.executor.waitForXevCompletion(&completion);

        return result_data.result catch |err| {
            if (err == error.Canceled) return error.Unexpected;
            return err;
        };
    }

    pub fn close(self: *UdpSocket) void {
        // Shield close operation from cancellation
        self.runtime.beginShield();
        defer self.runtime.endShield();

        const coro = self.runtime.executor.current_coroutine.?;
        var completion: xev.Completion = undefined;

        const Result = struct {
            coro: *Coroutine,
            result: xev.CloseError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                socket: xev.UDP,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = socket;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                resumeTask(result_data.coro, .local);

                return .disarm;
            }
        };

        var result_data: Result = .{ .coro = coro };

        self.xev_udp.close(
            &self.runtime.executor.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        // Shield ensures this never returns error.Canceled
        self.runtime.executor.waitForXevCompletion(&completion) catch unreachable;

        // Ignore close errors, following Zig std lib pattern
        _ = result_data.result catch {};
    }
};

test "UDP: basic send and receive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
            var socket = try UdpSocket.init(rt, bind_addr);
            defer socket.close();

            try socket.bind(bind_addr);

            // Set the server port for the client to connect to
            server_port.* = TEST_PORT;

            // Wait for and echo one message
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.read(&buffer);

            // Echo back to sender
            const bytes_sent = try socket.write(recv_result.sender_addr, buffer[0..recv_result.bytes_read]);
            try testing.expectEqual(recv_result.bytes_read, bytes_sent);
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            rt.sleep(10); // Give server time to bind

            const client_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            var socket = try UdpSocket.init(rt, client_addr);
            defer socket.close();

            try socket.bind(client_addr);

            // Send test data
            const test_data = "Hello, UDP!";
            const server_addr = try std.net.Address.parseIp4("127.0.0.1", server_port.*);
            const bytes_sent = try socket.write(server_addr, test_data);
            try testing.expectEqual(test_data.len, bytes_sent);

            // Receive echo
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.read(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..recv_result.bytes_read]);
        }
    };

    var server_port: u16 = TEST_PORT;

    var server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_port }, .{});
    defer server_task.deinit();

    var client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_port }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.join();
    try client_task.join();
}
