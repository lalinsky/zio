const std = @import("std");
const builtin = @import("builtin");
const ev = @import("../root.zig");
const os_thread = @import("../../os/thread.zig");
const ResetEvent = os_thread.ResetEvent;

test "ev.ThreadPool: one task" {
    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
    });
    defer thread_pool.deinit();

    var loop: ev.Loop = undefined;
    try loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();
    // Join the pool's threads before the loop is torn down: completion
    // callbacks wake the loop, so the loop must outlive the pool's threads.
    defer thread_pool.stop();

    const TestFn = struct {
        called: usize = 0,
        pub fn main(work: *ev.Work) void {
            var self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.called += 1;
        }
    };

    var test_fn: TestFn = .{};
    var work = ev.Work.init(&TestFn.main, @ptrCast(&test_fn));

    loop.add(&work.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, work.c.loadState().phase);
    try std.testing.expectEqual(1, test_fn.called);
}

test "ev.ThreadPool: reserved work runs even when the pool is saturated" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 0,
        .max_threads = 1,
    });
    defer thread_pool.deinit();
    defer thread_pool.stop();

    // A job that occupies the pool's single worker until the test releases it.
    const Blocker = struct {
        started: ResetEvent,
        gate: ResetEvent,
        pub fn main(work: *ev.Work) void {
            const self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.started.set();
            self.gate.wait();
        }
    };

    // A job that records that it ran and signals completion. With max_threads == 1
    // fully occupied, this can only make progress if reserve_thread grows the pool.
    const Reserved = struct {
        ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: ResetEvent,
        pub fn main(work: *ev.Work) void {
            const self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.ran.store(true, .release);
            self.done.set();
        }
    };

    var blocker: Blocker = .{ .started = .init(), .gate = .init() };
    defer blocker.started.deinit();
    defer blocker.gate.deinit();
    var blocker_work = ev.Work.init(&Blocker.main, @ptrCast(&blocker));
    thread_pool.submit(&blocker_work);

    // Ensure the worker is inside the blocker (the pool is now saturated) before
    // submitting the reserved job.
    blocker.started.wait();

    var reserved: Reserved = .{ .done = .init() };
    defer reserved.done.deinit();
    var reserved_work = ev.Work.init(&Reserved.main, @ptrCast(&reserved));
    reserved_work.reserve_thread = true;
    thread_pool.submit(&reserved_work);

    // Without the reservation this would deadlock (queued behind the blocker);
    // with it, a second worker is spawned to run it.
    reserved.done.wait();
    try std.testing.expect(reserved.ran.load(.acquire));

    // Release the blocker so the pool can shut down cleanly.
    blocker.gate.set();
}

test "ev.ThreadPool: reserved work reuses an idle worker instead of spawning" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 10,
    });
    defer thread_pool.deinit();
    defer thread_pool.stop();

    // Wait until both min-threads have parked, so there is idle capacity for the
    // reservation to reuse.
    var spins: usize = 0;
    while (thread_pool.idle_threads.load(.monotonic) < 2) {
        spins += 1;
        if (spins > 100_000_000) return error.TimedOut;
        os_thread.yield();
    }
    try std.testing.expectEqual(@as(usize, 2), thread_pool.running_threads.load(.monotonic));

    // A reserved job that parks so we can observe the worker count while it runs.
    const Job = struct {
        started: ResetEvent,
        gate: ResetEvent,
        pub fn main(work: *ev.Work) void {
            const self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.started.set();
            self.gate.wait();
        }
    };

    var job: Job = .{ .started = .init(), .gate = .init() };
    defer job.started.deinit();
    defer job.gate.deinit();
    var work = ev.Work.init(&Job.main, @ptrCast(&job));
    work.reserve_thread = true;
    thread_pool.submit(&work);

    // The reserved job runs on one of the two idle workers; because idle capacity
    // already covers the reservation, no new thread is spawned.
    job.started.wait();
    try std.testing.expectEqual(@as(usize, 2), thread_pool.running_threads.load(.monotonic));

    job.gate.set();
}

test "ev.ThreadPool: regular work still scales when reserved work occupies max_threads" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var thread_pool: ev.ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{
        .min_threads = 0,
        .max_threads = 1,
        .scale_threshold = 1,
    });
    defer thread_pool.deinit();
    defer thread_pool.stop();

    // A reserved job occupies the pool's single regular-budget worker.
    const Reserved = struct {
        started: ResetEvent,
        gate: ResetEvent,
        pub fn main(work: *ev.Work) void {
            const self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.started.set();
            self.gate.wait();
        }
    };
    var reserved: Reserved = .{ .started = .init(), .gate = .init() };
    defer reserved.started.deinit();
    defer reserved.gate.deinit();
    var reserved_work = ev.Work.init(&Reserved.main, @ptrCast(&reserved));
    reserved_work.reserve_thread = true;
    thread_pool.submit(&reserved_work);
    reserved.started.wait(); // now occupying the single max_threads slot

    // Regular work must still run: max_threads is the budget for regular work and
    // reserved work is additive, so the pool spawns a second worker for it. Without
    // counting reserved-occupied workers separately, this would starve behind the
    // blocked reserved job.
    const Regular = struct {
        ran: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: ResetEvent,
        pub fn main(work: *ev.Work) void {
            const self: *@This() = @ptrCast(@alignCast(work.userdata));
            self.ran.store(true, .release);
            self.done.set();
        }
    };
    var regular: Regular = .{ .done = .init() };
    defer regular.done.deinit();
    var regular_work = ev.Work.init(&Regular.main, @ptrCast(&regular));
    thread_pool.submit(&regular_work);

    regular.done.wait();
    try std.testing.expect(regular.ran.load(.acquire));

    reserved.gate.set();
}
