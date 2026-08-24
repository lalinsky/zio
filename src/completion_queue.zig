// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! A queue for waiting on multiple I/O operations with an iterator-like interface.
//!
//! Unlike `waitForIo` (single operation) or `ev.Group` (combine into one virtual
//! completion), `CompletionQueue` lets you submit multiple operations, dynamically
//! add more, and process completions one at a time as they finish.
//!
//! Runtime-only: must be used from within an async task context.
//!
//! One task drives the queue: `wait`, `timedWait`, `next`, `cancel` and
//! `cancelAll` belong to it. `submit` and `close` are thread-safe, so other
//! tasks can park their own operations here for the driver to process. An
//! operation submitted from another task must not live in that task's frame:
//! the submitter may unwind before the driver takes the completion, so such
//! operations belong on the heap, with the driver owning their results and
//! memory. Heap-backed operations rule out `cancelAll(.discard)` — it drops
//! the only pointers to them — so shut such a queue down with
//! `cancelAll(.keep)` and free each operation as `next` hands it out.
//!
//! Waiting for a batch to finish (the driver submits everything itself):
//! ```zig
//! var cq = CompletionQueue.init();
//! defer cq.cancelAll(.discard);
//!
//! var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(100) });
//! var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(200) });
//! try cq.submit(&timer1.c);
//! try cq.submit(&timer2.c);
//!
//! while (!cq.isEmpty()) {
//!     const c = try cq.wait();
//!     // Process completion; can submit more operations here
//! }
//! ```
//!
//! Long-lived dispatcher (operations submitted by other tasks):
//! ```zig
//! while (true) {
//!     const c = cq.wait() catch |err| switch (err) {
//!         // Closed and fully drained.
//!         error.Closed => break,
//!         // The queue is closed and every operation is canceled with its
//!         // result kept; drain with `next` before freeing them.
//!         error.Canceled => return err,
//!     };
//!     // Process completion
//! }
//! ```
//!
//! The queue also implements the future protocol, so the driver can wait for
//! the next completion alongside other futures:
//! `select(.{ .io = &cq, .msg = ch.asyncReceive() })`. The winning result is
//! what `wait` would have returned, with one difference: canceling a select
//! only stops the waiting, it does not close the queue or cancel the
//! operations in it.

const std = @import("std");

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const common = @import("common.zig");
const Futex = @import("sync/Futex.zig");
const SimpleQueue = @import("utils/simple_queue.zig").SimpleQueue;
const Runtime = @import("runtime.zig").Runtime;
const getCurrentExecutor = @import("runtime.zig").getCurrentExecutor;

const Cancelable = common.Cancelable;
const Timeoutable = common.Timeoutable;
const Closeable = common.Closeable;
const Waiter = common.Waiter;
const Timeout = @import("time.zig").Timeout;
const Completion = ev.Completion;

