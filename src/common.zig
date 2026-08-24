// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

pub const log = std.log.scoped(.zio);

const ev = @import("ev/root.zig");
const Timeout = @import("time.zig").Timeout;
const Clock = @import("time.zig").Clock;
const Timestamp = @import("time.zig").Timestamp;
const Stopwatch = @import("time.zig").Stopwatch;
const Duration = @import("time.zig").Duration;
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTaskOrNull = @import("runtime.zig").getCurrentTaskOrNull;
const getWaitableTaskOrNull = @import("runtime.zig").getWaitableTaskOrNull;
const loopClearTimer = @import("runtime.zig").loopClearTimer;
const AnyTask = @import("task.zig").AnyTask;
const Executor = @import("runtime.zig").Executor;
const WaitNode = @import("utils/wait_queue.zig").WaitNode;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const os = @import("os/root.zig");
const syscall_cancel = os.syscall_cancel;

/// Error set for operations that can be cancelled
pub const Cancelable = error{
    Canceled,
};

/// Error set for operations that can timeout
pub const Timeoutable = error{
    Timeout,
};

/// Error set for operations against something that can be closed
pub const Closeable = error{
    Closed,
};

/// Sentinel value indicating no winner has been selected yet in select operations
pub const NO_WINNER = std.math.maxInt(usize);

/// Sentinel value for a select's winner word while the select's own sweep is
/// committing a consuming arm (today: a channel rendezvous pairing). It is a
/// fence, not a decision: while it is set, external claims fail with `.busy`
/// and the owner is guaranteed that `finishCommit` cannot lose a race. Only
/// the owning select ever writes this value, and it never parks while holding
/// it.
pub const COMMITTING = std.math.maxInt(usize) - 1;

/// Result of `asyncWait` (see the protocol comment in select.zig).
pub const AsyncWaitState = enum {
    /// This arm won the select: the winner word holds its index and its side
    /// effect (if any) is complete. No signal follows for this registration.
    ready,
    /// Like `.ready`, but one signal was already sent for an earlier
    /// registration of this arm (the arm was popped and signaled before the
    /// caller re-polled). The caller must account for that signal.
    ready_signaled,
    /// Registered. Exactly one signal follows if the arm is claimed or woken.
    queued,
    /// Registered again after a previous registration was popped and signaled
    /// without a claim. The caller must account for that earlier signal.
    requeued,
    /// Another arm already won this select. Nothing was consumed and nothing
    /// new was registered (an existing registration may remain; it is the
    /// caller's job to cancel it).
    decided,
};

/// Result of claiming a select waiter from outside its own sweep.
pub const ClaimResult = enum {
    /// The claim won: the winner word now holds this arm's index. The caller
    /// is committed to delivering the arm's side effect and exactly one
    /// signal.
    won,
    /// The owning select's sweep holds the commit fence. The claim neither
    /// won nor lost; the caller must not consume anything on behalf of this
    /// waiter. Queue-based callers leave the node in place (the owner
    /// re-polls after releasing the fence); pop-based callers treat this
    /// like `.lost` but still send their signal, which records the arm so
    /// the owner can promote it even if the source stops reporting itself
    /// ready (see `Select.pending`).
    busy,
    /// Another arm already won. Nothing may be consumed for this waiter.
    lost,
};

