// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Wait on several I/O operations at once and handle them one at a time, in
//! the order they finish.
//!
//! Runtime-only: must be used from within an async task context.
//!
//! ## Which of the three waits you want
//!
//! - `waitForIo(&c)` - one operation, block until it finishes.
//! - `ev.Group.init(.race)` - several operations collapsed into a single
//!   virtual completion. The first to finish wins and **the rest are
//!   cancelled**. Use it when the losers are worthless once you have a winner.
//! - `CompletionQueue` - several operations kept individually. `wait` hands
//!   back whichever finished, and **the others stay armed**. Use it when each
//!   operation matters on its own, or when you want to keep waiting after the
//!   first one lands.
//!
//! That last difference is the one that decides most designs. A completion is
//! removed from the queue when it is returned to you; everything else is
//! untouched, so a long-lived loop re-arms only what actually fired instead of
//! tearing down and re-arming the whole set on every event.
//!
//! **A completion holds its result, so re-arming means re-initialising it.**
//! Handing `submit` a completion that has already finished queues nothing, and
//! the next `wait` reports the queue as empty rather than blocking. There is no
//! recovering from it either: re-initialising that completion afterwards does
//! not bring it back. Re-initialise before every submit.
//!
//! ## One fiber owning a socket, woken by both the socket and its peers
//!
//! The case that otherwise costs a fiber per connection: a fiber serving a
//! WebSocket that must also deliver messages other connections send it. Rather
//! than parking a second fiber on a mailbox, arm both sources and let one wait
//! end on either.
//!
//! ```zig
//! var poll = ev.NetPoll.init(stream.socket.handle, .recv);
//! var mailbox = ev.Async.init(); // other fibers call mailbox.notify()
//!
//! var cq = CompletionQueue.init();
//! defer cq.cancel();
//! cq.submit(&poll.c);
//! cq.submit(&mailbox.c);
//!
//! while (try cq.wait()) |c| {
//!     if (c == &poll.c) {
//!         const n = try stream.read(&buf, .none);
//!         if (n == 0) break; // peer hung up
//!         handleFrame(buf[0..n]);
//!         poll = ev.NetPoll.init(stream.socket.handle, .recv);
//!         cq.submit(&poll.c); // re-arm; the mailbox was never disturbed
//!     } else if (c == &mailbox.c) {
//!         while (outbox.pop()) |msg| try stream.writeAll(msg, .none);
//!         mailbox = ev.Async.init();
//!         cq.submit(&mailbox.c);
//!     }
//! }
//! ```
//!
//! Only the completion that fired is re-submitted. With `ev.Group.init(.race)`
//! the read would be cancelled and re-issued on every mailbox message, and vice
//! versa.
//!
//! ## Fan out, then act on each result as it lands
//!
//! `wait` returns in completion order, not submission order, so slow work does
//! not hold up fast work. New operations can be submitted from inside the loop,
//! including from within the handler for a completion.
//!
//! ```zig
//! var cq = CompletionQueue.init();
//! for (shards) |*s| cq.submit(&s.recv.c);
//!
//! while (try cq.wait()) |c| {
//!     const shard = shardFor(c);
//!     try shard.consume();
//!     if (!shard.done) {
//!         shard.recv = .init(shard.handle, .recv);
//!         cq.submit(&shard.recv.c); // keep this one going
//!     }
//! }
//! ```
//!
//! `wait` returns `null` once nothing is pending and nothing is completed, so
//! the loop ends on its own when the last shard stops re-submitting.
//!
//! ## Putting a deadline on the whole set
//!
//! `timedWait` bounds the wait for the *next* completion. To bound a whole
//! batch, compute the deadline once and pass it each time round, rather than
//! handing each call a fresh duration.
//!
//! ```zig
//! const deadline = Timeout.fromMilliseconds(500).toDeadline();
//! while (cq.timedWait(deadline)) |maybe_c| {
//!     const c = maybe_c orelse break; // all done
//!     handle(c);
//! } else |err| switch (err) {
//!     error.Timeout => {}, // out of time; cq.cancel() below cleans up
//!     error.Canceled => |e| return e,
//! }
//! ```
//!
//! ## Teardown
//!
//! `cancel` cancels everything still pending and discards anything already
//! completed, so it is safe as a `defer` regardless of how the loop exited. A
//! cancelled `wait` does the same before returning `error.Canceled`, so a fiber
//! cancelled while parked here does not leave operations armed against buffers
//! that are about to go out of scope.

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
    pub fn submit(self: *CompletionQueue, c: *Completion) void {
        c.group.owner = self;
        c.group.owner_callback = &ownerCallback;

        self.mutex.lock();
        self.pending.push(&c.group);
        self.mutex.unlock();

        getCurrentExecutor().loop.add(c);
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
                    self.cancelAll();
                    self.drainPending();
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
        const loop = &getCurrentExecutor().loop;
        while (node) |n| {
            const next_node = n.next;
            const c = completionFromGroup(n);
            loop.cancel(c);
            node = next_node;
        }
    }

    fn drainPending(self: *CompletionQueue) void {
        while (true) {
            self.resetSignals();

            self.mutex.lock();
            const pending_empty = self.pending.isEmpty();
            // Discard completed items during drain
            while (self.completed.pop()) |_| {}
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

test "CompletionQueue: re-submitting the completion that fired leaves the others armed" {
    // The property the docs lean on, and the one that separates this from
    // `ev.Group.init(.race)`: returning a completion removes only that one.
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancel();

    var fast = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
    var slow = ev.Timer.init(.{ .duration = .fromMilliseconds(200) });
    cq.submit(&fast.c);
    cq.submit(&slow.c);

    // Take the fast one three times, re-arming it each round. The slow timer is
    // never resubmitted, so if any of this disturbed it we would see it here
    // instead of `fast`.
    for (0..3) |_| {
        const c = (try cq.wait()).?;
        try std.testing.expectEqual(&fast.c, c);
        fast = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
        cq.submit(&fast.c);
    }

    // `slow` survived all of that still pending.
    try std.testing.expect(cq.hasPending());
}

test "CompletionQueue: one deadline can bound a whole batch" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var cq = CompletionQueue.init();
    defer cq.cancel();

    var quick: [3]ev.Timer = undefined;
    for (&quick) |*t| {
        t.* = ev.Timer.init(.{ .duration = .fromMilliseconds(5) });
        cq.submit(&t.c);
    }
    var never = ev.Timer.init(.{ .duration = .fromSeconds(60) });
    cq.submit(&never.c);

    // Computed once, passed unchanged each round: the budget covers the batch
    // rather than restarting for every completion.
    const deadline = Timeout.fromMilliseconds(500).toDeadline();
    var seen: usize = 0;
    while (cq.timedWait(deadline)) |maybe_c| {
        _ = maybe_c orelse break;
        seen += 1;
    } else |err| switch (err) {
        error.Timeout => {},
        error.Canceled => |e| return e,
    }

    // The three quick timers land; the 60s one is what ends the loop, via the
    // deadline rather than by completing.
    try std.testing.expectEqual(3, seen);
}
