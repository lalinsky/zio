const std = @import("std");
const Backend = @import("backend.zig").Backend;
const Completion = @import("completion.zig").Completion;
const Cancel = @import("completion.zig").Cancel;
const NetClose = @import("completion.zig").NetClose;
const Timer = @import("completion.zig").Timer;
const Queue = @import("queue.zig").Queue;
const Heap = @import("heap.zig").Heap;
const time = @import("time.zig");

pub const RunMode = enum {
    no_wait,
    once,
    until_done,
};

fn timerDeadlineLess(_: void, a: *Timer, b: *Timer) bool {
    return a.deadline_ms < b.deadline_ms;
}

const TimerHeap = Heap(Timer, void, timerDeadlineLess);

pub const LoopState = struct {
    loop: *Loop,

    initialized: bool = false,
    running: bool = false,
    stopped: bool = false,

    active: usize = 0,

    now_ms: u64 = 0,
    timers: TimerHeap = .{ .context = {} },

    submissions: Queue(Completion) = .{},

    pub fn markCompleted(self: *LoopState, completion: *Completion) void {
        if (completion.canceled) |cancel_c| {
            self.markCompleted(cancel_c);
        }
        completion.state = .completed;
        self.active -= 1;
        completion.call(self.loop);
    }

    pub fn markRunning(self: *LoopState, completion: *Completion) void {
        _ = self;
        completion.state = .running;
    }

    pub fn submit(self: *LoopState, completion: *Completion) void {
        completion.state = .adding;
        self.active += 1;
        self.submissions.push(completion);
    }

    pub fn updateNow(self: *LoopState) void {
        self.now_ms = time.now(.monotonic);
    }

    pub fn setTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = self.now_ms +| timer.delay_ms;
        timer.c.state = .running;
        if (was_active) {
            self.timers.remove(timer);
        } else {
            self.active += 1;
        }
        self.timers.insert(timer);
    }

    pub fn clearTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = 0;
        timer.c.state = .completed;
        if (was_active) {
            self.timers.remove(timer);
            self.active -= 1;
        }
    }
};

pub const Loop = struct {
    state: LoopState,
    backend: Backend,

    max_wait_ms: u64 = 60 * std.time.ms_per_s,

    pub fn init(self: *Loop) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
        };

        self.state.updateNow();

        try self.backend.init(std.heap.page_allocator);
        errdefer self.backend.deinit();

        self.state.initialized = true;
    }

    pub fn deinit(self: *Loop) void {
        self.backend.deinit();
    }

    pub fn stop(self: *Loop) void {
        self.state.stopped = true;
    }

    pub fn stopped(self: *const Loop) bool {
        return self.state.stopped;
    }

    pub fn done(self: *const Loop) bool {
        return self.state.stopped or self.state.active == 0;
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        std.debug.assert(self.state.initialized);
        if (self.state.stopped) return;
        switch (mode) {
            .no_wait => try self.tick(false),
            .once => try self.tick(true),
            .until_done => while (!self.done()) try self.tick(true),
        }
    }

    pub fn add(self: *Loop, c: *Completion) void {
        switch (c.op) {
            .timer => {
                const timer = c.cast(Timer);
                self.state.setTimer(timer);
                return;
            },
            else => {
                if (c.op == .cancel) {
                    const cancel = c.cast(Cancel);
                    if (cancel.cancel_c.op == .timer) {
                        const timer = cancel.cancel_c.cast(Timer);
                        self.state.clearTimer(timer);
                        return;
                    }
                }
                self.state.submit(c);
                return;
            },
        }
    }

    fn checkTimers(self: *Loop) u64 {
        self.state.updateNow();
        var timeout_ms: u64 = 0;
        while (self.state.timers.peek()) |timer| {
            if (timer.deadline_ms > self.state.now_ms) {
                timeout_ms = @min(timer.deadline_ms - self.state.now_ms, self.max_wait_ms);
                break;
            }
            self.state.clearTimer(timer);
            timer.c.call(self);
        }
        return timeout_ms;
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.state.stopped) return;

        var timeout_ms: u64 = checkTimers(self);
        if (!wait) {
            timeout_ms = 0;
        }

        try self.backend.tick(&self.state, timeout_ms);

        // Check times again, to trigger the one that set timeout for the tick
        _ = checkTimers(self);
    }
};

test "Loop: empty run(.no_wait)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.no_wait);
}

test "Loop: empty run(.once)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.once);
}

test "Loop: empty run(.until_done)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.until_done);
}

test "Loop: timer iters" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state != .completed) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(11, n_iter);
}