/// Stack-allocated waiter for async operations.
///
/// Supports two modes:
/// - `direct`: For single-future waiting. Owns the task and notify.
/// - `select`: For multi-future select(). Points to a parent direct waiter.
///
/// Usage:
/// ```zig
/// var waiter = Waiter.init();
/// future.asyncWait(&waiter);
/// try waiter.wait(1, .allow_cancel);
/// ```
///
/// **A waiter is good for one wait.** The signal count only ever increases:
/// `signal` adds to it and `wait` compares against it without consuming, so
/// once a waiter has been signaled it satisfies every later `wait(1, ...)`
/// immediately. Do not reuse one for a second, independent wait.
///
/// The one legitimate second call is the cancellation handshake, where both
/// calls are waiting for the *same* signal:
///
/// ```zig
/// waiter.wait(1, .allow_cancel) catch |err| {
///     if (!queue.remove(&waiter.node)) {
///         // Already dequeued by a waker; its signal is in flight and the
///         // waker still owns our node, so block until it lands.
///         waiter.wait(1, .no_cancel);
///         // We are not going to act on it, so pass it to someone who will.
///         if (queue.pop()) |node| Waiter.fromNode(node).signal();
///     }
///     return err;
/// };
/// ```
///
/// A primitive that retries must therefore construct a fresh waiter on each
/// attempt, inside the loop rather than outside it - see `Mutex.lock`. Hoisting
/// it out is silent: the second attempt's `wait` returns at once, and a
/// primitive that re-queues its node per attempt will push a node that is still
/// linked into the queue.
pub const Waiter = struct {
    node: WaitNode = .{},
    mode: union(enum) {
        direct: Direct,
        select: Select,
    },

    /// Direct waiter for single-future waiting.
    pub const Direct = struct {
        notify: os.thread.Notify,
        task: ?*AnyTask,

        pub fn init() Direct {
            return .{
                .notify = .init(),
                // Waitable, not current: inside a no-suspend region the wait
                // must block the thread, not park the task.
                .task = getWaitableTaskOrNull(),
            };
        }
    };

    /// Select waiter for multi-future select().
    pub const Select = struct {
        parent: *Waiter,
        winner: *std.atomic.Value(usize),
        /// Bumped by claimers before their winner CAS. The owning select
        /// re-polls its arms when this changes, which is what re-drives a
        /// pairing that a peer skipped because the winner word held
        /// `COMMITTING`. Lives in the select frame next to the winner word.
        gen: *std.atomic.Value(u32),
        /// Holds the arm of a notification whose winner CAS bounced off the
        /// commit fence. Such a notification consumed nothing, but its
        /// identity would otherwise be lost, and re-polling only recovers it
        /// for sources whose readiness is still standing afterwards (a
        /// drained Group can take new tasks, a set ResetEvent can be reset).
        /// The owning select promotes this into `winner` once the fence is
        /// down; see `promotePending`.
        pending: *std.atomic.Value(usize),
        index: usize,

        pub fn init(
            parent: *Waiter,
            winner: *std.atomic.Value(usize),
            gen: *std.atomic.Value(u32),
            pending: *std.atomic.Value(usize),
            index: usize,
        ) Select {
            return .{
                .parent = parent,
                .winner = winner,
                .gen = gen,
                .pending = pending,
                .index = index,
            };
        }
    };

    /// Initialize a direct waiter for single-future waiting.
    pub fn init() Waiter {
        return .{
            .mode = .{ .direct = Direct.init() },
        };
    }

    /// Initialize a select waiter for multi-future select().
    pub fn initSelect(
        parent: *Waiter,
        winner: *std.atomic.Value(usize),
        gen: *std.atomic.Value(u32),
        pending: *std.atomic.Value(usize),
        index: usize,
    ) Waiter {
        return .{
            .mode = .{ .select = Select.init(parent, winner, gen, pending, index) },
        };
    }

    /// Recover Waiter pointer from embedded WaitNode.
    pub inline fn fromNode(node: *WaitNode) *Waiter {
        return @fieldParentPtr("node", node);
    }

    /// A direct waiter's asyncWait is called exactly once and never re-polled
    /// (unlike a select's sweep), so it can never have a prior registration to
    /// unhook. Sources use this to skip that check for direct waiters.
    pub inline fn isDirect(self: *const Waiter) bool {
        return switch (self.mode) {
            .direct => true,
            .select => false,
        };
    }

    /// Signal this waiter.
    /// For direct: increments signal count and wakes the task.
    /// For select: tries to claim winner slot, then signals the parent.
    pub fn signal(self: *Waiter) void {
        switch (self.mode) {
            .direct => |*d| {
                if (d.task) |task| {
                    _ = d.notify.state.fetchAdd(1, .release);
                    task.wake();
                } else {
                    d.notify.signal();
                }
            },
            .select => |*s| {
                // Try to claim winner slot with our index. The CAS fails both
                // when another arm already won and when the select's own sweep
                // holds the COMMITTING fence.
                if (s.winner.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire)) |prev| {
                    // Losing to the fence is not losing: nothing was consumed
                    // for this arm and nobody else took the select, so record
                    // the arm for the owner to promote once the fence is down.
                    // Only the first bounce of a fence window is kept; the
                    // others would have lost the winner word anyway. Published
                    // before the signal below, so a woken owner that sees the
                    // wake also sees the record.
                    if (prev == COMMITTING) {
                        _ = s.pending.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire);
                    }
                }
                // Always signal parent - needed for both winner notification and
                // cleanup synchronization (waiting for in-flight wakes to complete).
                s.parent.signal();
            },
        }
    }

    /// Try to claim this waiter as a winner in select().
    /// Returns `.won` for direct waiters, which cannot lose.
    ///
    /// Queue consumers must claim under the same lock used by cancellation. A
    /// `.won` claim commits the caller to the arm's side effect and exactly
    /// one later signal; a `.lost` claim must not be signaled and its node may
    /// be discarded; a `.busy` claim must leave the node in place so the
    /// owner's re-poll can find it.
    ///
    pub fn tryClaim(self: *Waiter) ClaimResult {
        switch (self.mode) {
            .direct => return .won,
            .select => |*s| {
                const prev = s.winner.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire) orelse return .won;
                if (prev != COMMITTING) return .lost;
                // The owner's sweep holds the commit fence. Bump the
                // generation counter, then re-check the word: if the fence is
                // still held after the bump (both seq_cst, as are the owner's
                // fence release and generation load), the owner is guaranteed
                // to see the bump and re-poll; if it was released meanwhile,
                // the retry resolves the claim to won or lost.
                _ = s.gen.fetchAdd(1, .seq_cst);
                const prev2 = s.winner.cmpxchgStrong(NO_WINNER, s.index, .seq_cst, .seq_cst) orelse return .won;
                return if (prev2 == COMMITTING) .busy else .lost;
            },
        }
    }

    /// Check if this waiter won its select (was claimed).
    /// Returns true if won (or if direct waiter).
    pub fn didWin(self: *const Waiter) bool {
        return switch (self.mode) {
            .direct => true,
            .select => |s| s.winner.load(.acquire) == s.index,
        };
    }

    /// Owner-side: take the commit fence before a consuming commit that must
    /// pair two parties (claim a peer, then decide self). Returns false if
    /// another arm already won, in which case nothing may be consumed.
    ///
    /// Only the select's own sweep may call this, and it must release the
    /// fence via `finishCommit` or `abortCommit` without parking in between.
    /// Direct waiters need no fence (nobody can claim them) and always
    /// succeed.
    pub fn beginCommit(self: *Waiter) bool {
        return switch (self.mode) {
            .direct => true,
            .select => |*s| s.winner.cmpxchgStrong(NO_WINNER, COMMITTING, .seq_cst, .seq_cst) == null,
        };
    }

    /// Owner-side: decide this arm while holding the commit fence. Cannot
    /// fail: the fence excludes external claims.
    pub fn finishCommit(self: *Waiter) void {
        switch (self.mode) {
            .direct => {},
            .select => |*s| {
                std.debug.assert(s.winner.load(.monotonic) == COMMITTING);
                s.winner.store(s.index, .seq_cst);
            },
        }
    }

    /// Owner-side: release the commit fence without deciding (the commit
    /// found nothing to consume). Peers that observed the fence bumped the
    /// generation counter first, so the owner's post-release generation check
    /// is guaranteed to see them and re-poll.
    pub fn abortCommit(self: *Waiter) void {
        switch (self.mode) {
            .direct => {},
            .select => |*s| {
                std.debug.assert(s.winner.load(.monotonic) == COMMITTING);
                s.winner.store(NO_WINNER, .seq_cst);
            },
        }
    }

    /// Promote a notification that bounced off the commit fence into the
    /// winner word. Returns true if it won, in which case the arm's result is
    /// delivered without re-polling its source: the notification is proof the
    /// arm completed, whereas the source may no longer report itself ready.
    ///
    /// Called by the owning select after every point where the fence may have
    /// just been released, and again after each wake, which is what closes the
    /// window where a bounce lands just as the fence goes down.
    pub fn promotePending(
        winner: *std.atomic.Value(usize),
        pending: *std.atomic.Value(usize),
    ) bool {
        const arm = pending.load(.acquire);
        if (arm == NO_WINNER) return false;
        return winner.cmpxchgStrong(NO_WINNER, arm, .acq_rel, .acquire) == null;
    }

    /// Top bit of a direct waiter's notify state, set when its timeout timer
    /// fired. It is deliberately not a signal: the timer never touches the
    /// count, so the count keeps meaning "signals from real sources", and the
    /// bit alone says the timeout won.
    const timeout_flag: u32 = 1 << 31;

    fn signalCount(state: u32) u32 {
        return state & ~timeout_flag;
    }

    /// Whether this waiter's timeout timer fired.
    fn timedOut(self: *const Waiter) bool {
        return self.mode.direct.notify.state.load(.acquire) & timeout_flag != 0;
    }

    /// Wait for at least `expected` signals, handling spurious wakeups internally.
    /// Only valid for direct waiters.
    ///
    /// Level-triggered: this checks `count >= expected` and does not consume
    /// anything, so calling it twice for two different signals does not work.
    /// See the note on `Waiter` - one waiter, one wait, plus the `.no_cancel`
    /// re-wait of the cancellation handshake.
    pub fn wait(self: *Waiter, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        const d = &self.mode.direct;
        if (d.task) |task| {
            return waitTask(d, task, expected, cancel_mode);
        } else {
            return waitFutex(d, expected, cancel_mode);
        }
    }

    /// Error set of a timed wait: `error.Timeout` says the timer fired with no
    /// signal in hand, which the count alone cannot tell you (the timer does
    /// not signal).
    ///
    /// It reports which source ended the wait, not who won a contested
    /// handoff: a caller racing a wait queue still settles that with its own
    /// bookkeeping, since a signal can land right behind the timeout.
    pub fn TimedWaitError(comptime cancel_mode: Executor.YieldCancelMode) type {
        return if (cancel_mode == .allow_cancel) (Timeoutable || Cancelable) else Timeoutable;
    }

    /// Wait for at least `expected` signals with a timeout.
    /// Only valid for direct waiters.
    pub fn timedWait(self: *Waiter, expected: u32, timeout: Timeout, comptime cancel_mode: Executor.YieldCancelMode) TimedWaitError(cancel_mode)!void {
        return self.timedWaitClock(expected, timeout, .awake, cancel_mode);
    }

    /// Like `timedWait`, but the timeout is measured against `clock`. The
    /// no-task futex fallback only supports the monotonic (`awake`) clock, so
    /// boot/real timeouts there degrade to awake semantics.
    pub fn timedWaitClock(self: *Waiter, expected: u32, timeout: Timeout, clock: Clock, comptime cancel_mode: Executor.YieldCancelMode) TimedWaitError(cancel_mode)!void {
        if (timeout == .none) {
            if (cancel_mode == .allow_cancel) {
                try self.wait(expected, cancel_mode);
            } else {
                self.wait(expected, cancel_mode);
            }
            return;
        }

        const d = &self.mode.direct;
        const task = d.task orelse return timedWaitFutex(d, expected, futexTimeout(timeout, clock), cancel_mode);

        // Drop a flag left behind by an earlier timed wait on this waiter.
        _ = d.notify.state.fetchAnd(~timeout_flag, .monotonic);

        var timer: ev.Timer = .initClock(timeout, clock);
        timer.c.userdata = self;
        timer.c.callback = timeoutCallback;

        task.getExecutor().loopSetTimer(&timer, timeout);
        defer {
            // A clear that loses its race leaves the timer completing, and its
            // callback still runs against `timer`, which lives in this frame.
            // The callback sets the flag before waking us, so parking on it
            // keeps the frame alive for exactly as long as the callback needs.
            if (!loopClearTimer(timer.c.getLoop().?, &timer)) {
                while (!self.timedOut()) {
                    task.yield(.park, .no_cancel);
                }
            }
        }

        // Park until the count is reached or the timer fires. The count is
        // checked first, so a signal landing together with the timeout still
        // counts as a signal.
        while (true) {
            const state = d.notify.state.load(.acquire);
            if (signalCount(state) >= expected) return;
            if (state & timeout_flag != 0) return error.Timeout;
            if (cancel_mode == .allow_cancel) {
                try task.yield(.park, .allow_cancel);
            } else {
                task.yield(.park, .no_cancel);
            }
        }
    }

    /// Callback for the `timedWaitClock` timer.
    fn timeoutCallback(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Waiter = @ptrCast(@alignCast(c.userdata.?));
        const d = &self.mode.direct;
        // Read the task before publishing: once the flag is visible the waiter
        // may return and drop the frame holding the timer, so nothing below may
        // touch `self` or the completion again.
        const task = d.task.?;
        _ = d.notify.state.fetchOr(timeout_flag, .release);
        task.wake();
    }

    fn waitFutex(d: *Direct, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        if (cancel_mode == .allow_cancel) {
            const sc = try syscall_cancel.Syscall.begin();
            defer sc.finish();
            while (true) {
                const current = d.notify.state.load(.acquire);
                if (signalCount(current) >= expected) return;
                d.notify.wait(current);
                try sc.checkCancel();
            }
        } else {
            while (true) {
                const current = d.notify.state.load(.acquire);
                if (signalCount(current) >= expected) return;
                d.notify.wait(current);
            }
        }
    }

    /// Collapse a wall-clock (boot/real) deadline into a monotonic-relative
    /// duration for the no-task futex fallback, which can only wait on the
    /// monotonic clock. Without this, `timedWaitFutex` would compare an
    /// absolute realtime timestamp (~ns since 1970) against monotonic time and
    /// wait for decades. Best-effort: it snapshots the remaining time once and
    /// loses suspend/step semantics.
    ///
    /// TODO: support boot/real natively on this path. The Linux futex can wait
    /// against CLOCK_REALTIME (FUTEX_WAIT_BITSET | FUTEX_CLOCK_REALTIME), so a
    /// no-task wait on a real deadline could be exact rather than converted.
    fn futexTimeout(timeout: Timeout, clock: Clock) Timeout {
        return switch (timeout) {
            .none, .duration => timeout,
            .deadline => |deadline| .{ .duration = Timestamp.now(clock).durationTo(deadline) },
        };
    }

    fn timedWaitFutex(d: *Direct, expected: u32, timeout: Timeout, comptime cancel_mode: Executor.YieldCancelMode) TimedWaitError(cancel_mode)!void {
        if (cancel_mode == .allow_cancel) {
            const sc = try syscall_cancel.Syscall.begin();
            defer sc.finish();
            const deadline = timeout.toDeadline();
            while (true) {
                const current = d.notify.state.load(.acquire);
                if (signalCount(current) >= expected) return;
                const remaining = deadline.durationFromNow();
                if (remaining.value <= 0) return error.Timeout;
                d.notify.timedWait(current, remaining) catch {
                    const final = d.notify.state.load(.acquire);
                    if (signalCount(final) >= expected) return;
                    return error.Timeout;
                };
                try sc.checkCancel();
            }
        } else {
            const deadline = timeout.toDeadline();
            while (true) {
                const current = d.notify.state.load(.acquire);
                if (signalCount(current) >= expected) return;
                const remaining = deadline.durationFromNow();
                if (remaining.value <= 0) return error.Timeout;
                d.notify.timedWait(current, remaining) catch {
                    const final = d.notify.state.load(.acquire);
                    if (signalCount(final) >= expected) return;
                    return error.Timeout;
                };
            }
        }
    }

    fn waitTask(d: *Direct, task: *AnyTask, expected: u32, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        var current = signalCount(d.notify.state.load(.acquire));
        if (current >= expected) return;

        // Park loop: yield until the condition is met.
        //
        // Race safety: if a signal fires while the task is in .ready state (between
        // the condition check above and the actual context switch in yield), the waker
        // sets the `awaken` bit. `processCleanup.park` then consumes the bit and
        // reschedules the task instead of transitioning it to .waiting, so the wake
        // is never lost.
        while (true) {
            if (cancel_mode == .allow_cancel) {
                try task.yield(.park, .allow_cancel);
            } else {
                task.yield(.park, .no_cancel);
            }

            current = signalCount(d.notify.state.load(.acquire));
            if (current >= expected) return;
        }
    }

    /// Callback for ev.Completion - signals this waiter.
    pub fn callback(_: *ev.Loop, c: *ev.Completion) void {
        const self: *Waiter = @ptrCast(@alignCast(c.userdata.?));
        self.signal();
    }
};

