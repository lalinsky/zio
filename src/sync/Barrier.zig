//! A synchronization barrier for coordinating multiple async tasks.
//!
//! A barrier allows a fixed number of tasks to wait at a synchronization point
//! until all participants have arrived. Once all tasks reach the barrier, they
//! are all released simultaneously to continue execution.
//!
//! This implementation provides cooperative synchronization for the zio runtime.
//! Tasks that arrive early will suspend and yield to the executor, allowing other
//! work to proceed.
//!
//! Barriers are reusable - after all tasks pass through, the barrier automatically
//! resets for the next synchronization cycle. This makes them ideal for iterative
//! algorithms where tasks need to synchronize at the end of each iteration.
//!
//! The barrier provides "leader election" - the last task to arrive receives a
//! special return value, allowing it to perform setup or cleanup for the next phase.
//!
//! If a task is cancelled while waiting, the barrier enters a "broken" state and
//! all current and future waiters receive `error.BrokenBarrier`. This prevents
//! deadlocks when tasks are cancelled.
//!
//! ## Example
//!
//! ```zig
//! fn worker(rt: *Runtime, barrier: *zio.Barrier, id: u32) !void {
//!     // Phase 1: do some work
//!     std.debug.print("Worker {} starting phase 1\n", .{id});
//!
//!     // Wait for all workers to complete phase 1
//!     const is_leader = try barrier.wait(rt);
//!
//!     // Phase 2: all workers proceed together
//!     if (is_leader) {
//!         std.debug.print("All workers reached barrier\n", .{});
//!     }
//!     std.debug.print("Worker {} starting phase 2\n", .{id});
//! }
//!
//! var barrier = zio.Barrier.init(3);
//!
//! var task1 = try runtime.spawn(worker, .{ &runtime, &barrier, 1 }, .{});
//! var task2 = try runtime.spawn(worker, .{ &runtime, &barrier, 2 }, .{});
//! var task3 = try runtime.spawn(worker, .{ &runtime, &barrier, 3 }, .{});
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");
mutex: Mutex = Mutex.init,
cond: Condition = Condition.init,
count: usize,
current: usize = 0,
generation: usize = 0,
broken: bool = false,

const Barrier = @This();

/// Initializes a barrier that will synchronize the specified number of tasks.
/// The count must be greater than 0.
pub fn init(count: usize) Barrier {
    std.debug.assert(count > 0);
    return .{ .count = count };
}

/// Waits at the barrier until all tasks have arrived.
///
/// When the last task arrives, all waiting tasks are released simultaneously.
/// The barrier automatically resets for the next synchronization cycle.
///
/// Returns `true` if this task was the last to arrive (the "leader"), `false`
/// otherwise. This can be useful for having one task perform cleanup or
/// initialization for the next phase:
/// ```zig
/// const is_leader = try barrier.wait(rt);
/// if (is_leader) {
///     // Perform phase transition work
/// }
/// ```
///
/// Returns `error.BrokenBarrier` if the barrier has been broken by a cancellation
/// of another waiting task. Once broken, the barrier cannot be used again.
///
/// Returns `error.Canceled` if this task is cancelled while waiting. This will
/// also break the barrier for all other waiting tasks.
pub fn wait(self: *Barrier, runtime: *Runtime) (Cancelable || error{BrokenBarrier})!bool {
    try self.mutex.lock(runtime);
    defer self.mutex.unlock(runtime);

    // Check if barrier is already broken
    if (self.broken) {
        return error.BrokenBarrier;
    }

    const local_gen = self.generation;
    self.current += 1;

    if (self.current >= self.count) {
        // Last one to arrive - release everyone
        self.current = 0;
        self.generation += 1;
        self.cond.broadcast(runtime);
        return true;
    } else {
        // Wait for the barrier to be released
        while (self.generation == local_gen and !self.broken) {
            self.cond.wait(runtime, &self.mutex) catch |err| {
                // On cancellation: break the barrier and wake all waiters
                self.current -= 1;
                self.broken = true;
                self.cond.broadcast(runtime);
                return err;
            };
        }

        // Check if we woke due to broken barrier
        if (self.broken) {
            return error.BrokenBarrier;
        }

        return false;
    }
}

