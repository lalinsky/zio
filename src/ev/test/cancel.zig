const std = @import("std");
const ev = @import("../root.zig");
const Loop = ev.Loop;
const Timer = ev.Timer;
const Cancel = ev.Cancel;
const Async = ev.Async;
const Work = ev.Work;
const ThreadPool = ev.ThreadPool;
const NetOpen = ev.NetOpen;
const NetBind = ev.NetBind;
const NetListen = ev.NetListen;
const NetAccept = ev.NetAccept;
const NetRecv = ev.NetRecv;
const NetSend = ev.NetSend;
const NetClose = ev.NetClose;
const NetConnect = ev.NetConnect;
const net = ev.system.net;

test "cancel: timer with Cancel completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 100;
    var timer: Timer = .init(timeout_ms);
    loop.add(&timer.c);

    var cancel: Cancel = .init(&timer.c);
    loop.add(&cancel.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectEqual(.dead, cancel.c.state);
    try std.testing.expectError(error.Canceled, timer.getResult());
    try std.testing.expect(elapsed_ms < 50);
}

test "cancel: timer with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 100;
    var timer: Timer = .init(timeout_ms);
    loop.add(&timer.c);

    try loop.cancel(&timer.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectError(error.Canceled, timer.getResult());
    try std.testing.expect(elapsed_ms < 50);
}

test "cancel: double cancel returns AlreadyCanceled" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    loop.add(&timer.c);

    // First cancel should succeed
    try loop.cancel(&timer.c);

    // Second cancel should fail
    try std.testing.expectError(error.AlreadyCanceled, loop.cancel(&timer.c));

    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: cancel with Cancel completion then loop.cancel() returns AlreadyCanceled" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    loop.add(&timer.c);

    // Cancel with Cancel completion
    var cancel: Cancel = .init(&timer.c);
    loop.add(&cancel.c);

    // Try to cancel again with loop.cancel()
    try std.testing.expectError(error.AlreadyCanceled, loop.cancel(&timer.c));

    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: cancel completed operation returns AlreadyCompleted" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(1);
    loop.add(&timer.c);

    // Wait for timer to complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, timer.c.state);
    try timer.getResult();

    // Try to cancel after completion
    try std.testing.expectError(error.AlreadyCompleted, loop.cancel(&timer.c));
}

test "cancel: cancel not-started operation returns NotStarted" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    // Don't add to loop

    // Try to cancel before adding
    try std.testing.expectError(error.NotStarted, loop.cancel(&timer.c));
}

test "cancel: Cancel completion on not-started target" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    // Don't add timer yet

    // Add Cancel for not-yet-added target
    var cancel: Cancel = .init(&timer.c);
    loop.add(&cancel.c);

    // Now add the timer - it should be immediately canceled
    loop.add(&timer.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectEqual(.dead, cancel.c.state);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: async handle with Cancel completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    var cancel: Cancel = .init(&async_handle.c);
    loop.add(&cancel.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, async_handle.c.state);
    try std.testing.expectEqual(.dead, cancel.c.state);
    try std.testing.expectError(error.Canceled, async_handle.getResult());
}

test "cancel: async handle with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    try loop.cancel(&async_handle.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, async_handle.c.state);
    try std.testing.expectError(error.Canceled, async_handle.getResult());
}

test "cancel: net_accept with Cancel completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.getResult();

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.getResult();

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.getResult();

    // Start accept
    var accept_comp: NetAccept = .init(server_sock, null, null);
    loop.add(&accept_comp.c);

    try loop.run(.no_wait);
    try std.testing.expectEqual(.running, accept_comp.c.state);

    // Cancel the accept
    var cancel: Cancel = .init(&accept_comp.c);
    loop.add(&cancel.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, accept_comp.c.state);
    try std.testing.expectEqual(.dead, cancel.c.state);
    try std.testing.expectError(error.Canceled, accept_comp.getResult());

    // Close server socket
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "cancel: net_accept with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create and bind server socket
    var server_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.getResult();

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.getResult();

    // Listen
    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.getResult();

    // Start accept
    var accept_comp: NetAccept = .init(server_sock, null, null);
    loop.add(&accept_comp.c);

    try loop.run(.no_wait);
    try std.testing.expectEqual(.running, accept_comp.c.state);

    // Cancel with loop.cancel()
    try loop.cancel(&accept_comp.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, accept_comp.c.state);
    try std.testing.expectError(error.Canceled, accept_comp.getResult());

    // Close server socket
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_server.c);
    try loop.run(.until_done);
}

