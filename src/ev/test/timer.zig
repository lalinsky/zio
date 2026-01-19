const std = @import("std");
const time = @import("../../time.zig");
const Loop = @import("../loop.zig").Loop;
const Timer = @import("../completion.zig").Timer;

test "setTimer and clearTimer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.zero); // delay_ms will be set by setTimer

    // Test setTimer
    loop.setTimer(&timer, .fromMilliseconds(100));
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 90);
    try std.testing.expect(elapsed.toMilliseconds() <= 250);
    std.log.info("setTimer: expected=100ms, actual={f}", .{elapsed});
}

test "clearTimer before expiration" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.zero);

    // Set a timer with a long delay
    loop.setTimer(&timer, .fromMilliseconds(1000));
    try std.testing.expectEqual(.running, timer.c.state);

    // Clear it immediately
    loop.clearTimer(&timer);
    try std.testing.expectEqual(.new, timer.c.state);

    // Run the loop - should complete immediately with no active timers
    var wall_timer = time.Stopwatch.start();
    try loop.run(.once);
    const elapsed = wall_timer.read();

    // Should be very fast since there's nothing to wait for
    try std.testing.expect(elapsed.toMilliseconds() < 200);
    try std.testing.expect(loop.done());
    std.log.info("clearTimer: elapsed={f}", .{elapsed});
}

test "setTimer multiple times" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.zero);

    // Set timer with a long delay
    loop.setTimer(&timer, .fromMilliseconds(2000));
    try std.testing.expectEqual(.running, timer.c.state);

    // Reset it with a short delay
    loop.setTimer(&timer, .fromMilliseconds(10));
    try std.testing.expectEqual(.running, timer.c.state);

    // Should complete after ~10ms, not 2000ms
    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 5);
    try std.testing.expect(elapsed.toMilliseconds() <= 100);
    std.log.info("setTimer multiple: expected=10ms, actual={f}", .{elapsed});
}

test "clearTimer and reuse timer" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.zero);

    // Set and clear
    loop.setTimer(&timer, .fromMilliseconds(200));
    loop.clearTimer(&timer);
    try std.testing.expectEqual(.new, timer.c.state);

    // Reuse the same timer
    loop.setTimer(&timer, .fromMilliseconds(10));
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 5);
    try std.testing.expect(elapsed.toMilliseconds() <= 100);
    std.log.info("clearTimer reuse: expected=10ms, actual={f}", .{elapsed});
}
