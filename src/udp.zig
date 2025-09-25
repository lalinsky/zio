const std = @import("std");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Waiter = @import("runtime.zig").Waiter;
const Address = @import("address.zig").Address;

pub const UdpRecvResult = struct {
    bytes_read: usize,
    sender_addr: Address,
};

pub const UdpSocket = struct {
    xev_udp: xev.UDP,
    runtime: *Runtime,

    pub fn init(runtime: *Runtime, addr: Address) !UdpSocket {
        return UdpSocket{
            .xev_udp = try xev.UDP.init(addr),
            .runtime = runtime,
        };
    }

    pub fn bind(self: *UdpSocket, addr: Address) !void {
        try self.xev_udp.bind(addr);
    }

    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !UdpRecvResult {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;
        var state: xev.UDP.State = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ReadError!usize = undefined,
            sender_addr: Address = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                state_inner: *xev.UDP.State,
                addr: Address,
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
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_udp.read(
            &self.runtime.loop,
            &completion,
            &state,
            .{ .slice = buffer },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        const bytes_read = try result_data.result;
        return UdpRecvResult{
            .bytes_read = bytes_read,
            .sender_addr = result_data.sender_addr,
        };
    }

    pub fn sendTo(self: *UdpSocket, data: []const u8, addr: Address) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;
        var state: xev.UDP.State = undefined;

        const Result = struct {
            waiter: Waiter,
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
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_udp.write(
            &self.runtime.loop,
            &completion,
            &state,
            addr,
            .{ .slice = data },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
    }

    pub fn close(self: *UdpSocket) !void {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
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
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_udp.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
    }

    pub fn deinit(self: *const UdpSocket) void {
        _ = self;
    }
};

test "UDP: basic send and receive" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const ServerTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            const bind_addr = try Address.parseIp4("127.0.0.1", 0);
            var socket = try UdpSocket.init(rt, bind_addr);
            defer socket.deinit();

            try socket.bind(bind_addr);

            // Get the actual bound port (when using port 0)
            server_port.* = 9999; // For this test, we'll use a fixed port

            // Wait for and echo one message
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.recvFrom(&buffer);

            // Echo back to sender
            const bytes_sent = try socket.sendTo(
                buffer[0..recv_result.bytes_read],
                recv_result.sender_addr
            );
            try testing.expect(bytes_sent == recv_result.bytes_read);

            try socket.close();
        }
    };

    const ClientTask = struct {
        fn run(rt: *Runtime, server_port: *u16) !void {
            rt.sleep(10); // Give server time to bind

            const client_addr = try Address.parseIp4("127.0.0.1", 0);
            var socket = try UdpSocket.init(rt, client_addr);
            defer socket.deinit();

            try socket.bind(client_addr);

            // Send test data
            const test_data = "Hello, UDP!";
            const server_addr = try Address.parseIp4("127.0.0.1", server_port.*);
            const bytes_sent = try socket.sendTo(test_data, server_addr);
            try testing.expect(bytes_sent == test_data.len);

            // Receive echo
            var buffer: [1024]u8 = undefined;
            const recv_result = try socket.recvFrom(&buffer);
            try testing.expectEqualStrings(test_data, buffer[0..recv_result.bytes_read]);

            try socket.close();
        }
    };

    var server_port: u16 = 9999;

    const server_task = try runtime.spawn(ServerTask.run, .{ &runtime, &server_port }, .{});
    defer server_task.deinit();

    const client_task = try runtime.spawn(ClientTask.run, .{ &runtime, &server_port }, .{});
    defer client_task.deinit();

    try runtime.run();

    try server_task.result();
    try client_task.result();
}