pub const CompletionQueue = struct {
    mutex: os.Mutex,
    pending: Queue,
    completed: Queue,
    /// Futex word the driver waits on. Counts completion arrivals and a close
    /// with nothing in flight (a close over in-flight operations stays silent,
    /// each of them wakes the driver on its own way to `completed`). Never
    /// reset: waiters snapshot it before checking the queues, so a push
    /// landing between the check and the wait flips the word and the wait
    /// returns immediately. The future protocol depends on the strict reading
    /// of a wake: a completion is takeable, or the queue is drained.
    signal: std.atomic.Value(u32),
    /// No new submissions. Written under `mutex`.
    closed: bool,

    const GroupNode = @FieldType(Completion, "group");
    const Queue = SimpleQueue(GroupNode);

    pub fn init() CompletionQueue {
        return .{
            .mutex = .init(),
            .pending = .empty,
            .completed = .empty,
            .signal = .init(0),
            .closed = false,
        };
    }

    /// Get the Completion that owns a group node.
    inline fn completionFromGroup(node: *GroupNode) *Completion {
        return @fieldParentPtr("group", node);
    }

    pub const SubmitError = Closeable || error{
        /// The queue cannot own this completion: it belongs to a group or to
        /// another queue (ownership is sticky, re-initialise it first), or it
        /// is a rearm completion, which the loop re-adds itself, behind the
        /// queue's back.
        InvalidCompletion,
    };

    /// Submit a completion to the queue and event loop. Thread-safe: any task
    /// may submit, and the operation is added to the submitter's own loop.
    ///
    /// A completion that this queue has already handed back may be submitted
    /// again; the loop re-arms it.
    ///
    /// Returns `error.Closed` once the queue is closed. A refused completion
    /// is left untouched, whatever the error.
    pub fn submit(self: *CompletionQueue, c: *Completion) SubmitError!void {
        if (c.group.owner != null and c.group.owner != @as(*anyopaque, @ptrCast(self))) {
            return error.InvalidCompletion;
        }
        if (c.flags.rearm) {
            return error.InvalidCompletion;
        }

        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return error.Closed;
        }
        c.group.owner = self;
        c.group.owner_callback = &ownerCallback;
        self.pending.push(&c.group);
        self.mutex.unlock();

        getCurrentExecutor().loopAdd(c);
    }

    /// Close the queue: `submit` fails with `error.Closed` from now on, and
    /// the driver's `wait` returns `error.Closed` once everything already in
    /// the queue has been handed out. Operations in flight keep running and
    /// are still delivered; use `cancelAll` to stop them. Thread-safe and
    /// idempotent.
    pub fn close(self: *CompletionQueue) void {
        self.mutex.lock();
        const was_closed = self.closed;
        self.closed = true;
        const pending_empty = self.pending.isEmpty();
        self.mutex.unlock();
        if (was_closed) return;

        // Wake only when this close is what makes the queue drained: a driver
        // parked over in-flight operations has nothing new to see, and each of
        // those operations wakes it through `ownerCallback` later.
        if (pending_empty) {
            _ = self.signal.fetchAdd(1, .release);
            Futex.wake(&self.signal.raw, 1);
        }
    }

    /// Wait for the next completion. Blocks while the queue is open, even if
    /// it is momentarily empty: operations submitted later (also by other
    /// tasks) satisfy a wait already in progress. To wait only for what is
    /// already in the queue, guard with `isEmpty`:
    /// `while (!cq.isEmpty()) { const c = try cq.wait(); ... }`
    ///
    /// Returns `error.Closed` when the queue is closed and fully drained.
    ///
    /// On cancellation the queue is closed and every operation is canceled
    /// with its result kept: drain with `next` (nothing blocks at that point)
    /// before freeing the operations.
    pub fn wait(self: *CompletionQueue) (Cancelable || Closeable)!*Completion {
        while (true) {
            const seen = self.signal.load(.acquire);

            self.mutex.lock();
            const node = self.completed.pop();
            const drained = node == null and self.closed and self.pending.isEmpty();
            self.mutex.unlock();

            if (node) |n| return completionFromGroup(n);
            if (drained) return error.Closed;

            // A bare submit does not bump `signal`: a driver parked here is
            // waiting for a completion, and the submitted operation delivers
            // one through `ownerCallback` when it finishes.
            Futex.wait(&self.signal.raw, seen) catch |err| switch (err) {
                error.Canceled => {
                    self.closeAndKeepResults();
                    return error.Canceled;
                },
            };
        }
    }

    /// Wait for the next completion with a timeout. Blocks like `wait` while
    /// the queue is open and returns `error.Timeout` if no completion is
    /// ready before the timeout expires.
    ///
    /// Returns `error.Closed` when the queue is closed and fully drained.
    pub fn timedWait(self: *CompletionQueue, timeout: Timeout) (Timeoutable || Cancelable || Closeable)!*Completion {
        if (timeout == .none) {
            return self.wait();
        }

        while (true) {
            const seen = self.signal.load(.acquire);

            self.mutex.lock();
            const node = self.completed.pop();
            const drained = node == null and self.closed and self.pending.isEmpty();
            self.mutex.unlock();

            if (node) |n| return completionFromGroup(n);
            if (drained) return error.Closed;

            Futex.timedWait(&self.signal.raw, seen, timeout) catch |err| switch (err) {
                error.Canceled => {
                    self.closeAndKeepResults();
                    return error.Canceled;
                },
                error.Timeout => {
                    // A completion, or the close, can still have landed
                    // together with the timeout; report those rather than a
                    // timeout that did not happen.
                    self.mutex.lock();
                    const n = self.completed.pop();
                    const drained_now = n == null and self.closed and self.pending.isEmpty();
                    self.mutex.unlock();
                    if (n) |x| return completionFromGroup(x);
                    return if (drained_now) error.Closed else error.Timeout;
                },
            };
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

    // Future protocol implementation for use with select() / wait().
    //
    // The registered wait completes when a completion is ready to be taken or
    // the queue is drained; `getResult` then pops one like `next`, or reports
    // `error.Closed`. The single-driver rule applies: a select over the queue
    // is the driver's wait. Canceling the select only deregisters; it does not
    // close the queue or cancel the operations in it the way a canceled
    // `wait()` does, that cleanup is the caller's to do.
    //
    // Registration parks on the same futex word that `ownerCallback` and a
    // drained `close` wake, so the queue needs no waiter storage.

    pub const Result = Closeable!*Completion;

    pub const WaitContext = struct {
        fw: Futex.FutexWaiter = .{},
        registered: bool = false,
        /// A wake was dispatched for a dequeued registration but never
        /// reported to the caller (the arm's claim lost before it could be):
        /// asyncCancelWait must keep reporting it as an in-flight signal so
        /// the caller's cleanup outwaits it.
        pending_signal: bool = false,
    };

    pub fn getResult(self: *CompletionQueue, ctx: *WaitContext) Closeable!*Completion {
        _ = ctx;
        self.mutex.lock();
        const node = self.completed.pop();
        const drained = node == null and self.closed and self.pending.isEmpty();
        self.mutex.unlock();

        if (node) |n| return completionFromGroup(n);
        // A wake on `signal` means a completion was pushed (and only the
        // caller, as the driver, takes completions out) or the queue is
        // drained; a close over in-flight operations stays silent.
        std.debug.assert(drained);
        return error.Closed;
    }

    /// Whether a registered wait would have something to report: a takeable
    /// completion, or the drained state behind `error.Closed`.
    fn isReady(self: *CompletionQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.completed.isEmpty() or (self.closed and self.pending.isEmpty());
    }

    pub fn asyncWait(self: *CompletionQueue, waiter: *Waiter, ctx: *WaitContext) common.AsyncWaitState {
        // Unhook any previous registration so a re-poll never
        // double-registers; one that is already gone was dequeued and
        // signaled without a claim. The signal stays owed (pending_signal)
        // until a return value reports it to the caller.
        const had_signal = ctx.pending_signal or (ctx.registered and !Futex.cancelWait(&ctx.fw));
        ctx.registered = false;
        ctx.pending_signal = had_signal;

        // Fast path: something to report already. Readiness is level state
        // under the single-driver rule (only this task takes completions
        // out), so claiming before the getResult pop cannot go stale.
        if (self.isReady()) {
            return switch (waiter.tryClaim()) {
                .won => blk: {
                    ctx.pending_signal = false;
                    break :blk if (had_signal) .ready_signaled else .ready;
                },
                .busy => unreachable,
                .lost => .decided,
            };
        }

        // Park on the completion futex word.
        Futex.prepareWait(&self.signal.raw, &ctx.fw, waiter);
        ctx.registered = true;

        // Double-check: a completion or the drained close may have landed (and
        // issued its wake) between the fast-path check and the registration.
        if (self.isReady()) {
            // We removed ourselves before any wake -> report readiness now.
            if (Futex.cancelWait(&ctx.fw)) {
                ctx.registered = false;
                return switch (waiter.tryClaim()) {
                    .won => blk: {
                        ctx.pending_signal = false;
                        break :blk if (had_signal) .ready_signaled else .ready;
                    },
                    .busy => unreachable,
                    .lost => .decided,
                };
            }
            // A concurrent wake already dequeued us; the signal (and its
            // claim attempt) is in-flight.
        }

        ctx.pending_signal = false;
        return if (had_signal) .requeued else .queued;
    }

    pub fn asyncCancelWait(self: *CompletionQueue, waiter: *Waiter, ctx: *WaitContext) bool {
        _ = self;
        _ = waiter;
        if (ctx.pending_signal) return false;
        if (!ctx.registered) return true;
        return Futex.cancelWait(&ctx.fw);
    }

    /// What `cancelAll` does with the results of the operations it waited for.
    pub const Results = enum {
        /// Leave them in the queue, to be taken with `wait` or `next`. An
        /// operation that completed before its cancellation landed is in
        /// there too, carrying a real result rather than `error.Canceled`.
        /// The only correct choice when other tasks submitted heap-backed
        /// operations: whoever drains the queue frees them.
        keep,
        /// Drop them, leaving the queue empty. This also drops results that
        /// were already waiting to be taken. Only for operations the caller
        /// still holds by other means (a batch in the driver's own frame).
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
    /// NOT thread-safe, unlike `submit` and `close`: this belongs to the task
    /// that drives the queue and must never run concurrently with `wait`,
    /// `timedWait`, `next` or `cancelAll`. A concurrent consumer could take
    /// the finished `c` out of the queue first, leaving the wait below stuck
    /// forever on a node that already left; the single-driver rule is what
    /// makes that impossible. To cancel a specific operation from another
    /// task, ask the driver instead: park an `ev.Async` doorbell in the queue
    /// and let the driver do the cancel. The wait here cannot itself be
    /// canceled.
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
            const seen = self.signal.load(.acquire);

            self.mutex.lock();
            const taken = unlink(&self.completed, &c.group);
            self.mutex.unlock();

            if (taken) return;

            // Under the lock the node is in exactly one of the two queues, so
            // not being in `completed` means it is still pending.
            Futex.waitUncancelable(&self.signal.raw, seen);
        }
    }

    /// Cancel every pending operation and wait for all of them to finish.
    /// `results` says what happens to what they returned.
    ///
    /// Safe to call more than once, and safe with nothing pending. Like `wait`,
    /// this belongs to the task that drives the queue, and its wait cannot
    /// itself be canceled. Does not close the queue: on an open queue another
    /// task can submit while this drains, extending the wait.
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
        // `ownerCallback` relinks `pending` nodes under the mutex from the
        // loop threads, so walking the list is only safe with the mutex held.
        // `loopCancel` cannot be called with it held (the callback takes it),
        // so each pass walks to one operation that still needs a cancel,
        // drops the lock, and cancels just that one.
        //
        // The walk terminates: `requestCancel` latches `cancel_requested`
        // before `loopCancel` returns (or the operation is already completed
        // or dead), and an operation cannot leave those states while it sits
        // in `pending`, so every pass permanently disqualifies one node.
        const executor = getCurrentExecutor();
        while (true) {
            self.mutex.lock();
            const target: ?*Completion = blk: {
                var node = self.pending.head;
                while (node) |n| : (node = n.next) {
                    const c = completionFromGroup(n);
                    const state = c.loadState();
                    if (state.cancel_requested) continue;
                    // Finished already: `requestCancel` would not latch, only
                    // its dispatch to `completed` is still in flight.
                    if (state.phase == .completed or state.phase == .dead) continue;
                    break :blk c;
                }
                break :blk null;
            };
            self.mutex.unlock();

            executor.loopCancel(target orelse return);
        }
    }

    fn drainPending(self: *CompletionQueue, results: Results) void {
        while (true) {
            const seen = self.signal.load(.acquire);

            self.mutex.lock();
            const pending_empty = self.pending.isEmpty();
            // Read `pending` first: once it is empty every result is in
            // `completed`, so this pass drops all of them.
            if (results == .discard) {
                while (self.completed.pop()) |_| {}
            }
            self.mutex.unlock();

            if (pending_empty) break;

            Futex.waitUncancelable(&self.signal.raw, seen);
        }
    }

    /// Shut the queue down from a canceled wait: no new submissions, every
    /// operation canceled, all results kept in `completed` for `next` to hand
    /// out. Close comes first so no submission can slip in behind the drain
    /// and extend it.
    fn closeAndKeepResults(self: *CompletionQueue) void {
        self.close();
        self.cancelAll(.keep);
    }

    fn ownerCallback(_: *ev.Loop, c: *Completion) void {
        const self: *CompletionQueue = @ptrCast(@alignCast(c.group.owner.?));

        self.mutex.lock();
        const removed = self.pending.remove(&c.group);
        std.debug.assert(removed);
        self.completed.push(&c.group);
        self.mutex.unlock();

        _ = self.signal.fetchAdd(1, .release);
        Futex.wake(&self.signal.raw, 1);
    }
};

