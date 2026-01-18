// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! User-mode futex implementation for the zio coroutine runtime.
//!
//! This provides futex-like semantics (wait on address, wake waiters) within
//! the coroutine scheduler. Unlike kernel futex, this only works for coroutines
//! within the same zio Runtime, but works across all executors.
//!
//! API mirrors `std.Thread.Futex`:
//!
//! ```zig
//! const Futex = @import("zio").Futex;
//!
//! // Wait until *ptr != expect or woken
//! try Futex.wait(runtime, ptr, expect);
//!
//! // Wait with timeout
//! Futex.timedWait(runtime, ptr, expect, timeout_ns) catch |err| switch (err) {
//!     error.Timeout => // timed out,
//!     error.Canceled => // task was cancelled,
//! };
//!
//! // Wake up to N waiters
//! Futex.wake(runtime, ptr, 1);
//! ```

const std = @import("std");
const builtin = @import("builtin");

const Runtime = @import("../runtime.zig").Runtime;
const AnyTask = @import("../runtime/task.zig").AnyTask;
const AutoCancel = @import("../runtime/autocancel.zig").AutoCancel;
const Cancelable = @import("../common.zig").Cancelable;
const Duration = @import("../time.zig").Duration;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;

const Futex = @This();

const buckets_per_executor = 1024;

/// Futex wait table stored in Runtime. Dynamically sized based on executor count.
pub const Table = struct {
    buckets: []Bucket,
    shift: std.math.Log2Int(usize),

    pub fn init(allocator: std.mem.Allocator, num_executors: usize) !Table {
        // Round up to power of 2 for efficient hashing
        const min_buckets = buckets_per_executor * num_executors;
        const bucket_count = try std.math.ceilPowerOfTwo(usize, min_buckets);
        const buckets = try allocator.alloc(Bucket, bucket_count);
        @memset(buckets, .{});
        return .{
            .buckets = buckets,
            .shift = @intCast(@bitSizeOf(usize) - @ctz(bucket_count)),
        };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
    }
};

const Bucket = struct {
    mutex: std.Thread.Mutex = .{},
    waiters: SimpleWaitQueue(FutexWaiter) = .empty,
};

fn getBucket(table: *Table, address: usize) *Bucket {
    // Fibonacci hash - golden ratio distributes addresses evenly
    const fibonacci_multiplier = 0x9E3779B97F4A7C15 >> (64 - @bitSizeOf(usize));
    const index = (address *% fibonacci_multiplier) >> table.shift;
    return &table.buckets[index];
}

/// Checks if `ptr` still contains the value `expect` and, if so, blocks the caller until either:
/// - The value at `ptr` is no longer equal to `expect`.
/// - The caller is unblocked by a matching `wake()`.
/// - The caller is unblocked spuriously.
/// - The caller's task is cancelled, in which case `error.Canceled` is returned.
pub fn wait(runtime: *Runtime, ptr: *const u32, expect: u32) Cancelable!void {
    return timedWait(runtime, ptr, expect, Duration.max) catch |err| switch (err) {
        error.Timeout => unreachable,
        error.Canceled => error.Canceled,
    };
}

/// Stack-allocated waiter for futex operations.
const FutexWaiter = struct {
    // Linked list fields for SimpleWaitQueue
    next: ?*FutexWaiter = null,
    prev: ?*FutexWaiter = null,
    in_list: bool = false,
    task: *AnyTask,
    address: usize,

    /// Pad to cache line to prevent false sharing.
    _: void align(std.atomic.cache_line) = {},
};

/// Like `wait`, but also returns `error.Timeout` if the timeout elapses.
pub fn timedWait(runtime: *Runtime, ptr: *const u32, expect: u32, timeout: Duration) (Cancelable || error{Timeout})!void {
    // Fast path: check if value already changed
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        return;
    }

    const task = runtime.getCurrentTask();
    const executor = task.getExecutor();
    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    // Set up timeout timer
    var timer: AutoCancel = .{};
    defer timer.clear(runtime);
    timer.set(runtime, timeout);

    // Use a stack-allocated waiter with its own WaitNode
    var waiter = FutexWaiter{
        .task = task,
        .address = address,
    };

    // Add to bucket under lock
    bucket.mutex.lock();

    // Double-check under lock to avoid lost wakeups
    if (@atomicLoad(u32, ptr, .monotonic) != expect) {
        bucket.mutex.unlock();
        return;
    }

    // Prepare to wait - set state before adding to queue
    task.state.store(.preparing_to_wait, .release);

    // Add waiter to queue
    bucket.waiters.push(&waiter);

    bucket.mutex.unlock();

    // Yield to scheduler
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // On cancellation, remove from queue
        removeFromBucket(bucket, &waiter);

        // Check if this auto-cancel triggered, otherwise it was user cancellation
        if (timer.check(runtime, err)) return error.Timeout;
        return err;
    };

    // If timeout fired, we should have received error.Canceled from yield
    std.debug.assert(!timer.triggered);
}

/// Remove a waiter from its bucket (for cancellation/timeout).
fn removeFromBucket(bucket: *Bucket, waiter: *FutexWaiter) void {
    bucket.mutex.lock();
    defer bucket.mutex.unlock();
    _ = bucket.waiters.remove(waiter);
}

