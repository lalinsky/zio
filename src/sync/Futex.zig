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
//! Futex.timedWait(runtime, ptr, expect, .{ .duration = .fromMilliseconds(100) }) catch |err| switch (err) {
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
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Waiter = @import("../common.zig").Waiter;
const Duration = @import("../time.zig").Duration;
const Timeout = @import("../time.zig").Timeout;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const AutoCancel = @import("../runtime/autocancel.zig").AutoCancel;

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
    // Fast path: check if value already changed
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        return;
    }

    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    // Use a stack-allocated waiter
    var futex_waiter = FutexWaiter{
        .waiter = Waiter.init(runtime),
        .address = address,
    };

    // Add to bucket under lock
    bucket.mutex.lock();

    // Double-check under lock to avoid lost wakeups
    if (@atomicLoad(u32, ptr, .monotonic) != expect) {
        bucket.mutex.unlock();
        return;
    }

    // Add waiter to queue
    bucket.waiters.push(&futex_waiter);

    bucket.mutex.unlock();

    // Wait for signal, handling spurious wakeups internally
    futex_waiter.waiter.wait(1, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = removeFromBucket(bucket, &futex_waiter);
        if (!was_in_queue) {
            // Removed by wake() - wait for signal to complete before destroying waiter
            futex_waiter.waiter.wait(1, .no_cancel);
        }
        return err;
    };
}

/// Stack-allocated waiter for futex operations.
const FutexWaiter = struct {
    // Linked list fields for SimpleWaitQueue
    next: ?*FutexWaiter = null,
    prev: ?*FutexWaiter = null,
    in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
    waiter: Waiter,
    address: usize,

    /// Pad to cache line to prevent false sharing.
    _: void align(std.atomic.cache_line) = {},
};

/// Like `wait`, but also returns `error.Timeout` if the timeout elapses.
pub fn timedWait(runtime: *Runtime, ptr: *const u32, expect: u32, timeout: Timeout) (Timeoutable || Cancelable)!void {
    // Fast path: check if value already changed
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        return;
    }

    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    // Use a stack-allocated waiter with its own WaitNode
    var futex_waiter = FutexWaiter{
        .waiter = Waiter.init(runtime),
        .address = address,
    };

    // Add to bucket under lock
    bucket.mutex.lock();

    // Double-check under lock to avoid lost wakeups
    if (@atomicLoad(u32, ptr, .monotonic) != expect) {
        bucket.mutex.unlock();
        return;
    }

    // Add waiter to queue
    bucket.waiters.push(&futex_waiter);

    bucket.mutex.unlock();

    // Wait for signal or timeout, handling spurious wakeups internally
    futex_waiter.waiter.timedWait(1, timeout, .allow_cancel) catch |err| {
        // On cancellation, try to remove from queue
        const was_in_queue = removeFromBucket(bucket, &futex_waiter);
        if (!was_in_queue) {
            // Removed by wake() - wait for signal to complete before destroying waiter
            futex_waiter.waiter.wait(1, .no_cancel);
        }
        return err;
    };

    // Determine winner: can we remove ourselves from queue?
    if (removeFromBucket(bucket, &futex_waiter)) {
        // We were still in queue - timer won
        return error.Timeout;
    }
}

/// Remove a waiter from its bucket (for cancellation/timeout).
/// Returns true if the waiter was in the queue, false if already removed by wake.
fn removeFromBucket(bucket: *Bucket, waiter: *FutexWaiter) bool {
    bucket.mutex.lock();
    defer bucket.mutex.unlock();
    return bucket.waiters.remove(waiter);
}

/// Unblocks at most `max_waiters` callers blocked in a `wait()` call on `ptr`.
pub fn wake(runtime: *Runtime, ptr: *const u32, max_waiters: u32) void {
    if (max_waiters == 0) return;

    const address = @intFromPtr(ptr);
    const bucket = getBucket(&runtime.futex_table, address);

    bucket.mutex.lock();

    var local_stack: ?*FutexWaiter = null;
    var count: u32 = 0;

    // Iterate the queue looking for matching addresses
    var node = bucket.waiters.head;
    while (node) |waiter| {
        if (count >= max_waiters) break;

        const next = waiter.next;

        if (waiter.address == address) {
            _ = bucket.waiters.remove(waiter);
            // Verify prev = null (sentinel prevents concurrent remove() from touching this node)
            std.debug.assert(waiter.prev == null and waiter.next == null);
            // Push to local stack (only uses next pointer)
            waiter.next = local_stack;
            local_stack = waiter;
            count += 1;
        }

        node = next;
    }

    bucket.mutex.unlock();

    // Wake all waiters outside lock to avoid holding lock during resume
    while (local_stack) |waiter| {
        local_stack = waiter.next;
        waiter.waiter.signal();
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
            defer timeout.clear();
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
            defer timeout.clear();
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
            defer timeout.clear();
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

test "Futex: timedWait timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;

    // Wait with timeout, no one will wake it, so should timeout
    const result = Futex.timedWait(rt, &value, 0, .{ .duration = .fromMilliseconds(10) });
    try std.testing.expectError(error.Timeout, result);
}
