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
const Semaphore = @import("Semaphore.zig");
const Stopwatch = @import("../time.zig").Stopwatch;

const RwLock = @This();

const Count = @Int(.unsigned, @divFloor(@bitSizeOf(usize) - 1, 2));

const is_writing: usize = 1;
const writer: usize = 1 << 1;
const reader: usize = 1 << (1 + @bitSizeOf(Count));
const writer_mask: usize = std.math.maxInt(Count) << @ctz(writer);
const reader_mask: usize = std.math.maxInt(Count) << @ctz(reader);

state: usize = 0,
mutex: Mutex = Mutex.init,
semaphore: Semaphore = .{},

/// Creates a new unlocked RwLock.
pub const init: RwLock = .{};

/// Attempts to acquire the write lock without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the lock
/// is currently held by any reader or writer.
pub fn tryLock(self: *RwLock) bool {
    if (self.mutex.tryLock()) {
        const state = @atomicLoad(usize, &self.state, .seq_cst);
        if (state & reader_mask == 0) {
            _ = @atomicRmw(usize, &self.state, .Or, is_writing, .seq_cst);
            return true;
        }
        self.mutex.unlock();
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
    _ = @atomicRmw(usize, &self.state, .Add, writer, .seq_cst);
    self.mutex.lock() catch |err| {
        _ = @atomicRmw(usize, &self.state, .Sub, writer, .seq_cst);
        return err;
    };

    const state = @atomicRmw(usize, &self.state, .Add, is_writing -% writer, .seq_cst);
    if (state & reader_mask != 0) {
        self.semaphore.wait() catch |err| {
            self.unlock();
            return err;
        };
    }
}

/// Acquires the write lock, ignoring cancellation.
///
/// Like `lock()`, but cancellation requests are ignored during acquisition.
/// This is useful for cleanup operations where exclusive access is required
/// regardless of cancellation.
pub fn lockUncancelable(self: *RwLock) void {
    _ = @atomicRmw(usize, &self.state, .Add, writer, .seq_cst);
    self.mutex.lockUncancelable();

    const state = @atomicRmw(usize, &self.state, .Add, is_writing -% writer, .seq_cst);
    if (state & reader_mask != 0) {
        self.semaphore.waitUncancelable();
    }
}

/// Releases the write lock.
///
/// It is undefined behavior to call this without holding the write lock.
pub fn unlock(self: *RwLock) void {
    _ = @atomicRmw(usize, &self.state, .And, ~is_writing, .seq_cst);
    self.mutex.unlock();
}

/// Attempts to acquire a read lock without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if it
/// is currently held by a writer.
pub fn tryLockShared(self: *RwLock) bool {
    const state = @atomicLoad(usize, &self.state, .seq_cst);
    if (state & (is_writing | writer_mask) == 0) {
        _ = @cmpxchgStrong(
            usize,
            &self.state,
            state,
            state + reader,
            .seq_cst,
            .seq_cst,
        ) orelse return true;
    }

    if (self.mutex.tryLock()) {
        _ = @atomicRmw(usize, &self.state, .Add, reader, .seq_cst);
        self.mutex.unlock();
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
    var state = @atomicLoad(usize, &self.state, .seq_cst);
    while (state & (is_writing | writer_mask) == 0) {
        state = @cmpxchgWeak(
            usize,
            &self.state,
            state,
            state + reader,
            .seq_cst,
            .seq_cst,
        ) orelse return;
    }

    try self.mutex.lock();
    _ = @atomicRmw(usize, &self.state, .Add, reader, .seq_cst);
    self.mutex.unlock();
}

/// Acquires a read lock, ignoring cancellation.
///
/// Like `lockShared()`, but cancellation requests are ignored during
/// acquisition. This is useful for cleanup operations that need read access
/// regardless of cancellation.
pub fn lockSharedUncancelable(self: *RwLock) void {
    var state = @atomicLoad(usize, &self.state, .seq_cst);
    while (state & (is_writing | writer_mask) == 0) {
        state = @cmpxchgWeak(
            usize,
            &self.state,
            state,
            state + reader,
            .seq_cst,
            .seq_cst,
        ) orelse return;
    }

    self.mutex.lockUncancelable();
    _ = @atomicRmw(usize, &self.state, .Add, reader, .seq_cst);
    self.mutex.unlock();
}

/// Releases a read lock.
///
/// It is undefined behavior to call this without holding a read lock.
pub fn unlockShared(self: *RwLock) void {
    const state = @atomicRmw(usize, &self.state, .Sub, reader, .seq_cst);

    if ((state & reader_mask == reader) and (state & is_writing != 0)) {
        self.semaphore.post();
    }
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

test "RwLock last reader wakes writer when reader is queued first" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var rwlock = RwLock.init;
    var writer_acquired = std.atomic.Value(bool).init(false);

    try rwlock.lockShared(); // Read Lock A

    const TestFn = struct {
        fn reader(rw: *RwLock) void {
            rw.lockSharedUncancelable();
            rw.unlockShared();
        }

        fn writer(rw: *RwLock, acquired: *std.atomic.Value(bool)) void {
            rw.lockUncancelable();
            rw.unlock();
            acquired.store(true, .release);
        }
    };

    // Writer registers and parks on the semaphore, waiting for the reader
    // count to drain; a second reader then queues behind it on the mutex.
    var writer_handle = try runtime.spawn(TestFn.writer, .{ &rwlock, &writer_acquired });
    while (@atomicLoad(usize, &rwlock.state, .acquire) & is_writing == 0) {
        try yield();
    }

    var reader_handle = try runtime.spawn(TestFn.reader, .{&rwlock});
    while (!rwlock.mutex.queue.hasWaiters()) {
        try yield();
    }
    // TestFn.reader and TestFn.writer are now both blocked on lock acquisition.

    try std.testing.expect(!writer_acquired.load(.acquire));

    rwlock.unlockShared(); // Read Unlock A
    // Read Unlock A drops the reader count to zero; the writer must get the
    // semaphore post and the write lock, ahead of the queued reader.

    var stopwatch = Stopwatch.start();
    while (!writer_acquired.load(.acquire) and stopwatch.read().toMilliseconds() < 500) {
        try yield();
    }
    const writer_woke_from_last_reader = writer_acquired.load(.acquire);

    // If the assertion is going to fail, recover the blocked tasks before
    // leaving the test so Runtime.deinit() sees a clean task count.
    if (!writer_woke_from_last_reader) {
        rwlock.semaphore.post();
        while (!writer_acquired.load(.acquire)) {
            try yield();
        }
    }

    writer_handle.join();
    reader_handle.join();

    try std.testing.expect(writer_woke_from_last_reader);
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

test "RwLock cancel waiting writer" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var rwlock = RwLock.init;

    // Hold a read lock to block the writer
    try rwlock.lockShared();

    const TestFn = struct {
        fn writer(rw: *RwLock) !void {
            try rw.lock();
            rw.unlock();
        }
    };

    // Spawn a writer that will block waiting for the read lock to release
    var handle = try runtime.spawn(TestFn.writer, .{&rwlock});

    // Wait until the writer is parked on the semaphore
    while (@atomicLoad(usize, &rwlock.state, .acquire) & is_writing == 0) {
        try yield();
    }

    // Cancel the writer while it's waiting
    handle.cancel();

    // The writer must have backed out of the state, so readers can still acquire
    try std.testing.expect(rwlock.tryLockShared());
    rwlock.unlockShared();

    // Release the original read lock
    rwlock.unlockShared();

    // Writer lock should also work now
    try std.testing.expect(rwlock.tryLock());
    rwlock.unlock();
}