test "CompletionQueue: wait on a closed empty queue returns error.Closed" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    try std.testing.expect(cq.isEmpty());
    try std.testing.expect(!cq.hasPending());
    try std.testing.expect(!cq.hasCompleted());

    cq.close();
    try std.testing.expectError(error.Closed, cq.wait());
    try std.testing.expectError(error.Closed, cq.timedWait(.fromMilliseconds(10)));

    // Idempotent.
    cq.close();
    try std.testing.expectError(error.Closed, cq.wait());
}

test "CompletionQueue: single timer" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try cq.submit(&timer.c);

    try std.testing.expect(!cq.isEmpty());
    try std.testing.expect(cq.hasPending());

    const c = try cq.wait();
    try std.testing.expectEqual(&timer.c, c);

    // Queue is now empty
    try std.testing.expect(cq.isEmpty());
    try std.testing.expect(!cq.hasPending());
    try std.testing.expect(!cq.hasCompleted());
}

test "CompletionQueue: multiple timers" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(20) });
    var timer3 = ev.Timer.init(.{ .duration = .fromMilliseconds(30) });
    try cq.submit(&timer1.c);
    try cq.submit(&timer2.c);
    try cq.submit(&timer3.c);

    var count: u32 = 0;
    while (!cq.isEmpty()) {
        _ = try cq.wait();
        count += 1;
    }
    try std.testing.expectEqual(3, count);
}