/// Shared `asyncWait` body for level sources backed by a sticky-flag
/// WaitQueue (Future, ResetEvent, Awaitable): readiness is the flag,
/// completion pops every waiter and signals it. Idempotent under re-poll,
/// and claims the select before reporting ready.
pub fn waitOnFlagQueue(queue: *WaitQueue(WaitNode), waiter: *Waiter) AsyncWaitState {
    if (queue.isFlagSet()) {
        // Ready. Claim before touching the registration: a lost claim must
        // leave the node exactly where it is, so either the completing
        // side's pop still signals it or asyncCancelWait still removes it
        // cleanly - both keep the caller's signal accounting balanced.
        return switch (waiter.tryClaim()) {
            .won => if (waiter.isDirect() or queue.remove(&waiter.node)) .ready else .ready_signaled,
            // Only the owning sweep calls asyncWait, and it never holds its
            // own commit fence here.
            .busy => unreachable,
            .lost => .decided,
        };
    }
    // Not ready: (re-)register. Unhook any previous registration first so a
    // re-poll never double-registers. A registration that is already gone
    // was popped and signaled by the completing side.
    const had_registration = !waiter.isDirect() and queue.remove(&waiter.node);
    if (queue.pushUnlessFlag(&waiter.node)) {
        return if (had_registration) .queued else .requeued;
    }
    // Completion landed between the check and the push, leaving the node in
    // hand where no pop can reach it.
    switch (waiter.tryClaim()) {
        .won => return if (had_registration) .ready else .ready_signaled,
        .busy => unreachable,
        .lost => {
            // A cleanly unhooked registration owes a signal the completing
            // side can no longer send (the caller's cleanup will see the
            // node gone and expect one); send it ourselves.
            if (had_registration) waiter.signal();
            return .decided;
        },
    }
}

