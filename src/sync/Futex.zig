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
const Allocator = std.mem.Allocator;

const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const AnyTask = @import("../core/task.zig").AnyTask;
const WaitNode = @import("../core/WaitNode.zig");
const Timeout = @import("../core/timeout.zig").Timeout;
const Cancelable = @import("../common.zig").Cancelable;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;

const Futex = @This();

/// Global futex wait table. Stored in Runtime, shared across all executors.
pub const Table = struct {
    mutex: std.Thread.Mutex = .{},
    map: std.AutoHashMapUnmanaged(*const u32, SimpleWaitQueue(WaitNode)) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        self.map.deinit(self.allocator);
    }
};

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

/// Like `wait`, but also returns `error.Timeout` if `timeout_ns` nanoseconds elapse.
/// A `timeout_ns` of 0 means wait forever.
pub fn timedWait(runtime: *Runtime, ptr: *const u32, expect: u32, timeout_ns: u64) (Cancelable || error{Timeout})!void {
    // Fast path: check if value already changed
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        return;
    }

    const task = runtime.getCurrentTask();
    const executor = task.getExecutor();
    const table = &runtime.futex_table;

    // Set up timeout if specified
    var timeout: Timeout = .{};
    if (timeout_ns > 0) {
        timeout.set(runtime, timeout_ns);
    }
    defer timeout.clear(runtime);

    // Add to wait queue under lock
    table.mutex.lock();

    // Double-check under lock to avoid lost wakeups
    if (@atomicLoad(u32, ptr, .acquire) != expect) {
        table.mutex.unlock();
        return;
    }

    // Get or create wait queue for this address
    const entry = table.map.getOrPut(table.allocator, ptr) catch {
        table.mutex.unlock();
        // On allocation failure, just return (spurious wakeup semantics)
        return;
    };
    if (!entry.found_existing) {
        entry.value_ptr.* = .{};
    }

    // Prepare to wait - set state before adding to queue
    task.state.store(.preparing_to_wait, .release);

    // Add task's wait_node to queue
    entry.value_ptr.push(&task.awaitable.wait_node);

    table.mutex.unlock();

    // Yield to scheduler
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // On cancellation, remove from queue
        removeFromQueue(table, ptr, &task.awaitable.wait_node);

        // Check if this timeout triggered, otherwise it was user cancellation
        return runtime.checkTimeout(&timeout, err);
    };

    // If timeout fired, we should have received error.Canceled from yield
    std.debug.assert(!timeout.triggered);
}

/// Remove a wait node from the queue for a given address.
fn removeFromQueue(table: *Table, ptr: *const u32, node: *WaitNode) void {
    table.mutex.lock();
    defer table.mutex.unlock();

    if (table.map.getPtr(ptr)) |queue| {
        _ = queue.remove(node);
        // Clean up empty queue
        if (queue.isEmpty()) {
            _ = table.map.remove(ptr);
        }
    }
}

/// Unblocks at most `max_waiters` callers blocked in a `wait()` call on `ptr`.
pub fn wake(runtime: *Runtime, ptr: *const u32, max_waiters: u32) void {
    if (max_waiters == 0) return;

    const table = &runtime.futex_table;

    // Collect nodes to wake under lock
    var to_wake: [32]*WaitNode = undefined;
    var count: u32 = 0;

    table.mutex.lock();

    if (table.map.getPtr(ptr)) |queue| {
        while (count < max_waiters and count < 32) {
            if (queue.pop()) |node| {
                to_wake[count] = node;
                count += 1;
            } else {
                break;
            }
        }
        // Clean up empty queue entry
        if (queue.isEmpty()) {
            _ = table.map.remove(ptr);
        }
    }

    table.mutex.unlock();

    // Wake outside lock to avoid holding lock during resume
    for (to_wake[0..count]) |node| {
        node.wake();
    }
}

// Tests
const testing = std.testing;

test "Futex basic wait/wake" {
    const rt = try Runtime.init(testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 0;

    const Waiter = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            // Wait for value to change from 0
            try Futex.wait(runtime, v, 0);
            // Value should now be 1
            try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, v, .acquire));
        }
    };

    const Waker = struct {
        fn run(runtime: *Runtime, v: *u32) !void {
            // Change value and wake
            @atomicStore(u32, v, 1, .release);
            Futex.wake(runtime, v, 1);
        }
    };

    var waiter = try rt.spawn(Waiter.run, .{ rt, &value }, .{});
    defer waiter.cancel(rt);

    var waker = try rt.spawn(Waker.run, .{ rt, &value }, .{});
    defer waker.cancel(rt);

    try rt.run();
}

test "Futex spurious wakeup - value already changed" {
    const rt = try Runtime.init(testing.allocator, .{});
    defer rt.deinit();

    var value: u32 = 1; // Already != 0

    // Should return immediately since value != expect
    try Futex.wait(rt, &value, 0);
}