test "CompletionQueue: dynamic submit during iteration" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer1 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try cq.submit(&timer1.c);

    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    var submitted_second = false;

    var count: u32 = 0;
    while (!cq.isEmpty()) {
        _ = try cq.wait();
        count += 1;
        if (!submitted_second) {
            try cq.submit(&timer2.c);
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
    try cq.submit(&timer1.c);
    const c1 = try cq.wait();
    try std.testing.expectEqual(&timer1.c, c1);

    // Second: submit and timedWait() — must not return false Timeout
    var timer2 = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try cq.submit(&timer2.c);
    const c2 = try cq.timedWait(.{ .duration = .fromSeconds(1) });
    try std.testing.expectEqual(&timer2.c, c2);
}

test "CompletionQueue: timedWait completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try cq.submit(&timer.c);

    const c = try cq.timedWait(.{ .duration = .fromSeconds(1) });
    try std.testing.expectEqual(&timer.c, c);
}

test "CompletionQueue: timedWait returns timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    // Long timer with short timeout
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    try cq.submit(&timer.c);

    try std.testing.expectError(error.Timeout, cq.timedWait(.fromMilliseconds(10)));

    // Clean up
    cq.cancelAll(.discard);
}

test "CompletionQueue: timedWait on an open empty queue waits for the timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // An open queue blocks on empty rather than reporting exhaustion, so
    // with nothing submitted the timeout is the only way out.
    var cq = CompletionQueue.init();
    try std.testing.expectError(error.Timeout, cq.timedWait(.fromMilliseconds(10)));
}