/// Runs an I/O operation to completion.
/// Sets up the callback, submits to the event loop, and waits for completion.
///
/// If called from a context with an async runtime, uses the event loop.
/// If called from a context without a runtime, executes the operation synchronously.
pub fn waitForIo(c: *ev.Completion) Cancelable!void {
    var waiter = Waiter.init();
    c.userdata = &waiter;
    // Null callback: the loop hands the finished completion out through its
    // dispatched queue, and the executor signals the waiter when it drains
    // the queue (see Executor.drainDispatched).
    c.callback = null;
    c.flags = .{ .defer_callback = false }; // single-shot wait: no rearm either

    defer if (std.debug.runtime_safety) {
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, if (builtin.single_threaded) std.heap.c_allocator else std.heap.smp_allocator);
        return;
    };

    // A task that is already canceled must not start new work.
    //
    // Without this, a caller that loops on an operation which keeps failing
    // for its own reasons never observes the cancellation. The wait below
    // does see it, and cancels the operation -- but if the operation had
    // already completed with a result of its own, that result is what the
    // caller must be given, so the cancellation is re-armed and handed back
    // for the next cancelation point to deliver. When the caller's next
    // cancelation point is the same operation, and it fails the same way
    // again, the cancellation is re-armed forever and never acted on.
    //
    // It has to be before `loop.add`, not after: once the operation has run,
    // reporting the cancellation instead of its result would throw away an
    // accepted socket or bytes already read, which is exactly what the
    // re-arm below is protecting.
    try task.checkCancel();

    // Async path: Submit to the event loop and wait for completion
    task.getExecutor().loopAdd(c);
    // Inline completions never park; charge the coop budget so they still
    // hit a yield point.
    const completed_inline = waiter.mode.direct.notify.state.load(.acquire) != 0;
    waiter.wait(1, .allow_cancel) catch |err| switch (err) {
        error.Canceled => {
            // On cancellation, cancel the I/O and wait for completion
            task.getExecutor().loopCancel(c);
            waiter.wait(1, .no_cancel);

            // Check if I/O was actually canceled
            if (c.err) |io_err| {
                if (io_err == error.Canceled) {
                    return error.Canceled;
                }
            }
            // IO completed successfully despite cancel request - restore the pending cancel
            task.recancel();
            return;
        },
    };
    if (completed_inline) {
        task.getExecutor().maybeYield(.reschedule, .no_cancel);
    }
}