test "cancel: net_recv with Cancel completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create socket pair
    var server_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.getResult();

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.getResult();

    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.getResult();

    // Get bound address
    try net.getsockname(server_sock, @ptrCast(&addr), &addr_len);

    // Connect client
    var client_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.getResult();

    var client_conn = ev.NetConnect.init(client_sock, @ptrCast(&addr), addr_len);
    loop.add(&client_conn.c);

    // Accept connection
    var accept: NetAccept = .init(server_sock, null, null);
    loop.add(&accept.c);

    try loop.run(.until_done);
    try client_conn.getResult();
    const accepted_sock = try accept.getResult();

    // Start recv on accepted socket
    var buf: [128]u8 = undefined;
    var read_iov: [1]ev.system.iovec = undefined;
    var recv: NetRecv = .init(accepted_sock, .fromSlice(&buf, &read_iov), .{});
    loop.add(&recv.c);

    try loop.run(.no_wait);
    try std.testing.expectEqual(.running, recv.c.state);

    // Cancel the recv
    var cancel: Cancel = .init(&recv.c);
    loop.add(&cancel.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, recv.c.state);
    try std.testing.expectEqual(.dead, cancel.c.state);
    try std.testing.expectError(error.Canceled, recv.getResult());

    // Close sockets
    var close1: NetClose = .init(client_sock);
    var close2: NetClose = .init(accepted_sock);
    var close3: NetClose = .init(server_sock);
    loop.add(&close1.c);
    loop.add(&close2.c);
    loop.add(&close3.c);
    try loop.run(.until_done);
}

test "cancel: net_recv with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create socket pair
    var server_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&server_open.c);
    try loop.run(.until_done);
    const server_sock = try server_open.getResult();

    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var server_bind: NetBind = .init(server_sock, @ptrCast(&addr), &addr_len);
    loop.add(&server_bind.c);
    try loop.run(.until_done);
    try server_bind.getResult();

    var server_listen: NetListen = .init(server_sock, 1);
    loop.add(&server_listen.c);
    try loop.run(.until_done);
    try server_listen.getResult();

    // Get bound address
    try net.getsockname(server_sock, @ptrCast(&addr), &addr_len);

    // Connect client
    var client_open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&client_open.c);
    try loop.run(.until_done);
    const client_sock = try client_open.getResult();

    var client_conn = ev.NetConnect.init(client_sock, @ptrCast(&addr), addr_len);
    loop.add(&client_conn.c);

    // Accept connection
    var accept: NetAccept = .init(server_sock, null, null);
    loop.add(&accept.c);

    try loop.run(.until_done);
    try client_conn.getResult();
    const accepted_sock = try accept.getResult();

    // Start recv on accepted socket
    var buf: [128]u8 = undefined;
    var read_iov: [1]ev.system.iovec = undefined;
    var recv: NetRecv = .init(accepted_sock, .fromSlice(&buf, &read_iov), .{});
    loop.add(&recv.c);

    try loop.run(.no_wait);
    try std.testing.expectEqual(.running, recv.c.state);

    // Cancel with loop.cancel()
    try loop.cancel(&recv.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, recv.c.state);
    try std.testing.expectError(error.Canceled, recv.getResult());

    // Close sockets
    var close1: NetClose = .init(client_sock);
    var close2: NetClose = .init(accepted_sock);
    var close3: NetClose = .init(server_sock);
    loop.add(&close1.c);
    loop.add(&close2.c);
    loop.add(&close3.c);
    try loop.run(.until_done);
}