test "CompletionQueue: cancel pending operations" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    // Submit a long timer
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    try cq.submit(&timer.c);

    // Cancel should complete without waiting 10 seconds
    cq.cancelAll(.discard);

    // Queue should be empty after cancel
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: a finished completion can be submitted again (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&timer.c);

    const first = try cq.wait();
    try std.testing.expectEqual(&timer.c, first);

    // Dead completion, re-armed. `Loop.add` used to clear the whole `group`
    // sub-struct here, unlinking the node from `pending` the instant after
    // `submit` pushed it and dropping the callback that reports completion.
    try cq.submit(&timer.c);
    try std.testing.expect(cq.hasPending());

    const second = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&timer.c, second);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: re-submitting the completion that fired leaves the others armed (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var fast = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var slow = ev.Timer.init(.{ .duration = .fromMilliseconds(150) });
    try cq.submit(&fast.c);
    try cq.submit(&slow.c);

    const first = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&fast.c, first);

    try cq.submit(&fast.c);

    // Both must come back: the re-armed one, and the one that stayed armed
    // across the re-submission. Which lands first is a wall-clock question and
    // not what this pins, so take them in either order. A lost queue link
    // shows up as `error.Timeout` here rather than as a test that hangs.
    const second = try cq.timedWait(.fromSeconds(5));
    const third = try cq.timedWait(.fromSeconds(5));
    try std.testing.expect(
        (second == &fast.c and third == &slow.c) or
            (second == &slow.c and third == &fast.c),
    );
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: a notify that lands while an Async is unarmed is not lost (#673)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var mailbox = ev.Async.init();
    try cq.submit(&mailbox.c);
    mailbox.notify();
    const first = try cq.wait();
    try std.testing.expectEqual(&mailbox.c, first);

    // The handle is unarmed now. `notify` latches on the handle itself, and
    // the re-submit below picks the latch up through `Loop.add`. Handing the
    // same completion back is what makes this lossless: re-initialising the
    // handle here would zero the latch and drop this notify.
    mailbox.notify();
    try cq.submit(&mailbox.c);

    const second = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&mailbox.c, second);
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
    try cq.submit(&head.c);
    try cq.submit(&doomed.c);
    try cq.submit(&tail.c);
    try cq.submit(&keeper.c);

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
    try std.testing.expectEqual(&keeper.c, c);
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
    try cq.submit(&first.c);
    try cq.submit(&middle.c);
    try cq.submit(&last.c);

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
    try std.testing.expectEqual(&first.c, a);
    const b = try cq.wait();
    try std.testing.expectEqual(&last.c, b);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: cancel of an operation the queue already handed out" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&timer.c);
    const c = try cq.wait();
    try std.testing.expectEqual(&timer.c, c);

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
    for (&slow) |*t| try cq.submit(&t.c);

    cq.cancelAll(.keep);
    try std.testing.expect(!cq.hasPending());

    var seen: usize = 0;
    while (!cq.isEmpty()) : (seen += 1) {
        const c = try cq.wait();
        try std.testing.expectError(error.Canceled, c.cast(ev.Timer).getResult());
    }
    try std.testing.expectEqual(3, seen);
}

