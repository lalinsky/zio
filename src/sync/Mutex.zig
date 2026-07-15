// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A mutual exclusion primitive for protecting shared data in async contexts.
//!
//! The lock is not handed off: woken waiters compete with running tasks for
//! the lock (barging), which avoids serializing every transfer behind the
//! scheduler. Tasks park in the mutex's own wait queue; foreign threads wait
//! directly on the state word with a futex, so waking them needs no per-waiter
//! bookkeeping.
//!
//! Lock operations are cancelable. If a task is cancelled while waiting
//! for a mutex, it will properly handle cleanup and propagate the error.
//!
//! ## Example
//!
//! ```zig
//! var mutex: zio.Mutex = .init;
//! var shared_data: u32 = 0;
//!
//! try mutex.lock();
//! defer mutex.unlock();
//!
//! shared_data += 1;
//! ```

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const getCurrentTaskOrNull = @import("../runtime.zig").getCurrentTaskOrNull;
const Group = @import("../group.zig").Group;
const Cancelable = @import("../common.zig").Cancelable;
const WaitNode = @import("../utils/wait_queue.zig").WaitNode;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const Waiter = @import("../common.zig").Waiter;
const os = @import("../os/root.zig");

const Mutex = @This();

pub const Recursive = @import("Mutex/Recursive.zig");

const unlocked: u32 = 0;
const locked: u32 = 1;
/// Set only by contended foreign threads; tasks are visible via the queue.
const thread_contended: u32 = 2;

const thread_futex = os.thread.Futex;
const has_thread_futex = thread_futex != void;

state: std.atomic.Value(u32) = .init(unlocked),
/// Task waiters. Foreign threads wait on `state` itself.
queue: WaitQueue(WaitNode) = .empty,

/// Creates a new unlocked mutex.
pub const init: Mutex = .{};

/// Attempts to acquire the mutex without blocking.
/// Returns `true` if the lock was successfully acquired, `false` if the mutex
/// is already locked by another coroutine.
/// This function will never suspend the current task. If you need blocking behavior, use `lock()` instead.
pub fn tryLock(self: *Mutex) bool {
    return self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
}

/// Acquires the mutex, blocking if it is already locked.
///
/// This function must be called from within a coroutine context managed by
/// the zio runtime, or from a foreign thread.
///
/// Returns `error.Canceled` if the task is cancelled while waiting for the lock.
pub fn lock(self: *Mutex) Cancelable!void {
    if (self.tryLock()) return;
    if (has_thread_futex and getCurrentTaskOrNull() == null) {
        return self.lockThread();
    }
    return self.lockSlow(.allow_cancel);
}

/// Acquires the mutex, ignoring cancellation.
///
/// Like `lock()`, but cancellation requests are ignored during the lock
/// acquisition. This always acquires the lock and never returns an error.
///
/// If you need to propagate cancellation after acquiring the lock, call
/// `Runtime.checkCancel()` after this function returns.
pub fn lockUncancelable(self: *Mutex) void {
    if (self.tryLock()) return;
    if (has_thread_futex and getCurrentTaskOrNull() == null) {
        return self.lockThread();
    }
    self.lockSlow(.no_cancel);
}

/// Releases the mutex.
///
/// If there are waiters, one of each class is woken and competes for the
/// lock with anyone arriving on the fast path.
///
/// It is undefined behavior if the current coroutine does not hold the lock.
pub fn unlock(self: *Mutex) void {
    const prev = self.state.swap(unlocked, .seq_cst);
    std.debug.assert(prev != unlocked);
    if (has_thread_futex and prev == thread_contended) {
        thread_futex.wake(&self.state, .one);
    }
    if (self.queue.hasWaiters()) {
        if (self.queue.pop()) |node| Waiter.fromNode(node).signal();
    }
}

fn lockThread(self: *Mutex) void {
    while (self.state.swap(thread_contended, .acquire) != unlocked) {
        thread_futex.wait(&self.state, thread_contended);
    }
}

