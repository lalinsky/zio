// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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
//! fn worker(barrier: *zio.Barrier, id: u32) !void {
//!     // Phase 1: do some work
//!     std.debug.print("Worker {} starting phase 1\n", .{id});
//!
//!     // Wait for all workers to complete phase 1
//!     const is_leader = try barrier.wait();
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
//! var task1 = try runtime.spawn(worker, .{runtime, &barrier, 1 });
//! var task2 = try runtime.spawn(worker, .{runtime, &barrier, 2 });
//! var task3 = try runtime.spawn(worker, .{runtime, &barrier, 3 });
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Group = @import("../runtime/group.zig").Group;
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
/// const is_leader = try barrier.wait();
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
pub fn wait(self: *Barrier) (Cancelable || error{BrokenBarrier})!bool {
    try self.mutex.lock();
    defer self.mutex.unlock();

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
        self.cond.broadcast();
        return true;
    } else {
        // Wait for the barrier to be released
        while (self.generation == local_gen and !self.broken) {
            self.cond.wait(&self.mutex) catch |err| {
                // On cancellation: break the barrier and wake all waiters
                self.current -= 1;
                self.broken = true;
                self.cond.broadcast();
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
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var counter: u32 = 0;
    var results: [3]u32 = undefined;

    const TestFn = struct {
        fn worker(b: *Barrier, cnt: *u32, result: *u32) !void {
            // Increment counter before barrier
            cnt.* += 1;

            // Wait at barrier - all should see counter == 3 after this
            _ = try b.wait();

            // All coroutines should see the same final counter value
            result.* = cnt.*;
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    for (&results) |*result| {
        try group.spawn(runtime, TestFn.worker, .{ &barrier, &counter, result });
    }

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // All coroutines should have seen counter == 3
    for (results) |result| {
        try std.testing.expectEqual(3, result);
    }
}

test "Barrier: leader detection" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var leader_count: u32 = 0;

    const TestFn = struct {
        fn worker(b: *Barrier, leader_cnt: *u32) !void {
            const is_leader = try b.wait();
            if (is_leader) {
                leader_cnt.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.worker, .{ &barrier, &leader_count });
    try group.spawn(runtime, TestFn.worker, .{ &barrier, &leader_count });
    try group.spawn(runtime, TestFn.worker, .{ &barrier, &leader_count });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // Exactly one coroutine should have been the leader
    try std.testing.expectEqual(1, leader_count);
}

test "Barrier: reusable for multiple cycles" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(2);
    var phase1_done: u32 = 0;
    var phase2_done: u32 = 0;
    var phase3_done: u32 = 0;

    const TestFn = struct {
        fn worker(b: *Barrier, p1: *u32, p2: *u32, p3: *u32) !void {
            // Phase 1
            p1.* += 1;
            _ = try b.wait();

            // Phase 2
            p2.* += 1;
            _ = try b.wait();

            // Phase 3
            p3.* += 1;
            _ = try b.wait();
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    try group.spawn(runtime, TestFn.worker, .{ &barrier, &phase1_done, &phase2_done, &phase3_done });
    try group.spawn(runtime, TestFn.worker, .{ &barrier, &phase1_done, &phase2_done, &phase3_done });

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(2, phase1_done);
    try std.testing.expectEqual(2, phase2_done);
    try std.testing.expectEqual(2, phase3_done);
}

test "Barrier: single coroutine barrier" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(1);
    var is_leader_result = false;

    const TestFn = struct {
        fn worker(b: *Barrier, leader: *bool) !void {
            const is_leader = try b.wait();
            leader.* = is_leader;
        }
    };

    var handle = try runtime.spawn(TestFn.worker, .{ &barrier, &is_leader_result });
    try handle.join(runtime);

    try std.testing.expect(is_leader_result);
}

test "Barrier: ordering test" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(3);
    var arrivals: [3]u32 = .{ 0, 0, 0 };
    var arrival_order: u32 = 0;
    var final_order: u32 = 0;

    const TestFn = struct {
        fn worker(b: *Barrier, order: *u32, my_arrival: *u32, final: *u32) !void {
            // Record arrival order
            my_arrival.* = order.*;
            order.* += 1;

            // Wait at barrier
            _ = try b.wait();

            // After barrier, store final order value
            final.* = order.*;
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    for (&arrivals) |*my_arrival| {
        try group.spawn(runtime, TestFn.worker, .{ &barrier, &arrival_order, my_arrival, &final_order });
    }

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // All three should have unique arrival numbers (0, 1, 2 in some order)
    var seen = [_]bool{false} ** 3;
    for (arrivals) |arrival| {
        try std.testing.expect(arrival < 3);
        try std.testing.expect(!seen[arrival]);
        seen[arrival] = true;
    }

    // After barrier, order should be 3
    try std.testing.expectEqual(3, final_order);
}

test "Barrier: many coroutines" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var barrier = Barrier.init(5);
    var counter: u32 = 0;
    var final_counts: [5]u32 = undefined;

    const TestFn = struct {
        fn worker(b: *Barrier, cnt: *u32, result: *u32) !void {
            cnt.* += 1;
            _ = try b.wait();
            result.* = cnt.*;
        }
    };

    var group: Group = .init;
    defer group.cancel(runtime);

    for (&final_counts) |*result| {
        try group.spawn(runtime, TestFn.worker, .{ &barrier, &counter, result });
    }

    try group.wait(runtime);
    try std.testing.expect(!group.hasFailed());

    // All should see the final counter value
    for (final_counts) |count| {
        try std.testing.expectEqual(5, count);
    }
}
