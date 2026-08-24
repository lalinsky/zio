const std = @import("std");
const builtin = @import("builtin");
const time = @import("../../time.zig");
const Loop = @import("../loop.zig").Loop;
const Timer = @import("../completion.zig").Timer;
const FileReadStreaming = @import("../completion.zig").FileReadStreaming;
const ReadBuf = @import("../buf.zig").ReadBuf;
const fs = @import("../../os/fs.zig");
const posix = @import("../../os/posix.zig");

test "setTimer and clearTimer basic" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .zero }); // delay_ms will be set by setTimer

    // Test setTimer
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(100) });
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    var wall_timer = time.Stopwatch.start();
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    // Clear it immediately
    try std.testing.expect(loop.clearTimer(&timer));
    try std.testing.expectEqual(.new, timer.c.loadState().phase);

    // Run the loop - should complete immediately with no active timers
    var wall_timer = time.Stopwatch.start();
    try loop.poll(.max);
    const elapsed = wall_timer.read();

    // Should be very fast since there's nothing to wait for
    try std.testing.expect(elapsed.toMilliseconds() < 200);
    try std.testing.expect(loop.done());
    std.log.info("clearTimer: elapsed={f}", .{elapsed});
}

test "clearTimer reports a callback it could not stop" {
    // A timer whose callback has not run yet is not the caller's to reclaim:
    // the clear must report that, so the caller keeps the timer (and whatever
    // its userdata points at) alive until the callback is done with them.
    // `do_not_call_callbacks` holds a finished completion in the dispatch queue
    // and reproduces that window without a second thread.
    var loop: Loop = undefined;
    try loop.init(.{ .do_not_call_callbacks = true });
    defer loop.deinit();

    var fired = false;
    var timer: Timer = .init(.{ .duration = .zero });
    timer.c.userdata = &fired;
    timer.c.callback = struct {
        fn cb(_: *Loop, c: *@import("../completion.zig").Completion) void {
            const flag: *bool = @ptrCast(@alignCast(c.userdata.?));
            flag.* = true;
        }
    }.cb;

    loop.setTimer(&timer, .{ .duration = .zero });
    try loop.poll(.max);
    try std.testing.expect(!fired);

    try std.testing.expect(!loop.clearTimer(&timer));

    const dispatched = loop.nextDispatched().?;
    try std.testing.expectEqual(&timer.c, dispatched);
    dispatched.call(&loop);
    try std.testing.expect(fired);

    // Still not reclaimable afterwards: the callback ran, so the clear has
    // nothing to hand back and must not claim it does.
    try std.testing.expect(!loop.clearTimer(&timer));
}

test "setTimer multiple times" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .zero });

    // Set timer with a long delay
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(2000) });
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    // Reset it with a short delay
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(10) });
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    // Should complete after ~10ms, not 2000ms
    var wall_timer = time.Stopwatch.start();
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    try std.testing.expect(loop.clearTimer(&timer));
    try std.testing.expectEqual(.new, timer.c.loadState().phase);

    // Reuse the same timer
    loop.setTimer(&timer, .{ .duration = .fromMilliseconds(10) });
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    var wall_timer = time.Stopwatch.start();
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    try std.testing.expectEqual(.running, timer.c.loadState().phase);

    var wall_timer = time.Stopwatch.start();
    try loop.run();
    const elapsed = wall_timer.read();

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
    const start = time.Timestamp.now(.real);
    const deadline = start.addDuration(.fromMilliseconds(100));
    var timer: Timer = .initClock(.{ .deadline = deadline }, .real);

    loop.add(&timer.c);
    try loop.run();

    // Measure elapsed on the realtime clock too, not a monotonic stopwatch: a
    // realtime timer fires when the wall clock crosses the deadline, and the
    // kernel re-evaluates it across clock steps. CI machines (macOS VMs
    // especially) step the wall clock while tests run, which moves the firing
    // moment in monotonic terms and made this test flaky; in the timer's own
    // clock domain a step moves "now" and the crossing together, so the
    // elapsed time stays ~100ms plus firing latency either way.
    const elapsed = start.durationTo(time.Timestamp.now(.real));

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
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
                // can pop poll(.max) before that wake() is issued.
                while (!w.load(.acquire)) std.Thread.yield() catch {};
                l.deinit();
            }
            r.store(true, .release);
            while (!s.load(.acquire)) {
                l.poll(.max) catch return;
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

        // A clear that won hands the timer back and rules out the callback.
        // Anything else means the fire got there first (or is mid-flight):
        // wait for its callback before the stack timer goes out of scope.
        if (loop.clearTimer(&timer)) {
            try std.testing.expectEqual(.new, timer.c.loadState().phase);
            try std.testing.expect(!fired.load(.acquire));
        } else {
            while (!fired.load(.acquire)) std.Thread.yield() catch {};
        }
    }
}

