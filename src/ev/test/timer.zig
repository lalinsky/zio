const std = @import("std");
const time = @import("../../time.zig");
const Loop = @import("../loop.zig").Loop;
const Timer = @import("../completion.zig").Timer;

test "setTimer and clearTimer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .zero }); // delay_ms will be set by setTimer

    // Test setTimer
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(100) });
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

    var timer: Timer = .init(.{ .duration = .zero });

    // Set a timer with a long delay
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(1000) });
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

    var timer: Timer = .init(.{ .duration = .zero });

    // Set timer with a long delay
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(2000) });
    try std.testing.expectEqual(.running, timer.c.state);

    // Reset it with a short delay
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(10) });
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

    var timer: Timer = .init(.{ .duration = .zero });

    // Set and clear
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(200) });
    loop.clearTimer(&timer);
    try std.testing.expectEqual(.new, timer.c.state);

    // Reuse the same timer
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(10) });
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 5);
    try std.testing.expect(elapsed.toMilliseconds() <= 100);
    std.log.info("clearTimer reuse: expected=10ms, actual={f}", .{elapsed});
}

test "timer with zero duration completes immediately" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .zero });

    var wall_timer = time.Stopwatch.start();
    loop.add(&timer.c);
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() < 50);
    std.log.info("zero duration timer: elapsed={f}", .{elapsed});
}

test "timer with explicit deadline" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create a timer with an absolute deadline 100ms in the future
    const deadline = loop.now().addDuration(.fromMilliseconds(100));
    var timer: Timer = .init(.{ .deadline = deadline });

    var wall_timer = time.Stopwatch.start();
    loop.add(&timer.c);
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 90);
    try std.testing.expect(elapsed.toMilliseconds() <= 250);
    std.log.info("deadline timer: expected=100ms, actual={f}", .{elapsed});
}

test "timer on boot clock fires (duration)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .initClock(.{ .duration = .zero }, .boot);
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(100) });
    try std.testing.expectEqual(.running, timer.c.state);

    var wall_timer = time.Stopwatch.start();
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 90);
    try std.testing.expect(elapsed.toMilliseconds() <= 250);
    std.log.info("boot timer: expected=100ms, actual={f}", .{elapsed});
}

test "timer on real clock fires (absolute deadline)" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Absolute realtime deadline 100ms in the future. The deadline lives in the
    // realtime epoch (ns since 1970), so it must be compared against now(real),
    // not the monotonic clock.
    const deadline = time.Timestamp.now(.real).addDuration(.fromMilliseconds(100));
    var timer: Timer = .initClock(.{ .deadline = deadline }, .real);

    var wall_timer = time.Stopwatch.start();
    loop.add(&timer.c);
    try loop.run(.until_done);
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expect(elapsed.toMilliseconds() >= 90);
    try std.testing.expect(elapsed.toMilliseconds() <= 250);
    std.log.info("real timer: expected=100ms, actual={f}", .{elapsed});
}

test "clearTimer racing a firing timer (cross-thread)" {
    // Regression test: a task migrated to another executor clears its sleep
    // timer on the loop that armed it, racing the owner thread's checkTimers.
    // A fired timer sits in a limbo window (out of the heap, result set, its
    // markCompleted pending outside the timer lock); clearTimer touching it
    // there corrupted the heap, double-decremented active, and cleared the
    // result markCompleted asserts on.
    // The loop is initialized and driven entirely on the runner thread (an
    // io_uring SINGLE_ISSUER ring must be entered by its creating thread);
    // this thread only uses the thread-safe setTimer/clearTimer/wake APIs,
    // exactly like a migrated task's timedWaitClock does.
    var loop: Loop = undefined;
    var ready = std.atomic.Value(bool).init(false);
    var stop = std.atomic.Value(bool).init(false);
    var wake_done = std.atomic.Value(bool).init(false);
    const runner = try std.Thread.spawn(.{}, struct {
        fn run(l: *Loop, r: *std.atomic.Value(bool), s: *std.atomic.Value(bool), w: *std.atomic.Value(bool)) void {
            l.init(.{}) catch @panic("loop init failed");
            defer {
                // Deinit belongs to this thread, but must not race the main
                // thread's final wake(): a stale wake from the last clearTimer
                // can pop run(.once) before that wake() is issued.
                while (!w.load(.acquire)) std.Thread.yield() catch {};
                l.deinit();
            }
            r.store(true, .release);
            while (!s.load(.acquire)) {
                l.run(.once) catch return;
            }
        }
    }.run, .{ &loop, &ready, &stop, &wake_done });
    defer runner.join();
    defer {
        stop.store(true, .release);
        loop.wake();
        wake_done.store(true, .release);
    }
    while (!ready.load(.acquire)) std.Thread.yield() catch {};

    const callback = struct {
        fn cb(_: *Loop, c: *@import("../completion.zig").Completion) void {
            const fired: *std.atomic.Value(bool) = @ptrCast(@alignCast(c.userdata.?));
            fired.store(true, .release);
        }
    }.cb;

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var fired = std.atomic.Value(bool).init(false);
        var timer: Timer = .init(.{ .duration = .zero });
        timer.c.userdata = &fired;
        timer.c.callback = callback;

        // Arm with a tiny, varying delay so the clear below lands at different
        // points relative to the fire: before it, after it, and inside the
        // limbo window.
        loop.setTimer(&timer, .{ .duration = .fromNanoseconds((i % 64) * 1000) });
        if (i % 2 == 0) std.Thread.yield() catch {};
        loop.clearTimer(&timer);

        // If the clear won, the timer is ours again (.new, written by this
        // thread under the lock). Anything else means the fire got there
        // first (or is mid-flight): wait for its callback before the stack
        // timer goes out of scope.
        if (@atomicLoad(@TypeOf(timer.c.state), &timer.c.state, .acquire) != .new) {
            while (!fired.load(.acquire)) std.Thread.yield() catch {};
        }
    }
}
