const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const Timer = @import("../completion.zig").Timer;

test "setTimer and clearTimer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(0); // delay_ms will be set by setTimer

    // Test setTimer
    loop.setTimer(&timer, 100);
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.completed, timer.c.state);
    try std.testing.expect(elapsed_ms >= 90);
    try std.testing.expect(elapsed_ms <= 250);
    std.log.info("setTimer: expected=100ms, actual={}ms", .{elapsed_ms});
}

test "clearTimer before expiration" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(0);

    // Set a timer with a long delay
    loop.setTimer(&timer, 1000);
    try std.testing.expectEqual(.running, timer.c.state);

    // Clear it immediately
    loop.clearTimer(&timer);
    try std.testing.expectEqual(.new, timer.c.state);

    // Run the loop - should complete immediately with no active timers
    var wall_timer = try std.time.Timer.start();
    try loop.run(.once);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Should be very fast since there's nothing to wait for
    try std.testing.expect(elapsed_ms < 200);
    try std.testing.expect(loop.done());
    std.log.info("clearTimer: elapsed={}ms", .{elapsed_ms});
}

test "setTimer multiple times" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(0);

    // Set timer with a long delay
    loop.setTimer(&timer, 2000);
    try std.testing.expectEqual(.running, timer.c.state);

    // Reset it with a short delay
    loop.setTimer(&timer, 100);
    try std.testing.expectEqual(.running, timer.c.state);

    // Should complete after ~100ms, not 2000ms
    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.completed, timer.c.state);
    try std.testing.expect(elapsed_ms >= 90);
    try std.testing.expect(elapsed_ms <= 300);
    std.log.info("setTimer multiple: expected=100ms, actual={}ms", .{elapsed_ms});
}

test "clearTimer and reuse timer" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(0);

    // Set and clear
    loop.setTimer(&timer, 200);
    loop.clearTimer(&timer);
    try std.testing.expectEqual(.new, timer.c.state);

    // Reuse the same timer
    loop.setTimer(&timer, 100);
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = try std.time.Timer.start();
    try loop.run(.until_done);
    const elapsed_ns = wall_timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    try std.testing.expectEqual(.completed, timer.c.state);
    try std.testing.expect(elapsed_ms >= 90);
    try std.testing.expect(elapsed_ms <= 250);
    std.log.info("clearTimer reuse: expected=100ms, actual={}ms", .{elapsed_ms});
}
