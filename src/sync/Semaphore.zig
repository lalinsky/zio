// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

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
//!     try sem.wait();
//!     defer sem.post();
//!
//!     // Critical section - only N tasks can be here simultaneously
//!     std.debug.print("Worker {} in critical section\n", .{id});
//! }
//!
//! // Allow up to 3 concurrent workers
//! var semaphore = zio.Semaphore{ .permits = 3 };
//!
//! var task1 = try runtime.spawn(worker, .{runtime, &semaphore, 1 });
//! var task2 = try runtime.spawn(worker, .{runtime, &semaphore, 2 });
//! var task3 = try runtime.spawn(worker, .{runtime, &semaphore, 3 });
//! var task4 = try runtime.spawn(worker, .{runtime, &semaphore, 4 });
//! var task5 = try runtime.spawn(worker, .{runtime, &semaphore, 5 });
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const beginShield = @import("../runtime.zig").beginShield;
const endShield = @import("../runtime.zig").endShield;
const yield = @import("../runtime.zig").yield;
const Group = @import("../runtime/group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const time = @import("../time.zig");
const Duration = time.Duration;
const Timeout = time.Timeout;
const Timestamp = time.Timestamp;
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
pub fn wait(self: *Semaphore) Cancelable!void {
    try self.mutex.lock();
    defer self.mutex.unlock();

    while (self.permits == 0) {
        self.cond.wait(&self.mutex) catch {
            // Wake another waiter to handle any race with permit availability
            if (self.permits > 0) {
                self.cond.signal();
            }
            return error.Canceled;
        };
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal();
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
/// `Runtime.checkCancel()` after this function returns.
pub fn waitUncancelable(self: *Semaphore) void {
    beginShield();
    defer endShield();
    self.wait() catch unreachable;
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
pub fn timedWait(self: *Semaphore, timeout: Timeout) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return self.wait();
    }

    const deadline = timeout.toDeadline();

    try self.mutex.lock();
    defer self.mutex.unlock();

    while (self.permits == 0) {
        self.cond.timedWait(&self.mutex, deadline) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => {
                // Wake another waiter to handle any race with permit availability
                if (self.permits > 0) {
                    self.cond.signal();
                }
                return error.Canceled;
            },
        };
    }

    self.permits -= 1;
    if (self.permits > 0) {
        self.cond.signal();
    }
}

/// Releases a permit.
///
/// Increments the permit count by 1 and wakes one waiting task if any are waiting.
///
/// This operation is shielded from cancellation to ensure the permit is always
/// released, even if the calling task is in the process of being cancelled.
pub fn post(self: *Semaphore) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    self.permits += 1;
    self.cond.signal();
}

test "Semaphore: basic wait/post" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 1 };

    const TestFn = struct {
        fn worker(s: *Semaphore, n: *i32) !void {
            try s.wait();
            n.* += 1;
            s.post();
        }
    };

    var n: i32 = 0;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.worker, .{ &sem, &n });
    try group.spawn(TestFn.worker, .{ &sem, &n });
    try group.spawn(TestFn.worker, .{ &sem, &n });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(3, n);
}

test "Semaphore: timedWait timeout" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var sem = Semaphore{};
    var timed_out = false;

    const TestFn = struct {
        fn waiter(s: *Semaphore, timeout_flag: *bool) void {
            s.timedWait(.{ .duration = .fromMilliseconds(10) }) catch |err| {
                if (err == error.Timeout) {
                    timeout_flag.* = true;
                }
            };
        }
    };

    var handle = try runtime.spawn(TestFn.waiter, .{ &sem, &timed_out });
    handle.join();

    try std.testing.expect(timed_out);
    try std.testing.expectEqual(0, sem.permits);
}

test "Semaphore: timedWait success" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var sem = Semaphore{};
    var got_permit = false;

    const TestFn = struct {
        fn waiter(s: *Semaphore, flag: *bool) void {
            s.timedWait(.{ .duration = .fromMilliseconds(100) }) catch return;
            flag.* = true;
        }

        fn poster(s: *Semaphore) !void {
            defer s.post();
            try yield();
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.waiter, .{ &sem, &got_permit });
    try group.spawn(TestFn.poster, .{&sem});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expect(got_permit);
    try std.testing.expectEqual(0, sem.permits);
}

test "Semaphore: multiple permits" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var sem = Semaphore{ .permits = 3 };

    const TestFn = struct {
        fn worker(s: *Semaphore) !void {
            try s.wait();
            // Don't post - consume the permit
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.worker, .{&sem});
    try group.spawn(TestFn.worker, .{&sem});
    try group.spawn(TestFn.worker, .{&sem});

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(0, sem.permits);
}
