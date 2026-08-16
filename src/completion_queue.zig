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
//! defer cq.cancelAll(.discard);
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
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;
const Runtime = @import("runtime.zig").Runtime;
const getCurrentExecutor = @import("runtime.zig").getCurrentExecutor;

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

    const GroupNode = @FieldType(Completion, "group");
    const Queue = SimpleQueue(GroupNode);

    pub fn init() CompletionQueue {
        return .{
            .mutex = .init(),
            .pending = .empty,
            .completed = .empty,
            .waiter = Waiter.init(),
        };
    }

    /// Get the Completion that owns a group node.
    inline fn completionFromGroup(node: *GroupNode) *Completion {
        return @fieldParentPtr("group", node);
    }

    /// Submit a completion to the queue and event loop.
    ///
    /// A completion that this queue has already handed back may be submitted
    /// again; the loop re-arms it. Ownership is sticky, so one that belongs to
    /// a group or to another queue must be re-initialised first.
    pub fn submit(self: *CompletionQueue, c: *Completion) void {
        std.debug.assert(c.group.owner == null or c.group.owner == @as(*anyopaque, @ptrCast(self))); // owned elsewhere
        std.debug.assert(!c.flags.rearm); // the loop re-adds these itself, behind the queue's back
        c.group.owner = self;
        c.group.owner_callback = &ownerCallback;

        self.mutex.lock();
        self.pending.push(&c.group);
        self.mutex.unlock();

        getCurrentExecutor().loopAdd(c);
    }

    /// Reset the signal counter before checking the completed queue.
    /// This must be called BEFORE checking the completed queue to avoid
    /// a race where a signal is lost between checking and waiting.
    fn resetSignals(self: *CompletionQueue) void {
        self.waiter.mode.direct.notify.state.store(0, .monotonic);
    }

    /// Wait for the next completion. Blocks until one is available.
    /// Returns null when there are no more pending or completed operations.
    pub fn wait(self: *CompletionQueue) Cancelable!?*Completion {
        while (true) {
            self.resetSignals();

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

            self.waiter.wait(1, .allow_cancel) catch |err| switch (err) {
                error.Canceled => {
                    self.cancelAll(.discard);
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
            self.resetSignals();

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

            const timed_out = if (self.waiter.timedWait(1, timeout, .allow_cancel)) |_| false else |err| switch (err) {
                error.Canceled => {
                    self.cancelAll(.discard);
                    return error.Canceled;
                },
                error.Timeout => true,
            };

            // A completion can still have landed together with the timeout.
            self.mutex.lock();
            const node = self.completed.pop();
            self.mutex.unlock();

            if (node) |n| {
                return completionFromGroup(n);
            }

            if (timed_out) {
                return error.Timeout;
            }

            // Signaled without a completion to hand out (a pending op finished
            // into the queue and was taken, or the signal raced the pop): go
            // around rather than reporting a timeout that did not happen.
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

    /// What `cancelAll` does with the results of the operations it waited for.
    pub const Results = enum {
        /// Leave them in the queue, to be taken with `wait` or `next`. An
        /// operation that completed before its cancellation landed is in
        /// there too, carrying a real result rather than `error.Canceled`.
        keep,
        /// Drop them, leaving the queue empty. This also drops results that
        /// were already waiting to be taken.
        discard,
    };

    /// Take `c` out of the queue, whatever state it is in, blocking until that
    /// is safe. It will not be handed out by `wait` or `next` afterwards: a
    /// completion leaves the queue exactly once, and for this one the caller
    /// already holds it. Inspect it directly once this returns.
    ///
    /// Still pending: its cancellation is requested and this waits for it to
    /// finish. A cancel that lost the race leaves a real result behind, so read
    /// the operation's own `getResult` rather than assuming `error.Canceled`.
    ///
    /// Like `wait`, this belongs to the task that drives the queue, and its
    /// wait cannot itself be canceled.
    pub fn cancel(self: *CompletionQueue, c: *Completion) void {
        self.mutex.lock();
        if (unlink(&self.completed, &c.group)) {
            // Finished already, just not taken yet. Nothing to cancel.
            self.mutex.unlock();
            return;
        }
        const was_pending = contains(&self.pending, &c.group);
        self.mutex.unlock();

        if (!was_pending) {
            // Handed out by `wait` already, or never submitted here. Either way
            // the caller holds a finished completion; a live one would mean it
            // belongs to some other queue or group.
            std.debug.assert(c.loadState().phase == .dead);
            return;
        }

        getCurrentExecutor().loopCancel(c);

        while (true) {
            self.resetSignals();

            self.mutex.lock();
            const taken = unlink(&self.completed, &c.group);
            self.mutex.unlock();

            if (taken) return;

            // Under the lock the node is in exactly one of the two queues, so
            // not being in `completed` means it is still pending.
            self.waiter.wait(1, .no_cancel);
        }
    }

    /// Cancel every pending operation and wait for all of them to finish.
    /// `results` says what happens to what they returned.
    ///
    /// Safe to call more than once, and safe with nothing pending. Like `wait`,
    /// this belongs to the task that drives the queue, and its wait cannot
    /// itself be canceled.
    pub fn cancelAll(self: *CompletionQueue, results: Results) void {
        self.requestCancelAll();
        self.drainPending(results);
    }

    /// Whether `node` is in `queue`. The caller holds the mutex.
    ///
    /// `SimpleQueue.remove` is not a membership test: a node sitting in the
    /// middle of the *other* queue satisfies both of its validation checks and
    /// gets spliced out of that one instead.
    fn contains(queue: *Queue, node: *GroupNode) bool {
        var it = queue.head;
        while (it) |n| : (it = n.next) {
            if (n == node) return true;
        }
        return false;
    }

    /// Remove `node` from `queue` if it is in it. The caller holds the mutex.
    fn unlink(queue: *Queue, node: *GroupNode) bool {
        if (!contains(queue, node)) return false;
        const removed = queue.remove(node);
        std.debug.assert(removed);
        return true;
    }

    fn requestCancelAll(self: *CompletionQueue) void {
        self.mutex.lock();
        var node = self.pending.head;
        self.mutex.unlock();

        // Cancel each pending operation. We don't hold the lock while calling
        // loop.cancel() because the callback needs to acquire it.
        const executor = getCurrentExecutor();
        while (node) |n| {
            const next_node = n.next;
            const c = completionFromGroup(n);
            executor.loopCancel(c);
            node = next_node;
        }
    }

    fn drainPending(self: *CompletionQueue, results: Results) void {
        while (true) {
            self.resetSignals();

            self.mutex.lock();
            const pending_empty = self.pending.isEmpty();
            // Read `pending` first: once it is empty every result is in
            // `completed`, so this pass drops all of them.
            if (results == .discard) {
                while (self.completed.pop()) |_| {}
            }
            self.mutex.unlock();

            if (pending_empty) break;

            self.waiter.wait(1, .no_cancel);
        }
    }

    fn ownerCallback(_: *ev.Loop, c: *Completion) void {
        const self: *CompletionQueue = @ptrCast(@alignCast(c.group.owner.?));

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

test "CompletionQueue: wait then timedWait does not false-timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    // First: submit and wait() — pops without blocking, consuming a signal
    var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    cq.submit(&timer1.c);
    const c1 = try cq.wait();
    try std.testing.expectEqual(&timer1.c, c1.?);

    // Second: submit and timedWait() — must not return false Timeout
    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    cq.submit(&timer2.c);
    const c2 = try cq.timedWait(.{ .duration = .fromSeconds(1) });
    try std.testing.expectEqual(&timer2.c, c2.?);
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
    cq.cancelAll(.discard);
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
    cq.cancelAll(.discard);

    // Queue should be empty after cancel
    const result = try cq.wait();
    try std.testing.expectEqual(null, result);
}

test "CompletionQueue: a finished completion can be submitted again (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    cq.submit(&timer.c);

    const first = try cq.wait();
    try std.testing.expectEqual(&timer.c, first.?);

    // Dead completion, re-armed. `Loop.add` used to clear the whole `group`
    // sub-struct here, unlinking the node from `pending` the instant after
    // `submit` pushed it and dropping the callback that reports completion.
    cq.submit(&timer.c);
    try std.testing.expect(cq.hasPending());

    const second = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&timer.c, second.?);
    try std.testing.expectEqual(null, try cq.wait());
}

test "CompletionQueue: re-submitting the completion that fired leaves the others armed (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var fast = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var slow = ev.Timer.init(.{ .duration = .fromMilliseconds(150) });
    cq.submit(&fast.c);
    cq.submit(&slow.c);

    const first = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&fast.c, first.?);

    cq.submit(&fast.c);

    // Both must come back: the re-armed one, and the one that stayed armed
    // across the re-submission. Which lands first is a wall-clock question and
    // not what this pins, so take them in either order. A lost queue link
    // shows up as `error.Timeout` here rather than as a test that hangs.
    const second = try cq.timedWait(.fromSeconds(5));
    const third = try cq.timedWait(.fromSeconds(5));
    try std.testing.expect(
        (second.? == &fast.c and third.? == &slow.c) or
            (second.? == &slow.c and third.? == &fast.c),
    );
    try std.testing.expectEqual(null, try cq.wait());
}