test "Barrier: basic synchronization" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var counter: u32 = 0;
    var results: [3]u32 = undefined;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, cnt: *u32, result: *u32) !void {
            // Increment counter before barrier
            cnt.* += 1;

            // Wait at barrier - all should see counter == 3 after this
            _ = try b.wait(rt);

            // All coroutines should see the same final counter value
            result.* = cnt.*;
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &results[0] }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &results[1] }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &results[2] }, .{});
    defer task3.deinit();

    try runtime.run();

    // All coroutines should have seen counter == 3
    try testing.expectEqual(@as(u32, 3), results[0]);
    try testing.expectEqual(@as(u32, 3), results[1]);
    try testing.expectEqual(@as(u32, 3), results[2]);
}

test "Barrier: leader detection" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var leader_count: u32 = 0;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, leader_cnt: *u32) !void {
            const is_leader = try b.wait(rt);
            if (is_leader) {
                leader_cnt.* += 1;
            }
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &leader_count }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &leader_count }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &leader_count }, .{});
    defer task3.deinit();

    try runtime.run();

    // Exactly one coroutine should have been the leader
    try testing.expectEqual(@as(u32, 1), leader_count);
}

test "Barrier: reusable for multiple cycles" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(2);
    var phase1_done: u32 = 0;
    var phase2_done: u32 = 0;
    var phase3_done: u32 = 0;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, p1: *u32, p2: *u32, p3: *u32) !void {
            // Phase 1
            p1.* += 1;
            _ = try b.wait(rt);

            // Phase 2
            p2.* += 1;
            _ = try b.wait(rt);

            // Phase 3
            p3.* += 1;
            _ = try b.wait(rt);
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &phase1_done, &phase2_done, &phase3_done }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &phase1_done, &phase2_done, &phase3_done }, .{});
    defer task2.deinit();

    try runtime.run();

    try testing.expectEqual(@as(u32, 2), phase1_done);
    try testing.expectEqual(@as(u32, 2), phase2_done);
    try testing.expectEqual(@as(u32, 2), phase3_done);
}

test "Barrier: single coroutine barrier" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(1);
    var is_leader_result = false;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, leader: *bool) !void {
            const is_leader = try b.wait(rt);
            leader.* = is_leader;
        }
    };

    try runtime.runUntilComplete(TestFn.worker, .{ &runtime, &barrier, &is_leader_result }, .{});

    try testing.expect(is_leader_result);
}

test "Barrier: ordering test" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var arrivals: [3]u32 = .{ 0, 0, 0 };
    var arrival_order: u32 = 0;
    var final_order: u32 = 0;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, order: *u32, my_arrival: *u32, final: *u32) !void {
            // Record arrival order
            my_arrival.* = order.*;
            order.* += 1;

            // Wait at barrier
            _ = try b.wait(rt);

            // After barrier, store final order value
            final.* = order.*;
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &arrival_order, &arrivals[0], &final_order }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &arrival_order, &arrivals[1], &final_order }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &arrival_order, &arrivals[2], &final_order }, .{});
    defer task3.deinit();

    try runtime.run();

    // All three should have unique arrival numbers (0, 1, 2 in some order)
    var seen = [_]bool{false} ** 3;
    for (arrivals) |arrival| {
        try testing.expect(arrival < 3);
        try testing.expect(!seen[arrival]);
        seen[arrival] = true;
    }

    // After barrier, order should be 3
    try testing.expectEqual(@as(u32, 3), final_order);
}

test "Barrier: many coroutines" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(5);
    var counter: u32 = 0;
    var final_counts: [5]u32 = undefined;

    const TestFn = struct {
        fn worker(rt: *Runtime, b: *Barrier, cnt: *u32, result: *u32) !void {
            cnt.* += 1;
            _ = try b.wait(rt);
            result.* = cnt.*;
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &final_counts[0] }, .{});
    defer task1.deinit();
    var task2 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &final_counts[1] }, .{});
    defer task2.deinit();
    var task3 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &final_counts[2] }, .{});
    defer task3.deinit();
    var task4 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &final_counts[3] }, .{});
    defer task4.deinit();
    var task5 = try runtime.spawn(TestFn.worker, .{ &runtime, &barrier, &counter, &final_counts[4] }, .{});
    defer task5.deinit();

    try runtime.run();

    // All should see the final counter value
    for (final_counts) |count| {
        try testing.expectEqual(@as(u32, 5), count);
    }
}
