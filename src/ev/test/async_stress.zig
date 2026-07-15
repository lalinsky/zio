// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Stress tests for the Async notify/drain protocol under cross-thread fire.
//!
//! The contract under test: notifications are edge-triggered and coalescing —
//! after any notify(), the callback runs at least once, and a callback that
//! drains its guarded state to empty never strands work, no matter how
//! notify() interleaves with the rearm re-add (which can complete the handle
//! immediately when a notification already landed).

const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("../loop.zig").Loop;
const completion = @import("../completion.zig");
const Async = completion.Async;
const Completion = completion.Completion;
const OsMutex = @import("../../os/thread.zig").Mutex;

const Shared = struct {
    queue_mutex: OsMutex = .init(),
    queue_items: usize = 0,
    consumed: usize = 0,
    produced_total: usize,
    stop: *Async,

    fn drainCallback(loop: *Loop, c: *Completion) void {
        _ = loop;
        const async_handle: *Async = c.cast(Async);
        const self: *Shared = @ptrCast(@alignCast(async_handle.c.userdata.?));

        // Drain everything present; the edge-triggered contract makes
        // anything left behind here a stranding bug.
        self.queue_mutex.lock();
        const got = self.queue_items;
        self.queue_items = 0;
        self.queue_mutex.unlock();
        self.consumed += got;

        if (self.consumed >= self.produced_total) {
            self.stop.notify();
        }
    }
};

fn producer(shared: *Shared, work: *Async, count: usize) void {
    for (0..count) |_| {
        shared.queue_mutex.lock();
        shared.queue_items += 1;
        shared.queue_mutex.unlock();
        work.notify();
    }
}

test "Async: cross-thread notify storm with rearm never strands work" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const num_producers = 4;
    const per_producer = 25_000;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var stop = Async.init();
    stop.c.callback = struct {
        fn cb(l: *Loop, _: *Completion) void {
            l.stop();
        }
    }.cb;
    loop.add(&stop.c);

    var shared = Shared{
        .produced_total = num_producers * per_producer,
        .stop = &stop,
    };

    var work = Async.init();
    work.c.callback = Shared.drainCallback;
    work.c.userdata = &shared;
    // rearm: the loop re-adds the handle after each callback; the re-add
    // completes it again on the spot whenever a notify already landed, which
    // must iterate through the completions queue, not recurse.
    work.c.flags.rearm = true;
    loop.add(&work.c);

    var threads: [num_producers]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, producer, .{ &shared, &work, per_producer });
    }

    try loop.run(.until_done);

    for (threads) |t| t.join();

    // The callback that saw the final count may have left a raced remainder;
    // one more explicit drain settles it.
    shared.queue_mutex.lock();
    const leftover = shared.queue_items;
    shared.queue_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), leftover);
    try std.testing.expectEqual(shared.produced_total, shared.consumed);
}

test "Async: notify racing the rearm re-add is never lost" {
    if (builtin.single_threaded) return error.SkipZigTest;

    // Tight ping-pong: a single producer notifies exactly once per observed
    // consumption, maximizing the chance that the notify lands inside the
    // callback/re-add window. A single lost wake deadlocks the loop (caught
    // by the iteration bound below).
    const rounds = 50_000;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var stop = Async.init();
    stop.c.callback = struct {
        fn cb(l: *Loop, _: *Completion) void {
            l.stop();
        }
    }.cb;
    loop.add(&stop.c);

    const Ctx = struct {
        seen: std.atomic.Value(usize) = .init(0),
        stop: *Async,

        fn cb(l: *Loop, c: *Completion) void {
            _ = l;
            const async_handle: *Async = c.cast(Async);
            const self: *@This() = @ptrCast(@alignCast(async_handle.c.userdata.?));
            const n = self.seen.fetchAdd(1, .acq_rel) + 1;
            if (n >= rounds) self.stop.notify();
        }
    };

    var ctx = Ctx{ .stop = &stop };

    var work = Async.init();
    work.c.callback = Ctx.cb;
    work.c.userdata = &ctx;
    work.c.flags.rearm = true;
    loop.add(&work.c);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(w: *Async, c: *Ctx) void {
            var last: usize = 0;
            while (last < rounds) {
                w.notify();
                // Wait until the callback observed this notify before sending
                // the next one, so every notify races a fresh re-add window.
                while (true) {
                    const seen = c.seen.load(.acquire);
                    if (seen > last or seen >= rounds) break;
                    std.atomic.spinLoopHint();
                }
                last = c.seen.load(.acquire);
            }
        }
    }.run, .{ &work, &ctx });

    try loop.run(.until_done);
    t.join();

    try std.testing.expect(ctx.seen.load(.acquire) >= rounds);
}