fn lockSlow(self: *Mutex, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
    while (true) {
        var waiter: Waiter = .init();
        self.queue.push(&waiter.node);

        // Recheck after publishing the node, so an unlock that scanned an
        // empty queue is caught here. The RMW makes the push totally ordered
        // with unlock's swap; a plain failed CAS would only be a load.
        if (self.state.fetchAdd(0, .seq_cst) == unlocked and
            self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null)
        {
            if (!self.queue.remove(&waiter.node)) {
                // Popped by an unlock; its signal is in flight, consume it.
                waiter.wait(1, .no_cancel);
            }
            return;
        }

        if (cancel_mode == .allow_cancel) {
            waiter.wait(1, .allow_cancel) catch |err| {
                if (!self.queue.remove(&waiter.node)) {
                    waiter.wait(1, .no_cancel);
                    // The wake was meant for a competitor; pass it on.
                    if (self.queue.pop()) |node| Waiter.fromNode(node).signal();
                }
                return err;
            };
        } else {
            waiter.wait(1, .no_cancel);
        }

        // Woken: compete like everyone else.
        if (self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null) return;
    }
}

test "Mutex basic lock/unlock" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var shared_counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(counter: *u32, mtx: *Mutex) !void {
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

test "Mutex tryLock" {
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();

    var mutex = Mutex.init;

    try std.testing.expect(mutex.tryLock()); // Should succeed
    try std.testing.expect(!mutex.tryLock()); // Should fail (already locked)
    mutex.unlock();
    try std.testing.expect(mutex.tryLock()); // Should succeed again
    mutex.unlock();
}

test "Mutex contention" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer runtime.deinit();

    var counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(ctr: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
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

test "Mutex foreign threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn worker(ctr: *u32, mtx: *Mutex) void {
            for (0..100) |_| {
                mtx.lockUncancelable();
                defer mtx.unlock();
                ctr.* += 1;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, TestFn.worker, .{ &counter, &mutex });
    for (threads) |t| t.join();

    try std.testing.expectEqual(400, counter);
}

test "Mutex mixed tasks and threads" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var counter: u32 = 0;
    var mutex = Mutex.init;

    const TestFn = struct {
        fn taskWorker(ctr: *u32, mtx: *Mutex) !void {
            for (0..100) |_| {
                try mtx.lock();
                defer mtx.unlock();
                ctr.* += 1;
            }
        }
        fn threadWorker(ctr: *u32, mtx: *Mutex) void {
            for (0..100) |_| {
                mtx.lockUncancelable();
                defer mtx.unlock();
                ctr.* += 1;
            }
        }
    };

    var thread = try std.Thread.spawn(.{}, TestFn.threadWorker, .{ &counter, &mutex });

    var group: Group = .init;
    defer group.cancel();
    try group.spawn(TestFn.taskWorker, .{ &counter, &mutex });
    try group.spawn(TestFn.taskWorker, .{ &counter, &mutex });
    try group.wait();

    thread.join();

    try std.testing.expectEqual(300, counter);
}

test "Mutex cancellation while parked under churn" {
    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    var mutex = Mutex.init;
    var stop = std.atomic.Value(bool).init(false);
    var churned: u64 = 0;

    const TestFn = struct {
        fn churner(mtx: *Mutex, stop_flag: *std.atomic.Value(bool), n: *u64) !void {
            while (!stop_flag.load(.monotonic)) {
                try mtx.lock();
                n.* += 1;
                mtx.unlock();
            }
        }
        fn victim(mtx: *Mutex) !void {
            // Parks over and over so cancellation keeps racing unlock's pop.
            while (true) {
                try mtx.lock();
                mtx.unlock();
            }
        }
    };

    var churners: Group = .init;
    defer churners.cancel();
    for (0..2) |_| try churners.spawn(TestFn.churner, .{ &mutex, &stop, &churned });

    var victims: Group = .init;
    for (0..8) |_| try victims.spawn(TestFn.victim, .{&mutex});

    os.time.sleep(.fromMilliseconds(50));
    victims.cancel();

    stop.store(true, .monotonic);
    try churners.wait();
    try std.testing.expect(!churners.hasFailed());

    // The lock must still work after all the canceled waiters left.
    try mutex.lock();
    mutex.unlock();
    try std.testing.expect(churned > 0);
}
