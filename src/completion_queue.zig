// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A queue for waiting on multiple I/O operations with an iterator-like interface.
//!
//! Unlike `waitForIo` (single operation) or `ev.Group` (combine into one virtual completion),
//! `CompletionQueue` lets you submit multiple operations, dynamically add more, and process
//! completions one at a time as they finish.
//!
//! Runtime-only: must be used from within an async task context.
//!
//! Usage:
//! ```zig
//! var cq = CompletionQueue.init();
//!
//! var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(100) });
//! var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(200) });
//! cq.submit(&timer1.c);
//! cq.submit(&timer2.c);
//!
//! while (try cq.wait()) |c| {
//!     // Process completion
//!     // Can submit more operations here
//! }
//! ```

const std = @import("std");

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const common = @import("common.zig");
const SimpleWaitQueue = @import("utils/wait_queue.zig").SimpleWaitQueue;
const Runtime = @import("runtime.zig").Runtime;

const Waiter = common.Waiter;
const Cancelable = common.Cancelable;
const Timeoutable = common.Timeoutable;
const Timeout = @import("time.zig").Timeout;
const Completion = ev.Completion;

pub const CompletionQueue = struct {
    mutex: os.Mutex,
    pending: Queue,
    completed: Queue,
    waiter: Waiter,
    expected_signals: u32,

    const GroupNode = @FieldType(Completion, "group");
    const Queue = SimpleWaitQueue(GroupNode);

    pub fn init() CompletionQueue {
        return .{
            .mutex = .init(),
            .pending = .empty,
            .completed = .empty,
            .waiter = Waiter.init(),
            .expected_signals = 0,
        };
    }

    fn getLoop(self: *CompletionQueue) *ev.Loop {
        return &self.waiter.task.?.getExecutor().loop;
    }

    /// Get the Completion that owns a group node.
    inline fn completionFromGroup(node: *GroupNode) *Completion {
        return @fieldParentPtr("group", node);
    }

    /// Submit a completion to the queue and event loop.
    pub fn submit(self: *CompletionQueue, c: *Completion) void {
        c.userdata = self;
        c.callback = completionCallback;

        self.mutex.lock();
        self.pending.push(&c.group);
        self.mutex.unlock();

        self.getLoop().add(c);
    }

    /// Wait for the next completion. Blocks until one is available.
    /// Returns null when there are no more pending or completed operations.
    pub fn wait(self: *CompletionQueue) Cancelable!?*Completion {
        while (true) {
            self.mutex.lock();
            const completed_node = self.completed.pop();
            const pending_empty = self.pending.isEmpty();
            self.mutex.unlock();

            if (completed_node) |node| {
                return completionFromGroup(node);
            }

            if (pending_empty) {
                return null;
            }

            self.expected_signals += 1;
            self.waiter.wait(self.expected_signals, .allow_cancel) catch |err| switch (err) {
                error.Canceled => {
                    self.cancelAll();
                    self.drainPending();
                    return error.Canceled;
                },
            };
        }
    }

    /// Wait for the next completion with a timeout.
    /// Returns `error.Timeout` if no completion is ready before the timeout expires.
    /// Returns null when there are no more pending or completed operations.
    pub fn timedWait(self: *CompletionQueue, timeout: Timeout) (Timeoutable || Cancelable)!?*Completion {
        if (timeout == .none) {
            return self.wait();
        }

        while (true) {
            self.mutex.lock();
            const completed_node = self.completed.pop();
            const pending_empty = self.pending.isEmpty();
            self.mutex.unlock();

            if (completed_node) |node| {
                return completionFromGroup(node);
            }

            if (pending_empty) {
                return null;
            }

            self.expected_signals += 1;
            self.waiter.timedWait(self.expected_signals, timeout, .allow_cancel) catch |err| switch (err) {
                error.Canceled => {
                    self.cancelAll();
                    self.drainPending();
                    return error.Canceled;
                },
            };

            // Check if we got a completion or timed out
            self.mutex.lock();
            const node = self.completed.pop();
            self.mutex.unlock();

            if (node) |n| {
                return completionFromGroup(n);
            }

            return error.Timeout;
        }
    }

    /// Returns true if there are no pending or completed operations.
    pub fn isEmpty(self: *CompletionQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending.isEmpty() and self.completed.isEmpty();
    }

    /// Returns true if there are operations still in flight.
    pub fn hasPending(self: *CompletionQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.pending.isEmpty();
    }

    /// Returns true if there are completed operations ready to be consumed.
    pub fn hasCompleted(self: *CompletionQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.completed.isEmpty();
    }

    /// Non-blocking poll for the next completed operation.
    /// Returns null if no completions are ready yet.
    pub fn next(self: *CompletionQueue) ?*Completion {
        self.mutex.lock();
        const node = self.completed.pop();
        self.mutex.unlock();

        if (node) |n| {
            return completionFromGroup(n);
        }
        return null;
    }

    /// Cancel all pending operations and wait for them to complete.
    pub fn cancel(self: *CompletionQueue) void {
        self.cancelAll();
        self.drainPending();
    }

    fn cancelAll(self: *CompletionQueue) void {
        self.mutex.lock();
        var node = self.pending.head;
        self.mutex.unlock();

        // Cancel each pending operation. We don't hold the lock while calling
        // loop.cancel() because the callback needs to acquire it.
        while (node) |n| {
            const next_node = n.next;
            const c = completionFromGroup(n);
            self.getLoop().cancel(c);
            node = next_node;
        }
    }

    fn drainPending(self: *CompletionQueue) void {
        while (true) {
            self.mutex.lock();
            const pending_empty = self.pending.isEmpty();
            self.mutex.unlock();

            if (pending_empty) break;

            self.expected_signals += 1;
            self.waiter.wait(self.expected_signals, .no_cancel);
        }

        // Discard any completed items
        self.mutex.lock();
        while (self.completed.pop()) |_| {}
        self.mutex.unlock();
    }

    fn completionCallback(_: *ev.Loop, c: *Completion) void {
        const self: *CompletionQueue = @ptrCast(@alignCast(c.userdata.?));

        self.mutex.lock();
        const removed = self.pending.remove(&c.group);
        std.debug.assert(removed);
        self.completed.push(&c.group);
        self.mutex.unlock();

        self.waiter.signal();
    }
};

