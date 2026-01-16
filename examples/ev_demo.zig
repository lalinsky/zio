// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level event loop API demo.
//!
//! This example demonstrates the raw event loop primitives in zio.ev.
//! For most use cases, prefer the higher-level zio.Runtime API which
//! provides coroutines, structured concurrency, and easier I/O.
//!
//! The low-level API is useful when you need:
//! - Callback-based async instead of coroutines
//! - Building a custom scheduler/runtime on top of zio.ev
//! - Embedding in a game loop (call loop.run(.no_wait) each frame)

const std = @import("std");
const zio = @import("zio");

const ev = zio.ev;

/// A simple repeating timer that counts down.
const RepeatingTimer = struct {
    name: []const u8,
    count: u32,
    timer: ev.Timer,

    fn start(self: *RepeatingTimer, loop: *ev.Loop) void {
        std.log.info("[{s}] starting, will tick {} times every {f}", .{ self.name, self.count, self.timer.delay });
        self.timer.c.userdata = self;
        self.timer.c.callback = onTick;
        loop.add(&self.timer.c);
    }

    fn onTick(loop: *ev.Loop, completion: *ev.Completion) void {
        const self: *RepeatingTimer = @ptrCast(@alignCast(completion.userdata.?));

        self.count -= 1;
        std.log.info("[{s}] tick! remaining: {}", .{ self.name, self.count });

        if (self.count > 0) {
            // Re-arm the timer - userdata and callback are preserved
            loop.add(completion);
        } else {
            std.log.info("[{s}] finished", .{self.name});
        }
    }
};

pub fn main() !void {
    std.log.info("=== Low-level event loop demo ===", .{});
    std.log.info("Backend: {s}", .{@tagName(ev.backend)});
    std.log.info("", .{});

    // Initialize the event loop
    var loop: ev.Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Create two repeating timers with different intervals
    var fast_timer: RepeatingTimer = .{
        .name = "fast",
        .count = 5,
        .timer = .init(.fromMilliseconds(500)),
    };

    var slow_timer: RepeatingTimer = .{
        .name = "slow",
        .count = 5,
        .timer = .init(.fromMilliseconds(1000)),
    };

    fast_timer.start(&loop);
    slow_timer.start(&loop);

    // Run until all completions are done
    try loop.run(.until_done);

    std.log.info("", .{});
    std.log.info("[main] event loop finished", .{});
}
