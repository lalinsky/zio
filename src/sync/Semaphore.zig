// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

//! A counting semaphore for controlling access to a limited resource.
//!
//! A semaphore maintains a count of available permits. Tasks can acquire permits
//! via `wait()` (decrementing the count) and release permits via `post()`
//! (incrementing the count). When no permits are available, tasks attempting to
//! wait will suspend until a permit becomes available.
//!
//! This is useful for limiting concurrent access to resources, implementing
//! resource pools, or controlling parallelism.
//!
//! This implementation provides cooperative synchronization for the zio runtime.
//! Tasks waiting for permits will suspend and yield to the executor, allowing
//! other work to proceed.
//!
//! When a task waiting for a permit is cancelled, it ensures that any permit
//! that became available is signaled to other waiting tasks to prevent lost wakeups.
//!
//! ## Example
//!
//! ```zig
//! fn worker(rt: *Runtime, sem: *zio.Semaphore, id: u32) !void {
//!     // Acquire a permit (blocks if none available)
//!     try sem.wait(rt);
//!     defer sem.post(rt);
//!
//!     // Critical section - only N tasks can be here simultaneously
//!     std.debug.print("Worker {} in critical section\n", .{id});
//! }
//!
//! // Allow up to 3 concurrent workers
//! var semaphore = zio.Semaphore{ .permits = 3 };
//!
//! var task1 = try runtime.spawn(worker, .{runtime, &semaphore, 1 }, .{});
//! var task2 = try runtime.spawn(worker, .{runtime, &semaphore, 2 }, .{});
//! var task3 = try runtime.spawn(worker, .{runtime, &semaphore, 3 }, .{});
//! var task4 = try runtime.spawn(worker, .{runtime, &semaphore, 4 }, .{});
//! var task5 = try runtime.spawn(worker, .{runtime, &semaphore, 5 }, .{});
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");
mutex: Mutex = Mutex.init,
cond: Condition = Condition.init,
/// It is OK to initialize this field to any value.
permits: usize = 0,

const Semaphore = @This();

/// Acquires a permit, blocking if none are available.
///
/// Decrements the permit count by 1. If no permits are available (count is 0),
/// suspends the current task until a permit is released via `post()`.
///
/// If the task is cancelled while waiting, any permit that became available
/// is signaled to other waiting tasks to avoid lost wakeups.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn wait(self: *Semaphore, rt: *Runtime) Cancelable!void {
    try self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    while (self.permits == 0) {
        self.cond.wait(rt, &self.mutex) catch {
            // Wake another waiter to handle any race with permit availability
            if (self.permits > 0) {
                self.cond.signal(rt);
            }
            return error.Canceled;
        };
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal(rt);
    }
}

/// Acquires a permit with cancellation shielding.
///
/// Like `wait()`, but guarantees the permit is acquired even if cancellation
/// occurs. Cancellation requests are ignored during the wait operation.
///
/// Decrements the permit count by 1. If no permits are available (count is 0),
/// suspends the current task until a permit is released via `post()`.
///
/// This is useful in critical sections where you must acquire a permit regardless
/// of cancellation (e.g., cleanup operations that need resource access).
///
/// If you need to propagate cancellation after acquiring the permit, call
/// `runtime.checkCanceled()` after this function returns.
pub fn waitUncancelable(self: *Semaphore, rt: *Runtime) void {
    rt.beginShield();
    defer rt.endShield();
    self.wait(rt) catch unreachable;
}

/// Acquires a permit with a timeout.
///
/// Like `wait()`, but returns `error.Timeout` if no permit becomes available
/// within the specified duration. The timeout is specified in nanoseconds.
///
/// If the task is cancelled while waiting, any permit that became available
/// is signaled to other waiting tasks to avoid lost wakeups.
///
/// Returns `error.Timeout` if the timeout expires before a permit becomes available.
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn timedWait(self: *Semaphore, rt: *Runtime, timeout_ns: u64) (Timeoutable || Cancelable)!void {
    var timeout_timer = std.time.Timer.start() catch unreachable;

    try self.mutex.lock(rt);
    defer self.mutex.unlock(rt);

    while (self.permits == 0) {
        const elapsed = timeout_timer.read();
        if (elapsed >= timeout_ns) {
            return error.Timeout;
        }

        const local_timeout_ns = timeout_ns - elapsed;
        self.cond.timedWait(rt, &self.mutex, local_timeout_ns) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => {
                // Wake another waiter to handle any race with permit availability
                if (self.permits > 0) {
                    self.cond.signal(rt);
                }
                return error.Canceled;
            },
        };
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal(rt);
    }
}

/// Releases a permit.
///
/// Increments the permit count by 1 and wakes one waiting task if any are waiting.
///
/// This operation is shielded from cancellation to ensure the permit is always
/// released, even if the calling task is in the process of being cancelled.
pub fn post(self: *Semaphore, rt: *Runtime) void {
    self.mutex.lockUncancelable(rt);
    defer self.mutex.unlock(rt);

    self.permits += 1;
    self.cond.signal(rt);
}

test "Semaphore: basic wait/post" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 1 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore, n: *i32) !void {
            try s.wait(rt);
            n.* += 1;
            s.post(rt);
        }
    };

    var n: i32 = 0;
    var task1 = try runtime.spawn(TestFn.worker, .{ runtime, &sem, &n }, .{});
    defer task1.cancel(runtime);
    var task2 = try runtime.spawn(TestFn.worker, .{ runtime, &sem, &n }, .{});
    defer task2.cancel(runtime);
    var task3 = try runtime.spawn(TestFn.worker, .{ runtime, &sem, &n }, .{});
    defer task3.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(i32, 3), n);
}

test "Semaphore: timedWait timeout" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var timed_out = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, timeout_flag: *bool) void {
            s.timedWait(rt, 10_000_000) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    try runtime.runUntilComplete(TestFn.waiter, .{ runtime, &sem, &timed_out }, .{});

    try testing.expect(timed_out);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: timedWait success" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var got_permit = false;

    const TestFn = struct {
        fn waiter(rt: *Runtime, s: *Semaphore, flag: *bool) void {
            s.timedWait(rt, 100_000_000) catch return;
            flag.* = true;
        }

        fn poster(rt: *Runtime, s: *Semaphore) !void {
            defer s.post(rt);
            try rt.yield();
        }
    };

    var waiter_task = try runtime.spawn(TestFn.waiter, .{ runtime, &sem, &got_permit }, .{});
    defer waiter_task.cancel(runtime);
    var poster_task = try runtime.spawn(TestFn.poster, .{ runtime, &sem }, .{});
    defer poster_task.cancel(runtime);

    try runtime.run();

    try testing.expect(got_permit);
    try testing.expectEqual(@as(usize, 0), sem.permits);
}

test "Semaphore: multiple permits" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 3 };

    const TestFn = struct {
        fn worker(rt: *Runtime, s: *Semaphore) !void {
            try s.wait(rt);
            // Don't post - consume the permit
        }
    };

    var task1 = try runtime.spawn(TestFn.worker, .{ runtime, &sem }, .{});
    defer task1.cancel(runtime);
    var task2 = try runtime.spawn(TestFn.worker, .{ runtime, &sem }, .{});
    defer task2.cancel(runtime);
    var task3 = try runtime.spawn(TestFn.worker, .{ runtime, &sem }, .{});
    defer task3.cancel(runtime);

    try runtime.run();

    try testing.expectEqual(@as(usize, 0), sem.permits);
}