test "CompletionQueue: wait on empty queue returns null" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    try std.testing.expect(cq.isEmpty());
    try std.testing.expect(!cq.hasPending());
    try std.testing.expect(!cq.hasCompleted());

    const result = try cq.wait();
    try std.testing.expectEqual(null, result);
}

test "CompletionQueue: single timer" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    cq.submit(&timer.c);

    try std.testing.expect(!cq.isEmpty());
    try std.testing.expect(cq.hasPending());

    const c = try cq.wait();
    try std.testing.expect(c != null);
    try std.testing.expectEqual(&timer.c, c.?);

    // Queue is now empty
    try std.testing.expect(cq.isEmpty());
    try std.testing.expect(!cq.hasPending());
    try std.testing.expect(!cq.hasCompleted());

    const end = try cq.wait();
    try std.testing.expectEqual(null, end);
}

test "CompletionQueue: multiple timers" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(20) });
    var timer3 = ev.Timer.init(.{ .duration = .fromMilliseconds(30) });
    cq.submit(&timer1.c);
    cq.submit(&timer2.c);
    cq.submit(&timer3.c);

    var count: u32 = 0;
    while (try cq.wait()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(3, count);
}

test "CompletionQueue: dynamic submit during iteration" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    cq.submit(&timer1.c);

    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    var submitted_second = false;

    var count: u32 = 0;
    while (try cq.wait()) |_| {
        count += 1;
        if (!submitted_second) {
            cq.submit(&timer2.c);
            submitted_second = true;
        }
    }
    try std.testing.expectEqual(2, count);
}

test "CompletionQueue: timedWait completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    cq.submit(&timer.c);

    const c = try cq.timedWait(.{ .duration = .fromSeconds(1) });
    try std.testing.expect(c != null);
    try std.testing.expectEqual(&timer.c, c.?);
}

test "CompletionQueue: timedWait returns timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    // Long timer with short timeout
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    cq.submit(&timer.c);

    try std.testing.expectError(error.Timeout, cq.timedWait(.fromMilliseconds(10)));

    // Clean up
    cq.cancel();
}

test "CompletionQueue: timedWait on empty queue returns null" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    const result = try cq.timedWait(.fromMilliseconds(10));
    try std.testing.expectEqual(null, result);
}

test "CompletionQueue: cancel pending operations" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    // Submit a long timer
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    cq.submit(&timer.c);

    // Cancel should complete without waiting 10 seconds
    cq.cancel();

    // Queue should be empty after cancel
    const result = try cq.wait();
    try std.testing.expectEqual(null, result);
}