/// Runs an I/O operation to completion without allowing cancellation.
/// This is used for cleanup operations like close() that must complete.
///
/// If called from a context with an async runtime, uses the event loop (no cancel).
/// If called from a context without a runtime, executes the operation synchronously.
pub fn waitForIoUncancelable(c: *ev.Completion) void {
    var waiter = Waiter.init();
    c.userdata = &waiter;
    c.callback = null; // dispatched-queue delivery, see waitForIo
    c.flags = .{ .defer_callback = false };

    defer if (std.debug.runtime_safety) {
        c.userdata = null;
    };

    // Blocking path: Execute synchronously without event loop
    const task = waiter.mode.direct.task orelse {
        // TODO: Don't use std.heap.smp_allocator - it should be passed as a parameter
        ev.executeBlocking(c, if (builtin.single_threaded) std.heap.c_allocator else std.heap.smp_allocator);
        return;
    };

    // Async path: Submit to the event loop and wait for completion (no cancel)
    task.getExecutor().loopAdd(c);
    const completed_inline = waiter.mode.direct.notify.state.load(.acquire) != 0;
    waiter.wait(1, .no_cancel);
    if (completed_inline) {
        task.getExecutor().maybeYield(.reschedule, .no_cancel);
    }
}

/// Runs an I/O operation to completion with a timeout.
/// If the timeout expires before the I/O completes, returns `error.Timeout`.
/// If the timeout is `.none`, waits indefinitely (just calls `waitForIo`).
pub fn timedWaitForIo(c: *ev.Completion, timeout: Timeout) (Timeoutable || Cancelable)!void {
    return timedWaitForIoClock(c, timeout, .awake);
}

