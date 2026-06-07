// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A recursive mutual exclusion primitive for protecting shared data in async contexts.
//!
//! Unlike `Mutex`, a `Recursive` allows the same task (or thread) to acquire the lock
//! multiple times without deadlocking. Each `lock()` must be paired with a corresponding
//! `unlock()`. The lock is only released when the outermost `unlock()` is called.
//!
//! This is useful when a function that locks a mutex calls another function that also
//! needs to lock the same mutex, without needing to restructure the code to avoid
//! re-locking.
//!
//! Lock operations are cancelable. If a task is cancelled while waiting for the lock
//! (on the first acquisition), it will properly handle cleanup and propagate the error.
//!
//! ## Example
//!
//! ```zig
//! var mutex: zio.Mutex.Recursive = .init;
//! var shared_data: u32 = 0;
//!
//! fn outer(mtx: *zio.Mutex.Recursive, data: *u32) !void {
//!     try mtx.lock();
//!     defer mtx.unlock();
//!     data.* += 1;
//!     try inner(mtx, data);  // Re-acquires the same mutex without deadlocking
//! }
//!
//! fn inner(mtx: *zio.Mutex.Recursive, data: *u32) !void {
//!     try mtx.lock();
//!     defer mtx.unlock();
//!     data.* += 1;
//! }
//! ```

const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Group = @import("../../group.zig").Group;
const Cancelable = @import("../../common.zig").Cancelable;
const Mutex = @import("../Mutex.zig");
const getCurrentTaskOrNull = @import("../../runtime.zig").getCurrentTaskOrNull;

const Recursive = @This();

mtx: Mutex = .init,

/// Owner identity packed as a raw usize:
/// - 0: no owner
/// - In task context: @intFromPtr(task)
/// - In thread context: std.Thread.Id as usize
///
/// Task pointers and thread IDs occupy non-overlapping ranges on all supported
/// platforms (thread IDs are small integers; task pointers are heap addresses).
///
/// Atomic so that the "already owned?" check in lock()/tryLock() does not race
/// with writes from the owning task.
owner: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

/// Recursion depth. Only ever read or written by the current owner while it
/// holds `mtx`, so no atomics are needed.
count: u32 = 0,

/// Creates a new unlocked recursive mutex.
pub const init: Recursive = .{};

/// Encodes the current caller's identity into a usize.
fn currentOwner() usize {
    if (getCurrentTaskOrNull()) |task| {
        return @intFromPtr(task);
    }
    return @as(usize, @intCast(std.Thread.getCurrentId()));
}

/// Attempts to acquire the mutex without blocking.
///
/// If the mutex is already held by the current task/thread, the recursion count
/// is incremented and `true` is returned.
///
/// If the mutex is held by another task/thread, returns `false` immediately.
///
/// This function will never suspend the current task.
pub fn tryLock(self: *Recursive) bool {
    const current = currentOwner();

    // Fast path: we already hold the lock – just increment count.
    // .acquire synchronizes-with the .release store in lock()/lockUncancelable(),
    // ensuring we see the owner that was set while holding mtx.
    if (self.owner.load(.acquire) == current) {
        self.count += 1;
        return true;
    }

    // Slow path: try to acquire the underlying mutex.
    if (!self.mtx.tryLock()) return false;

    self.owner.store(current, .release);
    self.count = 1;
    return true;
}

/// Acquires the mutex, blocking if it is held by another task/thread.
///
/// If the current task/thread already holds the mutex, the recursion count is
/// incremented and this function returns immediately without blocking.
///
/// If the mutex is held by another task/thread, the current task will be
/// suspended until the lock becomes available.
///
/// Returns `error.Canceled` if the task is cancelled while waiting for the lock.
/// Cancellation only applies on the first (non-recursive) acquisition.
pub fn lock(self: *Recursive) Cancelable!void {
    const current = currentOwner();

    // Fast path: we already hold the lock – just increment count.
    if (self.owner.load(.acquire) == current) {
        self.count += 1;
        return;
    }

    // Slow path: acquire underlying mutex.
    try self.mtx.lock();
    self.owner.store(current, .release);
    self.count = 1;
}

/// Acquires the mutex, ignoring cancellation.
///
/// Like `lock()`, but cancellation requests are ignored during the lock
/// acquisition. This always acquires the lock and never returns an error.
///
/// If the current task/thread already holds the mutex, the recursion count is
/// incremented and this function returns immediately.
pub fn lockUncancelable(self: *Recursive) void {
    const current = currentOwner();

    // Fast path: we already hold the lock – just increment count.
    if (self.owner.load(.acquire) == current) {
        self.count += 1;
        return;
    }

    // Slow path: acquire underlying mutex.
    self.mtx.lockUncancelable();
    self.owner.store(current, .release);
    self.count = 1;
}

