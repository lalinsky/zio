const std = @import("std");
const Loop = @import("loop.zig").Loop;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const NetClose = @import("completion.zig").NetClose;
const NetOpen = @import("completion.zig").NetOpen;
const NetBind = @import("completion.zig").NetBind;
const net = @import("os/net.zig");
const time = @import("os/time.zig");

test {
    _ = @import("test/thread_pool.zig");
    _ = @import("test/stream_server.zig");
    _ = @import("test/dgram_server.zig");
    _ = @import("test/fs.zig");
    _ = @import("test/timer.zig");
    _ = @import("test/cancel.zig");
}

test "Loop: empty run(.no_wait)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.no_wait);
}

test "Loop: empty run(.once)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.once);
}

test "Loop: empty run(.until_done)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    try loop.run(.until_done);
}

test "Loop: timer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const timeout_ms = 50;
    var timer: Timer = .init(timeout_ms);
    loop.add(&timer.c);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed_ms >= timeout_ms - 5);
    try std.testing.expect(elapsed_ms <= timeout_ms + 100);
    std.log.info("timer: expected={}ms, actual={}ms", .{ timeout_ms, elapsed_ms });
}

test "Loop: close" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a socket first
    var open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&open.c);
    try loop.run(.until_done);
    const sock = try open.c.getResult(.net_open);

    // Now close it
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: socket create and bind" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create socket
    var open: NetOpen = .init(.ipv4, .stream, .{});
    loop.add(&open.c);
    try loop.run(.until_done);

    const sock = try open.c.getResult(.net_open);

    // Bind to localhost
    var addr = net.sockaddr.in{
        .family = net.AF.INET,
        .port = 0,
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };
    var addr_len: net.socklen_t = @sizeOf(@TypeOf(addr));
    var bind: NetBind = .init(sock, @ptrCast(&addr), &addr_len);
    loop.add(&bind.c);
    try loop.run(.until_done);

    try bind.c.getResult(.net_bind);

    // Close socket
    var close: NetClose = .init(sock);
    loop.add(&close.c);
    try loop.run(.until_done);
}

test "Loop: async notification - same thread" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    // Notify immediately in same thread
    async_handle.notify();

    // Run loop - async should complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
    try async_handle.c.getResult(.async);
}

test "Loop: async notification - cross-thread" {
    const Context = struct {
        async_handle: *Async,
    };

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    // Create thread that will notify after a delay
    var ctx = Context{ .async_handle = &async_handle };
    const thread = try std.Thread.spawn(.{}, struct {
        fn notifyThread(c: *Context) void {
            time.sleep(10);
            c.async_handle.notify();
        }
    }.notifyThread, .{&ctx});

    // Run loop - should block until notified
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
    try async_handle.c.getResult(.async);

    thread.join();
}

test "Loop: async notification - multiple handles" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async1: Async = .init();
    var async2: Async = .init();
    var async3: Async = .init();

    loop.add(&async1.c);
    loop.add(&async2.c);
    loop.add(&async3.c);

    // Notify all three
    async1.notify();
    async2.notify();
    async3.notify();

    // Run loop - all should complete
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async1.c.state);
    try std.testing.expectEqual(.dead, async2.c.state);
    try std.testing.expectEqual(.dead, async3.c.state);
}

test "Loop: async notification - re-arm" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();

    // First notification cycle
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);

    // Re-arm for second notification
    async_handle = .init();
    loop.add(&async_handle.c);
    async_handle.notify();
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);
}

test "Loop: wakeFromAnywhere - cross-thread" {
    const Context = struct {
        loop: *Loop,
    };

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var async_handle: Async = .init();
    loop.add(&async_handle.c);

    // Create thread that will use wakeFromAnywhere after a delay
    var ctx = Context{ .loop = &loop };
    const thread = try std.Thread.spawn(.{}, struct {
        fn notifyThread(c: *Context) void {
            time.sleep(10);
            // Use wakeFromAnywhere instead of wake
            c.loop.wakeFromAnywhere();
        }
    }.notifyThread, .{&ctx});

    // Manually notify the async handle from main thread
    async_handle.notify();

    // Run loop - should wake up due to wakeFromAnywhere
    try loop.run(.until_done);
    try std.testing.expectEqual(.dead, async_handle.c.state);

    thread.join();
}