/// Unblocks at most `max_waiters` callers blocked in a `wait()` call on `ptr`.
pub fn wake(runtime: *Runtime, ptr: *const u32, max_waiters: u32) void {
    if (max_waiters == 0) return;

    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    var total_woken: u32 = 0;

    // Wake in batches to handle more than 64 waiters
    while (total_woken < max_waiters) {
        var to_wake: [64]*FutexWaiter = undefined;
        var batch_count: u32 = 0;

        bucket.mutex.lock();

        // Iterate the queue looking for matching addresses
        var node = bucket.waiters.head;
        while (node) |waiter| {
            if (total_woken + batch_count >= max_waiters or batch_count >= to_wake.len) break;

            const next = waiter.next;

            if (waiter.address == address) {
                _ = bucket.waiters.remove(waiter);
                to_wake[batch_count] = waiter;
                batch_count += 1;
            }

            node = next;
        }

        bucket.mutex.unlock();

        // No more waiters for this address
        if (batch_count == 0) break;

        // Wake outside lock to avoid holding lock during resume
        for (to_wake[0..batch_count]) |waiter| {
            waiter.task.wake();
        }

        total_woken += batch_count;
    }
}

test "Futex: basic wait/wake" {
    const Main = struct {
        fn waiterFunc(io: *Runtime, v: *u32, w: *bool) !void {
            while (@atomicLoad(u32, v, .acquire) == 0) {
                try Futex.wait(io, v, 0);
            }
            @atomicStore(bool, w, true, .release);
        }

        fn wakerFunc(io: *Runtime, val: *u32) !void {
            @atomicStore(u32, val, 1, .release);
            Futex.wake(io, val, 1);
        }

        fn run(io: *Runtime) !void {
            var value: u32 = 0;
            var woken: bool = false;

            var waiter = try io.spawn(waiterFunc, .{ io, &value, &woken });
            defer waiter.cancel(io);

            var waker = try io.spawn(wakerFunc, .{ io, &value });
            try waker.join(io);

            var timeout: AutoCancel = .init;
            defer timeout.clear(io);
            timeout.set(io, .fromMilliseconds(10));

            try waiter.join(io);
            try std.testing.expect(woken);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(Main.run, .{rt});
    try task.join(rt);
}

test "Futex: spurious wakeup - value already changed" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 1; // Already != 0

    // Should return immediately since value != expect
    try Futex.wait(rt, &value, 0);
}

test "Futex: wake with no waiters" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;

    // Wake with no waiters should be a no-op
    Futex.wake(rt, &value, 1);
    Futex.wake(rt, &value, std.math.maxInt(u32));
}

test "Futex: multiple waiters same address" {
    const Main = struct {
        fn waiterFunc(io: *Runtime, v: *u32, w: *u32) !void {
            while (@atomicLoad(u32, v, .acquire) == 0) {
                try Futex.wait(io, v, 0);
            }
            _ = @atomicRmw(u32, w, .Add, 1, .monotonic);
        }

        fn wakerFunc(io: *Runtime, val: *u32) !void {
            // Yield multiple times to ensure waiters have time to block
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                try io.yield();
            }
            @atomicStore(u32, val, 1, .release);
            Futex.wake(io, val, 2);
        }

        fn run(io: *Runtime) !void {
            var value: u32 = 0;
            var woken: u32 = 0;

            var waiter1 = try io.spawn(waiterFunc, .{ io, &value, &woken });
            defer waiter1.cancel(io);

            var waiter2 = try io.spawn(waiterFunc, .{ io, &value, &woken });
            defer waiter2.cancel(io);

            var waker = try io.spawn(wakerFunc, .{ io, &value });
            try waker.join(io);

            var timeout: AutoCancel = .init;
            defer timeout.clear(io);
            timeout.set(io, .fromMilliseconds(10));

            try waiter1.join(io);
            try waiter2.join(io);
            try std.testing.expectEqual(2, woken);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(Main.run, .{rt});
    try task.join(rt);
}

test "Futex: multiple waiters different addresses" {
    const Main = struct {
        fn waiterFunc(io: *Runtime, v: *u32, w: *u32) !void {
            while (@atomicLoad(u32, v, .acquire) == 0) {
                try Futex.wait(io, v, 0);
            }
            _ = @atomicRmw(u32, w, .Add, 1, .monotonic);
        }

        fn wakerFunc(io: *Runtime, val: *u32) !void {
            @atomicStore(u32, val, 1, .release);
            Futex.wake(io, val, 1);
        }

        fn run(io: *Runtime, w: *u32) !void {
            var value1: u32 = 0;
            var value2: u32 = 0;

            var waiter1 = try io.spawn(waiterFunc, .{ io, &value1, w });
            defer waiter1.cancel(io);

            var waiter2 = try io.spawn(waiterFunc, .{ io, &value2, w });
            defer waiter2.cancel(io);

            var waker = try io.spawn(wakerFunc, .{ io, &value1 });
            try waker.join(io);

            var timeout: AutoCancel = .init;
            defer timeout.clear(io);
            timeout.set(io, .fromMilliseconds(10));

            try waiter1.join(io);
            waiter2.join(io) catch |err| {
                // waiter2 should be canceled by timeout since value2 was never woken
                return if (err == error.Canceled) {} else err;
            };
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var woken: u32 = 0;

    var task = try rt.spawn(Main.run, .{ rt, &woken });
    task.join(rt) catch {};

    // Only waiter1 should have completed - waiter2 was on a different address
    // and was canceled by the timeout
    try std.testing.expectEqual(1, woken);
}