test "cancel: canceled flag is set on completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    loop.add(&timer.c);

    try std.testing.expect(!timer.c.canceled);

    try loop.cancel(&timer.c);

    try std.testing.expect(timer.c.canceled);
    try std.testing.expect(timer.c.canceled_by == null);

    try loop.run(.until_done);
}

test "cancel: canceled_by is set with Cancel completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(100);
    loop.add(&timer.c);

    var cancel: Cancel = .init(&timer.c);

    try std.testing.expect(!timer.c.canceled);
    try std.testing.expect(timer.c.canceled_by == null);

    loop.add(&cancel.c);

    try std.testing.expect(timer.c.canceled);
    try std.testing.expect(timer.c.canceled_by == &cancel);

    try loop.run(.until_done);
}

test "cancel: callback is invoked on canceled operation" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Ctx = struct {
        called: bool = false,
        was_canceled: bool = false,

        fn callback(l: *Loop, c: *ev.Completion) void {
            _ = l;
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.called = true;
            self.was_canceled = c.canceled;
        }
    };

    var ctx: Ctx = .{};
    var timer: Timer = .init(100);
    timer.c.userdata = &ctx;
    timer.c.callback = Ctx.callback;
    loop.add(&timer.c);

    try loop.cancel(&timer.c);
    try loop.run(.until_done);

    try std.testing.expect(ctx.called);
    try std.testing.expect(ctx.was_canceled);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: race - operation completes before cancel" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Use very short timer to simulate race
    var timer: Timer = .init(1);
    loop.add(&timer.c);

    // Wait for it to complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, timer.c.state);
    try timer.getResult(); // Should succeed

    // Now try to cancel - should get AlreadyCompleted
    try std.testing.expectError(error.AlreadyCompleted, loop.cancel(&timer.c));
}

test "cancel: multiple timers, cancel one" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(100);
    var timer2: Timer = .init(200);
    var timer3: Timer = .init(300);

    loop.add(&timer1.c);
    loop.add(&timer2.c);
    loop.add(&timer3.c);

    // Cancel middle timer
    try loop.cancel(&timer2.c);

    try loop.run(.until_done);

    // timer1 and timer3 should complete normally
    try timer1.getResult();
    try timer3.getResult();

    // timer2 should be canceled
    try std.testing.expectError(error.Canceled, timer2.getResult());
}

test "cancel: work after completion returns AlreadyCompleted" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    const TestFn = struct {
        called: bool = false,
        pub fn main(work: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called = true;
        }
    };

    var test_fn: TestFn = .{};
    var work = Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    // Wait for work to complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, work.c.state);
    try work.getResult();
    try std.testing.expect(test_fn.called);

    // Try to cancel after completion
    try std.testing.expectError(error.AlreadyCompleted, loop.cancel(&work.c));
}

test "cancel: work before run" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    const TestFn = struct {
        called: bool = false,
        pub fn main(work: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called = true;
        }
    };

    var test_fn: TestFn = .{};
    var work = Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    // Cancel before running
    try loop.cancel(&work.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, work.c.state);
    try std.testing.expectError(error.Canceled, work.getResult());
    try std.testing.expect(!test_fn.called);
}

test "cancel: work double cancel returns AlreadyCanceled" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .thread_pool = &thread_pool });
    defer loop.deinit();

    const TestFn = struct {
        called: bool = false,
        pub fn main(work: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called = true;
        }
    };

    var test_fn: TestFn = .{};
    var work = Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    // First cancel should succeed
    try loop.cancel(&work.c);

    // Second cancel should fail
    try std.testing.expectError(error.AlreadyCanceled, loop.cancel(&work.c));

    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, work.getResult());
    try std.testing.expect(!test_fn.called);
}