test "Loop: timer iters cancel" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var cancel: Cancel = .init(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state != .completed) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            if (n_iter == 5) {
                loop.add(&cancel.c);
            }
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(6, n_iter);
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    const NetOpen = @import("completion.zig").NetOpen;

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run(.until_done);
    const sock = try open.result;

    // Now close it
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: socket create and bind" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    // Create socket
    const NetOpen = @import("completion.zig").NetOpen;
    const NetBind = @import("completion.zig").NetBind;

    var open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&open.c);
    try loop.run(.until_done);

    const sock = try open.result;

    // Bind to localhost
    const addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    var bind: NetBind = .init(sock, @ptrCast(&addr.any), addr.getOsSockLen());
    loop.add(&bind.c);
    try loop.run(.until_done);

    try bind.result;

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: listen and accept" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    const NetOpen = @import("completion.zig").NetOpen;
    const NetBind = @import("completion.zig").NetBind;
    const NetListen = @import("completion.zig").NetListen;
    const NetAccept = @import("completion.zig").NetAccept;
    const NetConnect = @import("completion.zig").NetConnect;

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    const addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr.any), addr.getOsSockLen());
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Get the actual port that was bound
    var bound_addr: std.posix.sockaddr.in = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try std.posix.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client socket
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

    // Start accept and connect concurrently
    var accept_comp: NetAccept = .init(server_sock, null, null, .{ .nonblocking = true });
    loop.add(&accept_comp.c);

    const connect_addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, port);
    var connect: NetConnect = .init(client_sock, @ptrCast(&connect_addr.any), connect_addr.getOsSockLen());
    loop.add(&connect.c);

    // Run until both complete
    try loop.run(.until_done);

    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Close all sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: send and recv" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    const NetOpen = @import("completion.zig").NetOpen;
    const NetBind = @import("completion.zig").NetBind;
    const NetListen = @import("completion.zig").NetListen;
    const NetAccept = @import("completion.zig").NetAccept;
    const NetConnect = @import("completion.zig").NetConnect;
    const NetSend = @import("completion.zig").NetSend;
    const NetRecv = @import("completion.zig").NetRecv;

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    const addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr.any), addr.getOsSockLen());
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Get the actual port
    var bound_addr: std.posix.sockaddr.in = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try std.posix.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client socket and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

    var accept_comp: NetAccept = .init(server_sock, null, null, .{ .nonblocking = true });
    loop.add(&accept_comp.c);

    const connect_addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, port);
    var connect: NetConnect = .init(client_sock, @ptrCast(&connect_addr.any), connect_addr.getOsSockLen());
    loop.add(&connect.c);

    try loop.run(.until_done);
    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Send data from client
    const msg = "Hello, World!";
    var send: NetSend = .init(client_sock, msg, .{});
    loop.add(&send.c);
    try loop.run(.until_done);
    const sent = try send.result;
    try std.testing.expectEqual(msg.len, sent);

    // Recv data on server
    var recv_buf: [128]u8 = undefined;
    var recv: NetRecv = .init(accepted_sock, &recv_buf, .{});
    loop.add(&recv.c);
    try loop.run(.until_done);
    const recvd = try recv.result;
    try std.testing.expectEqual(msg.len, recvd);
    try std.testing.expectEqualStrings(msg, recv_buf[0..recvd]);

    // Close all sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: cancel net_accept" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    const NetOpen = @import("completion.zig").NetOpen;
    const NetBind = @import("completion.zig").NetBind;
    const NetListen = @import("completion.zig").NetListen;
    const NetAccept = @import("completion.zig").NetAccept;

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    const addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr.any), addr.getOsSockLen());
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Start accept (will block waiting for connection)
    var accept_comp: NetAccept = .init(server_sock, null, null, .{ .nonblocking = true });
    loop.add(&accept_comp.c);

    // Run once to get accept into poll queue
    try loop.run(.once);
    try std.testing.expectEqual(.running, accept_comp.c.state);

    // Cancel the accept
    var cancel: Cancel = .init(&accept_comp.c);
    loop.add(&cancel.c);

    // Run until both complete
    try loop.run(.until_done);

    // Verify both completed
    try std.testing.expectEqual(.completed, accept_comp.c.state);
    try std.testing.expectEqual(.completed, cancel.c.state);

    // Verify accept got canceled error
    try std.testing.expectError(error.Canceled, accept_comp.getResult());

    // Close server socket
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "Loop: cancel net_recv" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    const NetOpen = @import("completion.zig").NetOpen;
    const NetBind = @import("completion.zig").NetBind;
    const NetListen = @import("completion.zig").NetListen;
    const NetAccept = @import("completion.zig").NetAccept;
    const NetConnect = @import("completion.zig").NetConnect;
    const NetRecv = @import("completion.zig").NetRecv;

    // Create and setup server
    var server_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.result;

    const addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 0);
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr.any), addr.getOsSockLen());
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.result;

    var bound_addr: std.posix.sockaddr.in = undefined;
    var bound_addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try std.posix.getsockname(server_sock, @ptrCast(&bound_addr), &bound_addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.result;

    // Create client and connect
    var client_open: NetOpen = .init(.ipv4, .stream, .tcp, .{ .nonblocking = true });
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.result;

    var accept_comp: NetAccept = .init(server_sock, null, null, .{ .nonblocking = true });
    loop.add(&accept_comp.c);

    const connect_addr = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, port);
    var connect: NetConnect = .init(client_sock, @ptrCast(&connect_addr.any), connect_addr.getOsSockLen());
    loop.add(&connect.c);

    try loop.run(.until_done);
    const accepted_sock = try accept_comp.result;
    try connect.result;

    // Start recv (will block waiting for data)
    var recv_buf: [128]u8 = undefined;
    var recv: NetRecv = .init(accepted_sock, &recv_buf, .{});
    loop.add(&recv.c);

    // Run once to get recv into poll queue
    try loop.run(.once);

    // Only test cancellation if recv is actually waiting
    if (recv.c.state == .running) {
        // Cancel the recv
        var cancel: Cancel = .init(&recv.c);
        loop.add(&cancel.c);

        // Run until both complete
        try loop.run(.until_done);

        // Verify both completed
        try std.testing.expectEqual(.completed, recv.c.state);
        try std.testing.expectEqual(.completed, cancel.c.state);

        // Verify recv got canceled error
        try std.testing.expectError(error.Canceled, recv.getResult());
    } else {
        // Recv completed immediately, just finish the loop
        try loop.run(.until_done);
    }

    // Close sockets
    var close_accepted: NetClose = .init(accepted_sock);
    var close_client: NetClose = .init(client_sock);
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_accepted.c);
    loop.add(&close_client.c);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}