test "CompletionQueue: cancelAll(.discard) leaves the queue empty" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var slow = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var done = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&slow.c);
    try cq.submit(&done.c);

    // Let the short one finish so a result is sitting in `completed` too.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(80) });
    try common.waitForIo(&pause.c);
    try std.testing.expect(cq.hasCompleted());

    cq.cancelAll(.discard);
    try std.testing.expect(cq.isEmpty());

    // Calling it again with nothing left is fine.
    cq.cancelAll(.discard);
}

test "CompletionQueue: submit after close returns error.Closed" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    cq.close();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try std.testing.expectError(error.Closed, cq.submit(&timer.c));

    // The refused completion was left untouched: no ownership taken, nothing
    // queued, free to go to another queue.
    try std.testing.expectEqual(null, timer.c.group.owner);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: submit refuses completions the queue cannot own" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    // A group member is owned by its group.
    var member = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var grp = ev.Group.init(.race);
    grp.add(&member.c);
    try std.testing.expectError(error.InvalidCompletion, cq.submit(&member.c));

    // An operation parked in another queue is owned by that queue.
    var other = CompletionQueue.init();
    defer other.cancelAll(.discard);
    var parked = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    try other.submit(&parked.c);
    try std.testing.expectError(error.InvalidCompletion, cq.submit(&parked.c));

    // Rearm completions re-add themselves; the queue can never own one.
    var mail = ev.Async.init();
    mail.c.flags.rearm = true;
    try std.testing.expectError(error.InvalidCompletion, cq.submit(&mail.c));

    // Every refusal left the queue and the completions untouched.
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: close hands out in-flight completions before error.Closed" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try cq.submit(&timer.c);
    cq.close();

    // Closed but not drained: the wait still blocks for the in-flight
    // operation and delivers it.
    const c = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&timer.c, c);
    try timer.getResult();

    try std.testing.expectError(error.Closed, cq.wait());
}