/// Releases the mutex.
///
/// If the recursion count is greater than 1, the count is decremented and the
/// mutex remains held by the current owner. Only when the count reaches 0 is
/// the mutex truly released, potentially waking the next waiter.
///
/// It is undefined behavior if the current task/thread does not hold the lock,
/// or if `unlock()` is called more times than `lock()`.
pub fn unlock(self: *Recursive) void {
    std.debug.assert(self.count > 0);
    self.count -= 1;

    if (self.count == 0) {
        // Order matters: clear owner before releasing mtx, so that a concurrent
        // tryLock() in the same task doesn't see a stale non-zero owner after
        // another task acquires. The .release pairs with .acquire in lock()/tryLock().
        self.owner.store(0, .release);
        self.mtx.unlock();
    }
}

/// Returns true if the mutex is currently held by any task or thread.
pub fn isLocked(self: *const Recursive) bool {
    return self.owner.load(.acquire) != 0;
}

test "Recursive basic lock/unlock" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex = Recursive.init;
    var shared_counter: u32 = 0;

    const TestFn = struct {
        fn worker(counter: *u32, mtx: *Recursive) !void {
            for (0..100) |_| {
                try mtx.lock();
                defer mtx.unlock();
                counter.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.worker, .{ &shared_counter, &mutex });
    try group.spawn(TestFn.worker, .{ &shared_counter, &mutex });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(200, shared_counter);
}

test "Recursive tryLock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var mutex = Recursive.init;

    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(mutex.tryLock()); // Recursive – same owner
    try std.testing.expect(mutex.tryLock()); // Recursive again
    try std.testing.expect(mutex.isLocked());

    mutex.unlock();
    mutex.unlock();
    mutex.unlock();

    try std.testing.expect(!mutex.isLocked());
}

test "Recursive recursive lock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var mutex = Recursive.init;
    var value: u32 = 0;

    const TestFn = struct {
        fn outer(mtx: *Recursive, val: *u32) !void {
            try mtx.lock();
            defer mtx.unlock();
            val.* += 1;
            try inner(mtx, val);
        }

        fn inner(mtx: *Recursive, val: *u32) !void {
            try mtx.lock();
            defer mtx.unlock();
            val.* += 1;
            try deeper(mtx, val);
        }

        fn deeper(mtx: *Recursive, val: *u32) !void {
            try mtx.lock();
            defer mtx.unlock();
            val.* += 1;
        }
    };

    try TestFn.outer(&mutex, &value);
    try std.testing.expectEqual(3, value);
    try std.testing.expect(!mutex.isLocked());
}

test "Recursive mutual exclusion with recursion" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var counter: u32 = 0;
    var mutex = Recursive.init;

    const TestFn = struct {
        fn worker(ctr: *u32, mtx: *Recursive) !void {
            for (0..100) |_| {
                try mtx.lock();
                defer mtx.unlock();

                // Simulate nested locking (e.g., calling helper functions)
                try mtx.lock();
                defer mtx.unlock();

                ctr.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    for (0..4) |_| {
        try group.spawn(TestFn.worker, .{ &counter, &mutex });
    }

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(400, counter);
}

test "Recursive different owners cannot recurse" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var mutex = Recursive.init;
    var task1_acquired = false;

    // Task 1 acquires the lock
    try mutex.lock();
    defer mutex.unlock();

    try std.testing.expect(mutex.isLocked());

    // Task 1 can recurse
    try mutex.lock();
    mutex.unlock();

    // Another task trying tryLock should fail
    const TestFn = struct {
        fn tryAcquire(mtx: *Recursive, acquired: *bool) void {
            acquired.* = mtx.tryLock();
            if (acquired.*) mtx.unlock();
        }
    };

    var handle = try rt.spawn(TestFn.tryAcquire, .{ &mutex, &task1_acquired });
    handle.join();

    try std.testing.expect(!task1_acquired);
}

test "Recursive cancel waiting on first acquisition" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex = Recursive.init;

    // Hold the lock
    try mutex.lock();
    defer mutex.unlock();

    // Spawn a task that will block waiting for the lock
    var handle = try runtime.spawn(struct {
        fn waitForLock(mtx: *Recursive) !void {
            try mtx.lock();
            mtx.unlock();
        }
    }.waitForLock, .{&mutex});

    // Cancel the waiting task
    handle.cancel();

    // Should error with Canceled
    try std.testing.expectError(error.Canceled, handle.join());
}