/// Like `timedWaitForIo`, but the timeout is measured against `clock`.
pub fn timedWaitForIoClock(c: *ev.Completion, timeout: Timeout, clock: Clock) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return waitForIo(c);
    }

    var group = ev.Group.init(.race);
    var timer = ev.Timer.initClock(timeout, clock);

    group.add(c);
    group.add(&timer.c);

    try waitForIo(&group.c);

    // Check if the IO was cancelled by the timeout
    // (both could complete in a race, so check if I/O was actually cancelled)
    if (timer.c.err == null) {
        if (c.err) |io_err| {
            if (io_err == error.Canceled) {
                return error.Timeout;
            }
        }
    }
}

test "waitForIo: basic timer completion" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try waitForIo(&timer.c);
}

test "timedWaitForIo: timeout interrupts long operation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Long timer (1 second) with short timeout (10ms)
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(1) });
    try std.testing.expectError(error.Timeout, timedWaitForIo(&timer.c, .fromMilliseconds(10)));
}

test "timedWaitForIo: completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Short timer (10ms) with long timeout (1 second)
    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try timedWaitForIo(&timer.c, .{ .duration = .fromSeconds(1) });
}

test "Waiter: futex-based timed wait with timeout" {
    // Create waiter without task (blocking context)
    var waiter: Waiter = .{
        .mode = .{ .direct = .{
            .task = null,
            .notify = .init(),
        } },
    };

    var timer = Stopwatch.start();
    try std.testing.expectError(error.Timeout, waiter.timedWait(1, .fromMilliseconds(50), .no_cancel));
    const elapsed = timer.read();

    errdefer std.debug.print("timedWait(50ms) returned after {d}ms\n", .{elapsed.toMilliseconds()});

    // Should return after the timeout expires (allow slight undershoot for timer resolution)
    try std.testing.expect(elapsed.toMilliseconds() >= 40);
    // Generous upper bound: only meant to catch gross timeout miscalculation
    // (wrong units, waiting forever). Loaded CI runners can delay the wakeup
    // by hundreds of milliseconds, so anything tighter is flaky.
    try std.testing.expect(elapsed.toMilliseconds() < 5000);
}