test "CompletionQueue: another task's submit satisfies a wait blocked on an empty queue" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    const Producer = struct {
        fn run(cq_: *CompletionQueue, timer: *ev.Timer) !void {
            // Give the driver time to park on the empty queue first.
            var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(20) });
            try common.waitForIo(&pause.c);
            try cq_.submit(&timer.c);
        }
    };

    // The timer outlives the producer task: it is handed to the driver, not
    // kept in the producer's frame.
    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var handle = try rt.spawn(Producer.run, .{ &cq, &timer });
    defer handle.cancel();

    // Empty and open: parks until the producer's operation completes.
    const c = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&timer.c, c);
    try timer.getResult();
    try handle.join();
}

test "CompletionQueue: race group of I/O and timer works as an idle timeout (#677)" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    // The I/O side wins: the group comes back through the queue with the
    // timer canceled alongside it.
    var mail1 = ev.Async.init();
    var idle1 = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var grp1 = ev.Group.init(.race);
    grp1.add(&mail1.c);
    grp1.add(&idle1.c);
    try cq.submit(&grp1.c);

    mail1.notify();
    const first = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&grp1.c, first);
    try grp1.getResult();
    try mail1.getResult();
    try std.testing.expectError(error.Canceled, idle1.getResult());

    // The timer wins: the queue reports the idle timeout. Group membership is
    // sticky, so a re-park builds a fresh group over re-initialised members
    // rather than re-submitting the finished one.
    var mail2 = ev.Async.init();
    var idle2 = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var grp2 = ev.Group.init(.race);
    grp2.add(&mail2.c);
    grp2.add(&idle2.c);
    try cq.submit(&grp2.c);

    const second = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&grp2.c, second);
    try grp2.getResult();
    try idle2.getResult();
    try std.testing.expectError(error.Canceled, mail2.getResult());

    // A group still parked in the queue is torn down by cancelAll: the cancel
    // reaches the group root and takes its members down with it.
    var mail3 = ev.Async.init();
    var idle3 = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    var grp3 = ev.Group.init(.race);
    grp3.add(&mail3.c);
    grp3.add(&idle3.c);
    try cq.submit(&grp3.c);

    cq.cancelAll(.discard);
    try std.testing.expect(cq.isEmpty());
    try std.testing.expectError(error.Canceled, grp3.getResult());
}

test "CompletionQueue: canceling the waiting driver closes the queue and keeps results" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var slow = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    try cq.submit(&slow.c);

    const Driver = struct {
        fn run(cq_: *CompletionQueue) (Cancelable || Closeable)!void {
            _ = try cq_.wait();
        }
    };

    var handle = try rt.spawn(Driver.run, .{&cq});

    // Let the driver park on the queue, then cancel it.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(20) });
    try common.waitForIo(&pause.c);
    handle.cancel();

    // The canceled wait closed the queue and canceled every operation with
    // its result kept, so producers are turned away and the cleanup path can
    // take the results without blocking.
    var other = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try std.testing.expectError(error.Closed, cq.submit(&other.c));
    try std.testing.expect(!cq.hasPending());

    const c = cq.next().?;
    try std.testing.expectEqual(&slow.c, c);
    try std.testing.expectError(error.Canceled, slow.getResult());
    try std.testing.expect(cq.isEmpty());
    try std.testing.expectError(error.Closed, cq.wait());
}

test "CompletionQueue: select delivers the next completion" {
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&timer.c);

    const Sleeper = struct {
        fn run(rt_: *Runtime) !void {
            try rt_.sleep(.fromSeconds(10));
        }
    };
    var slow_task = try rt.spawn(Sleeper.run, .{rt});
    defer slow_task.cancel();

    const result = try select(.{ .io = &cq, .other = &slow_task });
    switch (result) {
        .io => |r| try std.testing.expectEqual(&timer.c, try r),
        .other => return error.TestUnexpectedResult,
    }
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: select fast path on an already finished completion" {
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&timer.c);

    // Let the timer land in `completed` before the select looks.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(50) });
    try common.waitForIo(&pause.c);
    try std.testing.expect(cq.hasCompleted());

    const Sleeper = struct {
        fn run(rt_: *Runtime) !void {
            try rt_.sleep(.fromSeconds(10));
        }
    };
    var slow_task = try rt.spawn(Sleeper.run, .{rt});
    defer slow_task.cancel();

    const result = try select(.{ .io = &cq, .other = &slow_task });
    switch (result) {
        .io => |r| try std.testing.expectEqual(&timer.c, try r),
        .other => return error.TestUnexpectedResult,
    }
}

