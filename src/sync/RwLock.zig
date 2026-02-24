// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A readers-writer lock for protecting shared data in async contexts.
//!
//! This lock allows multiple concurrent readers or a single writer. It is
//! designed for use with the zio async runtime and provides cooperative
//! locking that works with coroutines. When a task attempts to acquire a
//! locked RwLock, it will suspend and yield to the executor.
//!
//! Lock operations are cancelable. If a task is cancelled while waiting
//! for a lock, it will properly handle cleanup and propagate the error.
//!
//! ## Example
//!
//! ```zig
//! var rwlock: zio.RwLock = .init;
//! var shared_data: u32 = 0;
//!
//! // Reader
//! try rwlock.lockShared();
//! defer rwlock.unlockShared();
//! const value = shared_data;
//!
//! // Writer
//! try rwlock.lock();
//! defer rwlock.unlock();
//! shared_data += 1;
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const beginShield = @import("../runtime.zig").beginShield;
const endShield = @import("../runtime.zig").endShield;
const checkCancel = @import("../runtime.zig").checkCancel;
const yield = @import("../runtime.zig").yield;
const Group = @import("../group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const Mutex = @import("Mutex.zig");
const Condition = @import("Condition.zig");

const RwLock = @This();

const max_permits: u31 = std.math.maxInt(u31);

const State = packed struct(u32) {
    writer_waiting: bool = false,
    permits: u31 = max_permits,
};

mutex: Mutex = Mutex.init,
cond: Condition = Condition.init,
state: State = .{},

/// Creates a new unlocked RwLock.
pub const init: RwLock = .{};

/// Attempts to acquire the write lock without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the lock
/// is currently held by any reader or writer.
pub fn tryLock(self: *RwLock) bool {
    if (!self.mutex.tryLock()) return false;
    defer self.mutex.unlock();

    if (self.state.permits == max_permits) {
        self.state.permits = 0;
        return true;
    }

    return false;
}

/// Acquires the write lock, blocking if it is currently held.
///
/// If the lock is currently held by readers or another writer, the current
/// task will be suspended until exclusive access is available.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn lock(self: *RwLock) Cancelable!void {
    try self.mutex.lock();
    defer self.mutex.unlock();

    while (self.state.permits < max_permits) {
        self.cond.wait(&self.mutex) catch {
            self.state.writer_waiting = false;
            self.cond.signal();
            return error.Canceled;
        };
        self.state.writer_waiting = true;
    }

    self.state.writer_waiting = false;
    self.state.permits = 0;
}

/// Acquires the write lock, ignoring cancellation.
///
/// Like `lock()`, but cancellation requests are ignored during acquisition.
/// This is useful for cleanup operations where exclusive access is required
/// regardless of cancellation.
pub fn lockUncancelable(self: *RwLock) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    while (self.state.permits < max_permits) {
        self.cond.waitUncancelable(&self.mutex);
        self.state.writer_waiting = true;
    }

    self.state.writer_waiting = false;
    self.state.permits = 0;
}

/// Releases the write lock.
///
/// It is undefined behavior to call this without holding the write lock.
pub fn unlock(self: *RwLock) void {
    self.mutex.lockUncancelable();
    self.state.permits = max_permits;
    self.mutex.unlock();
    self.cond.broadcast();
}

/// Attempts to acquire a read lock without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if it
/// is currently held by a writer.
pub fn tryLockShared(self: *RwLock) bool {
    if (!self.mutex.tryLock()) return false;
    defer self.mutex.unlock();

    if (self.state.permits >= 1 and !self.state.writer_waiting) {
        self.state.permits -= 1;
        return true;
    }

    return false;
}

/// Acquires a read lock, blocking if a writer holds the lock.
///
/// Multiple tasks can hold read locks simultaneously. If a writer currently
/// holds the lock, the task will be suspended until the writer releases it.
///
/// Returns `error.Canceled` if the task is cancelled while waiting.
pub fn lockShared(self: *RwLock) Cancelable!void {
    try self.mutex.lock();
    defer self.mutex.unlock();

    while (self.state.permits < 1 or self.state.writer_waiting) {
        try self.cond.wait(&self.mutex);
    }

    self.state.permits -= 1;
}

