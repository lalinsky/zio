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
const Timeout = @import("../runtime/timeout.zig").Timeout;
const Cancelable = @import("../common.zig").Cancelable;
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
        const bucket_count = std.math.ceilPowerOfTwo(usize, min_buckets) catch min_buckets;
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
    /// Number of waiters in this bucket. Used for fast-path optimization in wake().
    /// Checked atomically before taking the lock - if 0, no need to lock.
    num_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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
    return timedWait(runtime, ptr, expect, 0) catch |err| switch (err) {
        error.Timeout => unreachable, // 0 timeout means wait forever
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

/// Like `wait`, but also returns `error.Timeout` if `timeout_ns` nanoseconds elapse.
/// A `timeout_ns` of 0 means wait forever.
pub fn timedWait(runtime: *Runtime, ptr: *const u32, expect: u32, timeout_ns: u64) (Cancelable || error{Timeout})!void {
    // Fast path: check if value already changed
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        return;
    }

    const task = runtime.getCurrentTask();
    const executor = task.getExecutor();
    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    // Set up timeout if specified
    var timeout: Timeout = .{};
    if (timeout_ns > 0) {
        timeout.set(runtime, timeout_ns);
    }
    defer timeout.clear(runtime);

    // Use a stack-allocated waiter with its own WaitNode
    var waiter = FutexWaiter{
        .task = task,
        .address = address,
    };

    // Add to bucket under lock
    bucket.mutex.lock();

    // Increment waiter count BEFORE checking value to avoid race with wake's fast path.
    // If wake sees 0 waiters, we're guaranteed to see wake's store to ptr.
    _ = bucket.num_waiters.fetchAdd(1, .acquire);

    // Double-check under lock to avoid lost wakeups
    if (@atomicLoad(u32, ptr, .monotonic) != expect) {
        _ = bucket.num_waiters.fetchSub(1, .monotonic);
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

        // Check if this timeout triggered, otherwise it was user cancellation
        return runtime.checkTimeout(&timeout, err);
    };

    // If timeout fired, we should have received error.Canceled from yield
    std.debug.assert(!timeout.triggered);
}

/// Remove a waiter from its bucket (for cancellation/timeout).
fn removeFromBucket(bucket: *Bucket, waiter: *FutexWaiter) void {
    bucket.mutex.lock();
    defer bucket.mutex.unlock();
    if (bucket.waiters.remove(waiter)) {
        _ = bucket.num_waiters.fetchSub(1, .release);
    }
}

/// Unblocks at most `max_waiters` callers blocked in a `wait()` call on `ptr`.
pub fn wake(runtime: *Runtime, ptr: *const u32, max_waiters: u32) void {
    if (max_waiters == 0) return;

    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    // Fast path: no waiters in this bucket.
    // Use fetchAdd(0, .release) to ensure the store to ptr is ordered before this check.
    // Paired with fetchAdd(1, .acquire) in wait - if we see 0, waiter will see our store.
    if (bucket.num_waiters.fetchAdd(0, .release) == 0) return;

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

        // Decrement counter for removed waiters
        if (batch_count > 0) {
            _ = bucket.num_waiters.fetchSub(batch_count, .release);
        }

        bucket.mutex.unlock();

        // No more waiters for this address
        if (batch_count == 0) break;

        // Wake outside lock to avoid holding lock during resume
        for (to_wake[0..batch_count]) |waiter| {
            const executor = waiter.task.getExecutor();
            executor.scheduleTask(waiter.task, .maybe_remote);
        }

        total_woken += batch_count;
    }
}

// Tests

test "Futex: sleep" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Sleeper = struct {
        fn run(runtime: *Runtime) !void {
            try runtime.sleep(1);
        }
    };

    _ = try rt.spawn(Sleeper.run, .{rt}, .{});
    try rt.run();
}

test "Futex: basic wait/wake" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;

    const Waiter = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            try Futex.wait(runtime, v, 0);
            try std.testing.expectEqual(1, @atomicLoad(u32, v, .acquire));
        }
    };

    const Waker = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            try runtime.sleep(1);
            @atomicStore(u32, v, 1, .release);
            Futex.wake(runtime, v, 1);
        }
    };

    var waiter = try rt.spawn(Waiter.run, .{ rt, &value }, .{});
    defer waiter.cancel(rt);

    var waker = try rt.spawn(Waker.run, .{ rt, &value }, .{});
    defer waker.cancel(rt);

    try waiter.join(rt);
}

test "Futex: spurious wakeup - value already changed" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 1; // Already != 0

    // Should return immediately since value != expect
    try Futex.wait(rt, &value, 0);
}

test "Futex: wake with no waiters (fast path)" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;

    // Wake with no waiters should be a fast no-op (no lock taken)
    Futex.wake(rt, &value, 1);
    Futex.wake(rt, &value, std.math.maxInt(u32));
}

test "Futex: multiple waiters same address" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;
    var woken_count: u32 = 0;

    const Waiter = struct {
        fn run(runtime: *Runtime, v: *u32, count: *u32) !void {
            // Use timedWait so test doesn't hang if wake fails
            Futex.timedWait(runtime, v, 0, 10 * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => return, // Not woken in time
                error.Canceled => return,
            };
            _ = @atomicRmw(u32, count, .Add, 1, .monotonic);
        }
    };

    const Waker = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            try runtime.sleep(1);
            @atomicStore(u32, v, 1, .release);
            Futex.wake(runtime, v, std.math.maxInt(u32)); // Wake all
        }
    };

    var w1 = try rt.spawn(Waiter.run, .{ rt, &value, &woken_count }, .{});
    defer w1.cancel(rt);
    var w2 = try rt.spawn(Waiter.run, .{ rt, &value, &woken_count }, .{});
    defer w2.cancel(rt);
    var w3 = try rt.spawn(Waiter.run, .{ rt, &value, &woken_count }, .{});
    defer w3.cancel(rt);
    var waker = try rt.spawn(Waker.run, .{ rt, &value }, .{});
    defer waker.cancel(rt);

    try rt.run();

    try std.testing.expectEqual(3, woken_count);
}

test "Futex: different addresses same bucket" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value1: u32 = 0;
    var value2: u32 = 0;
    var woken1: bool = false;
    var woken2: bool = false;

    const Waiter = struct {
        fn run(runtime: *Runtime, v: *u32, flag: *bool) !void {
            // Use timedWait so test doesn't hang
            Futex.timedWait(runtime, v, 0, 10 * std.time.ns_per_ms) catch |err| switch (err) {
                error.Timeout => return, // Not woken in time
                error.Canceled => return,
            };
            flag.* = true;
        }
    };

    const Waker = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            try runtime.sleep(1);
            @atomicStore(u32, v, 1, .release);
            Futex.wake(runtime, v, std.math.maxInt(u32)); // Wake all on this address
        }
    };

    // Start waiters
    var w1 = try rt.spawn(Waiter.run, .{ rt, &value1, &woken1 }, .{});
    defer w1.cancel(rt);
    var w2 = try rt.spawn(Waiter.run, .{ rt, &value2, &woken2 }, .{});
    defer w2.cancel(rt);

    // Start waker that only wakes value1
    var waker = try rt.spawn(Waker.run, .{ rt, &value1 }, .{});
    defer waker.cancel(rt);

    try rt.run();

    // w1 should be woken, w2 should have timed out
    try std.testing.expect(woken1);
    try std.testing.expect(!woken2);
}
