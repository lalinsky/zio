const std = @import("std");
const ev = @import("../root.zig");
const os = @import("../../os/root.zig");
const Loop = ev.Loop;
const Timer = ev.Timer;
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
const net = os.net;

test "cancel: timer with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.fromMilliseconds(100));
    loop.add(&timer.c);

    loop.cancel(&timer.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectError(error.Canceled, timer.getResult());
    try std.testing.expect(elapsed_ms < 50);
}

test "cancel: double cancel is idempotent" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.fromMilliseconds(100));
    loop.add(&timer.c);

    // Both cancels succeed (idempotent)
    loop.cancel(&timer.c);
    loop.cancel(&timer.c);

    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: cancel completed operation is no-op" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.fromMilliseconds(1));
    loop.add(&timer.c);

    // Wait for timer to complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, timer.c.state);
    try timer.getResult();

    // Cancel after completion is no-op
    loop.cancel(&timer.c);
}

test "cancel: cancel not-started operation marks for cancel on add" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.fromMilliseconds(100));
    // Don't add to loop yet

    // Cancel before adding - marks the completion
    loop.cancel(&timer.c);

    // Now add - should immediately fail with Canceled
    loop.add(&timer.c);
    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, timer.getResult());
}

test "cancel: async handle with loop.cancel()" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    loop.cancel(&async_handle.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, async_handle.c.state);
    try std.testing.expectError(error.Canceled, async_handle.getResult());
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
    loop.cancel(&accept_comp.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, accept_comp.c.state);
    try std.testing.expectError(error.Canceled, accept_comp.getResult());

    // Close server socket
    var close_server: NetClose = .init(server_sock);
    loop.add(&close_server.c);
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
    var read_iov: [1]os.iovec = undefined;
    var recv: NetRecv = .init(accepted_sock, .fromSlice(&buf, &read_iov), .{});
    loop.add(&recv.c);

    try loop.run(.no_wait);
    try std.testing.expectEqual(.running, recv.c.state);

    // Cancel with loop.cancel()
    loop.cancel(&recv.c);

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

test "cancel: cancel.requested flag is set on completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.fromMilliseconds(100));
    loop.add(&timer.c);

    try std.testing.expect(!timer.c.cancel.requested.load(.acquire));

    loop.cancel(&timer.c);

    try std.testing.expect(timer.c.cancel.requested.load(.acquire));

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
            self.was_canceled = c.cancel.requested.load(.acquire);
        }
    };

    var ctx: Ctx = .{};
    var timer: Timer = .init(.fromMilliseconds(100));
    timer.c.userdata = &ctx;
    timer.c.callback = Ctx.callback;
    loop.add(&timer.c);

    loop.cancel(&timer.c);
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
    var timer: Timer = .init(.fromMilliseconds(1));
    loop.add(&timer.c);

    // Wait for it to complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, timer.c.state);
    try timer.getResult(); // Should succeed

    // Cancel after completion is no-op
    loop.cancel(&timer.c);
}

test "cancel: multiple timers, cancel one" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(.fromMilliseconds(100));
    var timer2: Timer = .init(.fromMilliseconds(200));
    var timer3: Timer = .init(.fromMilliseconds(300));

    loop.add(&timer1.c);
    loop.add(&timer2.c);
    loop.add(&timer3.c);

    // Cancel middle timer
    loop.cancel(&timer2.c);

    try loop.run(.until_done);

    // timer1 and timer3 should complete normally
    try timer1.getResult();
    try timer3.getResult();

    // timer2 should be canceled
    try std.testing.expectError(error.Canceled, timer2.getResult());
}

test "cancel: work after completion is no-op" {
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

    // Cancel after completion is no-op
    loop.cancel(&work.c);
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
    loop.cancel(&work.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, work.c.state);
    try std.testing.expectError(error.Canceled, work.getResult());
    try std.testing.expect(!test_fn.called);
}

test "cancel: work double cancel is idempotent" {
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

    // Both cancels succeed (idempotent)
    loop.cancel(&work.c);
    loop.cancel(&work.c);

    try loop.run(.until_done);
    try std.testing.expectError(error.Canceled, work.getResult());
    try std.testing.expect(!test_fn.called);
}

test "cancel: queued work via thread pool cancel" {
    // Test that ThreadPool.cancel() correctly calls completion_fn when
    // it removes work from the queue (work never started running).
    var started_event: std.Thread.ResetEvent = .{};
    var blocker_event: std.Thread.ResetEvent = .{};

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();
    defer blocker_event.set(); // Ensure thread unblocks before deinit

    const BlockingFn = struct {
        started: *std.Thread.ResetEvent,
        blocker: *std.Thread.ResetEvent,

        pub fn work(w: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(w.userdata));
            self.started.set();
            self.blocker.wait();
        }
    };

    const QueuedFn = struct {
        work_called: bool = false,
        completion_called: bool = false,

        pub fn work(w: *Work) void {
            var self: *@This() = @ptrCast(@alignCast(w.userdata));
            self.work_called = true;
        }

        pub fn completion(ctx: ?*anyopaque, _: *Work) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.completion_called = true;
        }
    };

    var blocking_ctx: BlockingFn = .{ .started = &started_event, .blocker = &blocker_event };
    var queued_ctx: QueuedFn = .{};

    var blocking_work = Work.init(&BlockingFn.work, @ptrCast(&blocking_ctx));

    var queued_work = Work.init(&QueuedFn.work, @ptrCast(&queued_ctx));
    queued_work.completion_fn = &QueuedFn.completion;
    queued_work.completion_context = @ptrCast(&queued_ctx);

    // Submit blocking work first - it will occupy the only thread
    thread_pool.submit(&blocking_work);

    // Wait for blocking work to start running
    started_event.wait();

    // Submit second work - it will be queued since thread is busy
    thread_pool.submit(&queued_work);

    // Cancel the queued work - this tests ThreadPool.cancel() calling completion_fn
    thread_pool.cancel(&queued_work);

    // Verify completion_fn was called by cancel
    try std.testing.expect(queued_ctx.completion_called);
    try std.testing.expect(!queued_ctx.work_called);
    try std.testing.expectError(error.Canceled, queued_work.getResult());
}

test "cancel: cross-thread cancellation" {
    // Test cancelling an operation from a different thread/loop
    var loop1: Loop = undefined;
    try loop1.init(.{});
    defer loop1.deinit();

    // Create a timer on loop1 that will be cancelled from another thread
    var timer: Timer = .init(.fromMilliseconds(5000)); // Long timeout
    var completed = std.atomic.Value(bool).init(false);
    timer.c.userdata = &completed;
    timer.c.callback = struct {
        fn callback(_: *Loop, c: *ev.Completion) void {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(c.userdata.?));
            flag.store(true, .release);
        }
    }.callback;
    loop1.add(&timer.c);

    // Spawn thread that will cancel from its own loop
    const cancel_thread = std.Thread.spawn(.{}, struct {
        fn run(target_timer: *Timer) void {
            // Init loop on this thread
            var loop2: Loop = undefined;
            loop2.init(.{}) catch return;
            defer loop2.deinit();

            // Cancel from a different loop (cross-thread)
            loop2.cancel(&target_timer.c);
        }
    }.run, .{&timer}) catch unreachable;

    // Run loop1 until completion (should be cancelled quickly)
    var wall_timer = try std.time.Timer.start();
    while (!completed.load(.acquire)) {
        try loop1.run(.once);
        if (wall_timer.read() > 1 * std.time.ns_per_s) {
            return error.TestTimeout;
        }
    }

    cancel_thread.join();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectError(error.Canceled, timer.getResult());
}