/// Acquires a read lock, ignoring cancellation.
///
/// Like `lockShared()`, but cancellation requests are ignored during
/// acquisition. This is useful for cleanup operations that need read access
/// regardless of cancellation.
pub fn lockSharedUncancelable(self: *RwLock) void {
    self.mutex.lockUncancelable();
    defer self.mutex.unlock();

    while (self.state.permits < 1 or self.state.writer_waiting) {
        self.cond.waitUncancelable(&self.mutex);
    }

    self.state.permits -= 1;
}

/// Releases a read lock.
///
/// It is undefined behavior to call this without holding a read lock.
pub fn unlockShared(self: *RwLock) void {
    self.mutex.lockUncancelable();
    self.state.permits += 1;
    self.mutex.unlock();
    self.cond.signal();
}

test "RwLock basic write lock/unlock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var rwlock = RwLock.init;

    try std.testing.expect(rwlock.tryLock()); // Should succeed
    try std.testing.expect(!rwlock.tryLock()); // Should fail (write locked)
    try std.testing.expect(!rwlock.tryLockShared()); // Should fail (write locked)
    rwlock.unlock();
    try std.testing.expect(rwlock.tryLock()); // Should succeed again
    rwlock.unlock();
}

test "RwLock basic shared lock/unlock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var rwlock = RwLock.init;

    try std.testing.expect(rwlock.tryLockShared()); // Should succeed
    try std.testing.expect(rwlock.tryLockShared()); // Should succeed (multiple readers)
    try std.testing.expect(!rwlock.tryLock()); // Should fail (readers active)
    rwlock.unlockShared();
    rwlock.unlockShared();
    try std.testing.expect(rwlock.tryLock()); // Should succeed (no readers)
    rwlock.unlock();
}

test "RwLock concurrent readers and writers" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var rwlock = RwLock.init;
    var val_a: usize = 0;
    var val_b: usize = 0;
    var reads = std.atomic.Value(u32).init(0);

    const TestFn = struct {
        fn reader(rw: *RwLock, a: *usize, b: *usize, read_count: *std.atomic.Value(u32)) !void {
            for (0..100) |_| {
                try rw.lockShared();
                defer rw.unlockShared();

                // Both values should always be equal under the lock
                const va: *const volatile usize = a;
                const vb: *const volatile usize = b;
                try std.testing.expectEqual(va.*, vb.*);
                _ = read_count.fetchAdd(1, .monotonic);
            }
        }

        fn writer(rw: *RwLock, a: *usize, b: *usize) !void {
            for (0..100) |_| {
                try rw.lock();
                defer rw.unlock();

                a.* += 1;
                b.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(TestFn.writer, .{ &rwlock, &val_a, &val_b });
    try group.spawn(TestFn.writer, .{ &rwlock, &val_a, &val_b });
    try group.spawn(TestFn.reader, .{ &rwlock, &val_a, &val_b, &reads });
    try group.spawn(TestFn.reader, .{ &rwlock, &val_a, &val_b, &reads });

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(200, val_a);
    try std.testing.expectEqual(200, val_b);
    try std.testing.expect(reads.load(.monotonic) > 0);
}

test "RwLock writer exclusion" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var rwlock = RwLock.init;
    var counter: u32 = 0;

    const TestFn = struct {
        fn writer(rw: *RwLock, ctr: *u32) !void {
            for (0..100) |_| {
                try rw.lock();
                defer rw.unlock();
                ctr.* += 1;
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();

    for (0..4) |_| {
        try group.spawn(TestFn.writer, .{ &rwlock, &counter });
    }

    try group.wait();
    try std.testing.expect(!group.hasFailed());

    try std.testing.expectEqual(400, counter);
}