test "Waiter: cancelable futex park returns Canceled via the bound token" {
    if (!syscall_cancel.enabled) return error.SkipZigTest;

    // Normally the thread pool installs this; do it ourselves since the test
    // drives a bare worker thread with no pool.
    syscall_cancel.installHandler();
    defer syscall_cancel.uninstallHandler();

    var token: syscall_cancel.Token = .{};

    // Parked on the futex and never signaled to completion (expected stays 1),
    // so the only way out is cancellation.
    var waiter: Waiter = .{
        .mode = .{ .direct = .{ .task = null, .notify = .init() } },
    };

    const Worker = struct {
        fn run(tok: *syscall_cancel.Token, w: *Waiter, canceled: *std.atomic.Value(bool)) void {
            // Bind the token to this worker (as the pool does around a task's func),
            // so the Waiter park can reach it through the threadlocal.
            tok.enter();
            defer tok.exit();
            if (w.wait(1, .allow_cancel)) |_| {
                // Unexpected completion; leave `canceled` false.
            } else |err| {
                if (err == error.Canceled) canceled.store(true, .release);
            }
        }
    };

    var canceled = std.atomic.Value(bool).init(false);
    var thread = try std.Thread.spawn(.{}, Worker.run, .{ &token, &waiter, &canceled });

    // Wait until the worker is inside the cancelable region (parked or about to).
    while (token.state.load(.acquire) != .blocked) os.thread.yield();

    // Request cancellation and resend SIGURG until the worker acknowledges,
    // covering the gap between begin() and the kernel entering the futex.
    _ = token.cancel();
    while (token.signal()) os.thread.yield();

    thread.join();
    try std.testing.expect(canceled.load(.acquire));
}