test "CompletionQueue: losing a select does not lose the completion" {
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(60) });
    try cq.submit(&timer.c);

    const Napper = struct {
        fn run(rt_: *Runtime) !void {
            try rt_.sleep(.fromMilliseconds(5));
        }
    };
    var fast_task = try rt.spawn(Napper.run, .{rt});
    defer fast_task.cancel();

    const result = try select(.{ .io = &cq, .other = &fast_task });
    switch (result) {
        .io => return error.TestUnexpectedResult,
        .other => |r| try r,
    }

    // The queue was only deregistered from; the operation is still armed and
    // comes back through the ordinary wait.
    const c = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&timer.c, c);
    try std.testing.expect(cq.isEmpty());
}

test "CompletionQueue: select on a drained queue reports error.Closed" {
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    cq.close();

    const Sleeper = struct {
        fn run(rt_: *Runtime) !void {
            try rt_.sleep(.fromSeconds(10));
        }
    };
    var slow_task = try rt.spawn(Sleeper.run, .{rt});
    defer slow_task.cancel();

    const result = try select(.{ .io = &cq, .other = &slow_task });
    switch (result) {
        .io => |r| try std.testing.expectError(error.Closed, r),
        .other => return error.TestUnexpectedResult,
    }
}

test "CompletionQueue: close over an in-flight operation does not wake a parked select" {
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(60) });
    try cq.submit(&timer.c);

    const Closer = struct {
        fn run(cq_: *CompletionQueue) !void {
            var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(15) });
            try common.waitForIo(&pause.c);
            cq_.close();
        }
    };
    var closer = try rt.spawn(Closer.run, .{&cq});
    defer closer.cancel();

    const Sleeper = struct {
        fn run(rt_: *Runtime) !void {
            try rt_.sleep(.fromSeconds(10));
        }
    };
    var slow_task = try rt.spawn(Sleeper.run, .{rt});
    defer slow_task.cancel();

    // The close lands while the select is parked and the timer is in flight.
    // It must stay silent: the wake that ends the select is the operation
    // itself, carrying a real completion rather than error.Closed.
    const first = try select(.{ .io = &cq, .other = &slow_task });
    switch (first) {
        .io => |r| try std.testing.expectEqual(&timer.c, try r),
        .other => return error.TestUnexpectedResult,
    }

    // Drained now: closed with nothing in flight.
    const second = try select(.{ .io = &cq, .other = &slow_task });
    switch (second) {
        .io => |r| try std.testing.expectError(error.Closed, r),
        .other => return error.TestUnexpectedResult,
    }
    try closer.join();
}

test "CompletionQueue: canceling a select leaves the queue open" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var slow = ev.Timer.init(.{ .duration = .fromSeconds(10) });
    try cq.submit(&slow.c);

    const Driver = struct {
        const select = @import("select.zig").select;

        fn run(cq_: *CompletionQueue) !void {
            const result = try select(.{ .io = cq_ });
            _ = try result.io;
        }
    };
    var handle = try rt.spawn(Driver.run, .{&cq});
    defer handle.cancel();

    // Let the driver park in the select, then cancel it.
    var pause = ev.Timer.init(.{ .duration = .fromMilliseconds(20) });
    try common.waitForIo(&pause.c);
    handle.cancel();
    try std.testing.expectError(error.Canceled, handle.join());

    // The canceled select only deregistered, unlike a canceled `wait()`: the
    // queue is still open, the operation still in flight, and new submissions
    // are accepted.
    try std.testing.expect(cq.hasPending());
    var other = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&other.c);
    const c = try cq.timedWait(.fromSeconds(5));
    try std.testing.expectEqual(&other.c, c);
}

test "CompletionQueue: generic wait() on the queue" {
    const waitFuture = @import("select.zig").wait;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancelAll(.discard);

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    try cq.submit(&timer.c);

    const result = try waitFuture(&cq);
    try std.testing.expectEqual(&timer.c, try result.value);
    try std.testing.expect(cq.isEmpty());
}
