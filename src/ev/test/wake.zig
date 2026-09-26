// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Tests for the loop wake protocol: a wake reaches a sleeping loop through
//! the backend, and one that finds the loop awake is picked up by its next
//! poll without a backend wake.

const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const Timer = @import("../completion.zig").Timer;
const Timestamp = @import("../../time.zig").Timestamp;

test "Loop: a wake requested while the loop is awake keeps the next poll from blocking" {
    var loop: Loop = undefined;
    try loop.init(.{});
    loop.max_wait = .fromSeconds(10);
    defer loop.deinit();
    // A loop with nothing to wait for returns from poll at once; this timer
    // (far past the checks below) keeps it waiting.
    var keep_alive: Timer = .init(.{ .duration = .zero });
    loop.setTimer(&keep_alive, .{ .duration = .fromSeconds(60) });
    defer _ = loop.clearTimer(&keep_alive);

    // Not polling, so no backend wake happens; the request must still stop
    // the next poll from sleeping until max_wait.
    loop.wake();
    const start = Timestamp.now(.monotonic);
    try loop.poll(.max);
    const elapsed = start.durationTo(Timestamp.now(.monotonic));
    try std.testing.expect(elapsed.toMilliseconds() < 1000);
    try std.testing.expectEqual(0, loop.state.wake_requested.load(.acquire));
}

test "Loop: wakes from another thread always end the poll they race with" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // The loop is driven entirely on the runner thread (an io_uring
    // SINGLE_ISSUER ring must be entered by its creating thread). Each wake
    // below waits for the poll count to move, so a wake lost between the
    // loop's sleep announcement and its poll would hang until max_wait.
    const Shared = struct {
        loop: Loop = undefined,
        ready: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        polls: std.atomic.Value(u64) = .init(0),
        wake_done: std.atomic.Value(bool) = .init(false),
        keep_alive: Timer = .init(.{ .duration = .zero }),

        fn run(self: *@This()) void {
            self.loop.init(.{}) catch @panic("loop init failed");
            self.loop.max_wait = .fromSeconds(10);
            // Without pending work poll returns at once; the timer, far past
            // the test's deadlines, makes every poll(.max) a real sleep.
            self.loop.setTimer(&self.keep_alive, .{ .duration = .fromSeconds(120) });
            defer {
                while (!self.wake_done.load(.acquire)) std.Thread.yield() catch {};
                _ = self.loop.clearTimer(&self.keep_alive);
                self.loop.deinit();
            }
            self.ready.store(true, .release);
            while (!self.stop.load(.acquire)) {
                self.loop.poll(.max) catch return;
                _ = self.polls.fetchAdd(1, .release);
            }
        }
    };
    var shared: Shared = .{};
    const runner = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    defer runner.join();
    defer {
        shared.stop.store(true, .release);
        shared.loop.wake();
        shared.wake_done.store(true, .release);
    }
    while (!shared.ready.load(.acquire)) std.Thread.yield() catch {};

    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        // Vary the timing so wakes land while the loop sleeps, while it is
        // announcing its sleep, and while it is between polls.
        if (i % 3 == 1) std.Thread.yield() catch {};
        const before = shared.polls.load(.acquire);
        shared.loop.wake();
        const deadline = Timestamp.now(.monotonic).addDuration(.fromSeconds(2));
        while (shared.polls.load(.acquire) == before) {
            if (Timestamp.now(.monotonic).toNanoseconds() >= deadline.toNanoseconds()) return error.LostWake;
            std.atomic.spinLoopHint();
        }
    }
}