/// Execute a blocking function on the thread pool, blocking the current task until completion.
///
/// Unlike `spawnBlocking`, this does not allocate - all state is kept on the stack.
/// The calling task is parked while the blocking work executes on a thread pool
/// worker. Two cases run `func` inline on the calling thread instead, where
/// parking is not an option: no task at all, and a task inside a no-suspend
/// region. Inline execution is uncancelable - it never binds a `syscall_cancel`
/// token, so a cancel cannot interrupt it.
///
/// Usage:
/// ```zig
/// const result = zio.blockInPlace(expensiveComputation, .{arg1, arg2});
/// ```
pub fn blockInPlace(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) meta.ReturnType(func) {
    const Args = @TypeOf(args);
    const Result = meta.ReturnType(func);

    const Context = struct {
        args: Args,
        result: Result = undefined,

        fn workFn(work: *ev.Work) void {
            const ctx: *@This() = @ptrCast(@alignCast(work.userdata.?));
            ctx.result = @call(.auto, func, ctx.args);
        }
    };

    var ctx: Context = .{ .args = args };

    // Nothing to park, so nothing to hand off to: run it here.
    if (getWaitableTaskOrNull() == null) {
        return @call(.auto, func, args);
    }

    var token: os.syscall_cancel.Token = .{};
    var work = ev.Work.init(Context.workFn, &ctx);
    work.cancel_token = &token;

    // Submit to the thread pool and wait through the event loop. The loop owns
    // completion delivery — it finalizes work.c and signals the waiter on the
    // loop thread as the *last* step — and cancellation: loop.cancel interrupts
    // a blocking cancelable syscall via SIGURG and resends each tick until the
    // worker acknowledges (see Loop.cancel_resend). Unlike a direct worker-thread
    // completion callback, nothing touches this stack frame after we might
    // return, so there is no use-after-free window.
    //
    // workFn always runs (token-bearing work is never dropped from the queue),
    // so ctx.result is always valid. A canceled syscall makes `func` return
    // error.Canceled, which surfaces here as that result; waitForIo re-arms the
    // task's pending cancellation before returning.
    //
    // waitForIo only fails with error.Canceled, and only when the *completion*
    // carries a Canceled result — which happens on the drop path, where workFn
    // never runs and ctx.result would be undefined. Token-bearing work is never
    // dropped (it always completes via setResult, cancellation delivered in-band
    // through func's return), so this is unreachable. Assert it: were it ever to
    // fire we would be returning uninitialized ctx.result, which we would much
    // rather crash on.
    waitForIo(&work.c) catch unreachable;

    return ctx.result;
}

const meta = @import("meta.zig");

test "blockInPlace: basic computation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const double = struct {
        fn call(x: i32) i32 {
            return x * 2;
        }
    }.call;

    const result = blockInPlace(double, .{21});
    try std.testing.expectEqual(42, result);
}

test "blockInPlace: cancellation interrupts a blocking syscall on the worker" {
    if (!os.syscall_cancel.enabled) return;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // A worker function that blocks in a cancelable read on an empty pipe. When
    // the owning task is canceled, the read must be interrupted via SIGURG and
    // return error.Canceled — which blockInPlace surfaces as its result.
    const worker = struct {
        fn cancelableRead(fd: std.c.fd_t, ready: *std.atomic.Value(bool)) error{ Canceled, Unexpected }!void {
            const sc = try os.syscall_cancel.Syscall.begin();
            defer sc.finish();
            // Signal that we are inside the cancelable region, just before read().
            ready.store(true, .release);
            var buf: [1]u8 = undefined;
            while (true) {
                const rc = std.c.read(fd, &buf, buf.len);
                if (rc >= 0) return error.Unexpected;
                switch (std.posix.errno(rc)) {
                    .INTR => {
                        try sc.checkCancel();
                        continue;
                    },
                    else => return error.Unexpected,
                }
            }
        }

        fn call(read_fd: std.c.fd_t, ready: *std.atomic.Value(bool)) !void {
            const result = blockInPlace(cancelableRead, .{ read_fd, ready });
            try std.testing.expectError(error.Canceled, result);
        }
    };

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ready = std.atomic.Value(bool).init(false);
    var handle = try rt.spawn(worker.call, .{ fds[0], &ready });

    // Wait until the worker is inside the cancelable region (after begin() but
    // before read()), then cancel the task.
    while (!ready.load(.acquire)) try rt.sleep(.fromMicroseconds(100));
    handle.cancel();

    // The worker catches the cancellation and returns normally, so join succeeds.
    try handle.join();
}