test "CompletionQueue: a notify that lands while an Async is unarmed is not lost (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var mailbox = ev.Async.init();
    cq.submit(&mailbox.c);
    mailbox.notify();
    const first = try cq.wait();
    try std.testing.expectEqual(&mailbox.c, first.?);

    // The handle is unarmed now. `notify` latches on the handle itself, and
    // the re-submit below picks the latch up through `Loop.add`. Handing the
    // same completion back is what makes this lossless: re-initialising the
    // handle here would zero the latch and drop this notify.
    mailbox.notify();
    cq.submit(&mailbox.c);

    const second = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&mailbox.c, second.?);
}

test "CompletionQueue: cancel takes one operation out and leaves the rest armed" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var head = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var doomed = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var tail = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var keeper = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    cq.submit(&head.c);
    cq.submit(&doomed.c);
    cq.submit(&tail.c);
    cq.submit(&keeper.c);

    // Let `keeper` finish, so the cancel below has to find `doomed` in the
    // middle of a non-empty `pending` while `completed` is non-empty too.
    // `SimpleQueue.remove` would accept it as a member of either list.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(80) });
    try common.waitForIo(&pause.c);
    try std.testing.expect(cq.hasCompleted());

    cq.cancel(&doomed.c);
    try std.testing.expectError(error.Canceled, doomed.getResult());

    // `doomed` is out of the queue; everything else is where it was.
    const c = try cq.wait();
    try std.testing.expectEqual(&keeper.c, c.?);
    try keeper.getResult();
    try std.testing.expect(cq.hasPending());

    cq.cancelAll(.discard);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: cancel of an operation that already finished keeps its result" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var first = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var middle = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    var last = ev.Timer.init(.{ .duration = .fromMilliseconds(15) });
    cq.submit(&first.c);
    cq.submit(&middle.c);
    cq.submit(&last.c);

    // Let all three finish into `completed` without taking any of them.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(80) });
    try common.waitForIo(&pause.c);
    try std.testing.expect(!cq.hasPending());

    // Nothing to cancel: it is unlinked and handed to the caller as it stands.
    // Taking one from the middle of the list is what stops `remove` from being
    // usable as the membership test.
    cq.cancel(&middle.c);
    try middle.getResult();

    const a = try cq.wait();
    try std.testing.expectEqual(&first.c, a.?);
    const b = try cq.wait();
    try std.testing.expectEqual(&last.c, b.?);
    try std.testing.expectEqual(null, try cq.wait());
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: cancel of an operation the queue already handed out" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    cq.submit(&timer.c);
    const c = try cq.wait();
    try std.testing.expectEqual(&timer.c, c.?);

    // In neither queue any more: a no-op rather than a broken list walk.
    cq.cancel(&timer.c);
    try timer.getResult();
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: cancelAll(.keep) hands back what the operations returned" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var slow: [3]ev.Timer = @splat(ev.Timer.init(.{ .duration = .fromSeconds(10) }));
    for (&slow) |*t| cq.submit(&t.c);

    cq.cancelAll(.keep);
    try std.testing.expect(!cq.hasPending());

    var seen: usize = 0;
    while (try cq.wait()) |c| : (seen += 1) {
        try std.testing.expectError(error.Canceled, c.cast(ev.Timer).getResult());
    }
    try std.testing.expectEqual(3, seen);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: cancelAll(.discard) leaves the queue empty" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var slow = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var done = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    cq.submit(&slow.c);
    cq.submit(&done.c);

    // Let the short one finish so a result is sitting in `completed` too.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(80) });
    try common.waitForIo(&pause.c);
    try std.testing.expect(cq.hasCompleted());

    cq.cancelAll(.discard);
    try std.testing.expect(cq.isEmpty());
    try std.testing.expectEqual(null, try cq.wait());

    // Calling it again with nothing left is fine.
    cq.cancelAll(.discard);
}