test "duration timer armed after a long idle poll is not backdated" {
    // Regression: `Loop.add` arms `.duration` timers via `armTimer`, which
    // computed the deadline from the scan-cached `now`. The cache refreshes
    // in `checkTimers` at the top of `poll`, and again after the backend
    // poll only when it TIMED OUT. So when the backend poll slept a long
    // time and woke on I/O, everything that ran before the next `poll` —
    // completion callbacks, and the runtime's task batch — saw a cache
    // stale by the whole sleep. A duration timer armed there was backdated:
    // a 500ms timer armed after a ~1.2s sleep had a deadline already in the
    // past and fired on the next scan instead of 500ms later.
    //
    // The wake must be an I/O completion delivered by the poll that slept
    // (an async notify wakes one poll and completes on the next, whose
    // `checkTimers` freshens the cache first — that shape cannot reproduce
    // the bug). A pipe read mirrors the runtime: socket-completion wake,
    // then task code arms a select timeout.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const os_time = @import("../../os/time.zig");

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const pipefd = try posix.pipe(.{ .nonblocking = true, .cloexec = true });
    defer _ = fs.close(pipefd[0]) catch {};
    defer _ = fs.close(pipefd[1]) catch {};

    var read_data: [8]u8 = undefined;
    var read_iovecs: [1]fs.iovec = undefined;
    const read_buf = ReadBuf.fromSlice(&read_data, &read_iovecs);
    var stream_read: FileReadStreaming = .init(pipefd[0], read_buf);
    stream_read.pollable = true;
    loop.add(&stream_read.c);

    const thread = try std.Thread.spawn(.{}, struct {
        fn write(fd: posix.fd_t) void {
            os_time.sleep(.fromMilliseconds(1200));
            // A 1-byte pipe write cannot block; write directly via libc.
            _ = std.c.write(fd, "x", 1);
        }
    }.write, .{pipefd[1]});
    defer thread.join();

    // The poll sleeps ~1.2s and wakes on the pipe-read completion.
    while (stream_read.c.loadState().phase != .dead) {
        try loop.poll(.max);
    }
    _ = try stream_read.getResult();

    // Arm after the poll returned, exactly where the runtime runs task code.
    var timer: Timer = .init(.{ .duration = .fromMilliseconds(500) });
    const armed_at = os_time.now(.monotonic);
    loop.add(&timer.c);
    try loop.run();
    const fired_at = os_time.now(.monotonic);
    const elapsed_ms = @divTrunc(fired_at.toNanoseconds() - armed_at.toNanoseconds(), 1_000_000);

    try std.testing.expectEqual(.dead, timer.c.loadState().phase);
    // Backdated: fires in ~0ms. Correct: no earlier than the duration.
    try std.testing.expect(elapsed_ms >= 450);
    try std.testing.expect(elapsed_ms <= 1500);
    std.log.info("post-idle arm: expected=500ms, actual={d}ms", .{elapsed_ms});
}
