// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTask = @import("runtime.zig").getCurrentTask;
const getCurrentTaskOrNull = @import("runtime.zig").getCurrentTaskOrNull;
const yield = @import("runtime.zig").yield;
const common = @import("common.zig");
const Cancelable = common.Cancelable;
const Waiter = common.Waiter;
const NO_WINNER = common.NO_WINNER;
const AnyTask = @import("task.zig").AnyTask;
const Awaitable = @import("awaitable.zig").Awaitable;
const meta = @import("meta.zig");

// Future protocol - Any type implementing these methods can be used with select():
//
//   const Result = T
//     The type of value this future produces when complete.
//
//   const WaitContext = void | SomeStruct
//     Optional per-wait mutable state. Use void if the future needs no per-wait state.
//     If non-void, this struct will be allocated on the caller's stack and passed to
//     asyncWait/asyncCancelWait. Useful for storing completions, results, or other
//     data that varies per wait operation.
//
//   fn asyncWait(self: *Self, waiter: *Waiter) AsyncWaitState           // if WaitContext == void
//   fn asyncWait(self: *Self, waiter: *Waiter, ctx: *WaitContext) AsyncWaitState  // if WaitContext != void
//     Check readiness; either claim the select for this arm or register for a signal.
//
//     The one rule everything else follows from: an arm's consuming side
//     effect happens only after the arm has secured the select's winner word
//     (issue #701). For most sources that is `waiter.tryClaim()` before the
//     consume, done atomically with the readiness check under the source's
//     own lock (or made revertible, like a counter that can be added back).
//     A commit that must pair a peer waiter (channel rendezvous) instead
//     brackets the whole pairing in `waiter.beginCommit()`/`finishCommit()`,
//     so the claim of the peer and the decision of this select cannot be
//     torn apart; see the comment on `common.COMMITTING`.
//
//     Returns:
//       - .ready: This arm won: the winner word holds its index and the side
//                 effect is complete. Result is available via getResult().
//                 No signal will be sent for this registration.
//       - .ready_signaled: Like .ready, but one signal was already sent for
//                 an earlier registration of this waiter (it was popped and
//                 signaled without a claim while the select held the commit
//                 fence); the caller must count that signal.
//       - .queued: Registered. The waiter will be signaled exactly once when
//                 the arm is claimed or the source broadcasts.
//       - .requeued: Registered again after an earlier registration was
//                 popped and signaled without a claim; the caller must count
//                 that signal. On a first call this is equivalent to .queued
//                 (the source cannot tell a first call apart; the caller can).
//       - .decided: Another arm already won this select. Nothing was consumed
//                 and nothing new was registered. An existing registration
//                 may remain; asyncCancelWait still cleans it up.
//
//     Guarantees:
//       - May be called again while a previous registration is still queued
//         or was popped without a claim (select() re-polls after a fence
//         window); the implementation must not double-register.
//       - A re-poll need not rediscover readiness that a signal already
//         reported: a notification whose claim bounced off the commit fence
//         records its arm, and select() promotes that record. So a source
//         whose readiness can lapse (a drained Group taking new tasks, a set
//         ResetEvent being reset) may report itself unready here without
//         losing the event.
//       - Thread-safe with respect to the source; only the owning select's
//         sweep calls asyncWait for a given waiter.
//       - The ctx pointer (if present) remains valid until asyncCancelWait()
//         or waiter.wake()
//
//   fn asyncCancelWait(self: *Self, waiter: *Waiter) bool     // if WaitContext == void
//   fn asyncCancelWait(self: *Self, waiter: *Waiter, ctx: *WaitContext) bool  // if WaitContext != void
//     Cancel a pending wait operation by removing the waiter from internal queues.
//
//     Must be called if asyncWait() registered the waiter and the caller no
//     longer wants to wait (e.g., select() chose a different future).
//
//     Returns:
//       - true: Successfully removed from queue. The future will not signal this
//               waiter (and has not, for the current registration).
//       - false: Already removed by completion. A signal for the current
//                registration is in-flight or already happened.
//
//     For queuing operations (Channel), when returning false the implementation
//     must transfer the wakeup to another waiter to avoid losing the signal/item.
//
//     Guarantees:
//       - Thread-safe: can be called from any thread
//       - Safe to call even if asyncWait() completed immediately (no-op)
//
//   fn getResult(self: *const Self) Result                                        // if WaitContext == void
//   fn getResult(self: *const Self, ctx: *WaitContext) Result                      // if WaitContext != void
//     Retrieve the result of the completed operation.
//
//     Must only be called after asyncWait() returns .ready/.ready_signaled or
//     after the waiter won and its signal arrived.
//
//     Returns: The result value. For operations that can fail, Result may be an error union
//              (e.g., error{Closed}!T).
//
//     Guarantees:
//       - All side effects from the operation that produced the result are visible
//       - Thread-safe: can be called from any thread after completion

/// Extract the Future type from a pointer or value type
fn FutureType(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        return type_info.pointer.child;
    }
    return T;
}

/// Check if the future type is passed by pointer
fn isPointerFuture(comptime T: type) bool {
    return @typeInfo(T) == .pointer;
}

/// Extract the Result type from a future (pointer or value)
fn FutureResult(comptime future_type: type) type {
    const Future = FutureType(future_type);
    return Future.Result;
}

/// Check for self-wait deadlock if the future has a toAwaitable() method
fn checkSelfWait(task: *AnyTask, future: anytype) void {
    if (builtin.mode == .debug or builtin.mode == .safe) {
        if (std.meta.hasMethod(@TypeOf(future), "toAwaitable")) {
            const awaitable_ptr = future.toAwaitable();
            if (awaitable_ptr == &task.awaitable) {
                std.debug.panic("cannot wait on self (would deadlock)", .{});
            }
        }
    }
}

/// Extract the WaitContext type from a future pointer type
fn FutureWaitContext(comptime future_type: type) type {
    const Future = FutureType(future_type);
    if (@hasDecl(Future, "WaitContext")) {
        return Future.WaitContext;
    }
    return void;
}

/// Check if a future has a non-void WaitContext
fn hasWaitContext(comptime future_type: type) bool {
    return FutureWaitContext(future_type) != void;
}

/// Build a struct type containing WaitContext fields for each future that needs one
fn WaitContextsType(comptime futures_type: type) type {
    const info = @typeInfo(futures_type).@"struct";

    // Count how many fields have non-void WaitContext
    comptime var count: usize = 0;
    inline for (info.field_types) |FieldType| {
        if (FutureWaitContext(FieldType) != void) {
            count += 1;
        }
    }

    // Handle the zero-field case
    if (count == 0) {
        return @Struct(.auto, null, &.{}, &.{}, &.{});
    }

    // Build arrays of field names, types, and attributes
    var field_names: [count][:0]const u8 = undefined;
    var field_types: [count]type = undefined;
    var field_attrs: [count]std.builtin.Type.Struct.FieldAttributes = undefined;

    comptime var i: usize = 0;
    inline for (info.field_names, info.field_types) |name, FieldType| {
        const WaitCtx = FutureWaitContext(FieldType);
        if (WaitCtx != void) {
            const default_value: WaitCtx = .{};
            field_names[i] = name;
            field_types[i] = WaitCtx;
            field_attrs[i] = .{
                .default_value_ptr = @ptrCast(&default_value),
            };
            i += 1;
        }
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

/// Wrapper for wait() result to avoid nested error unions
pub fn WaitResult(comptime T: type) type {
    return struct {
        value: T,
    };
}

/// Behavior when a wait operation is canceled
pub const CancelBehavior = enum {
    /// Propagate the cancellation error to the caller
    propagate,
    /// Cancel the child task and continue waiting until completion (with shield)
    cancel_and_continue,
};

/// Flags for configuring wait behavior
pub const WaitFlags = struct {
    on_cancel: CancelBehavior = .propagate,
};

pub fn SelectResult(comptime S: type) type {
    const info = @typeInfo(S).@"struct";

    var field_names: [info.field_names.len][:0]const u8 = undefined;
    var field_types: [info.field_types.len]type = undefined;
    var field_attrs: [info.field_names.len]std.builtin.Type.Union.FieldAttributes = undefined;

    for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
        const Future = FutureType(FieldType);
        field_names[i] = name;
        field_types[i] = Future.Result;
        field_attrs[i] = .{};
    }

    return @Union(.auto, std.meta.FieldEnum(S), &field_names, &field_types, &field_attrs);
}

test "SelectResult: result types" {
    const Future1 = struct {
        const Result = void;
    };
    const Future2 = struct {
        const Result = u32;
    };

    const Select = SelectResult(struct {
        future1: *Future1,
        future2: *Future2,
    });

    _ = Select{ .future1 = {} };
    _ = Select{ .future2 = 32 };
}

/// Wait for multiple futures simultaneously and return whichever completes first.
///
/// `futures` is a struct with each field being either:
/// - A pointer to a future (e.g., `*JoinHandle(T)`) for futures that mutate self
/// - A value future (e.g., `channel.asyncReceive()`) for futures using WaitContext
///
/// Returns a tagged union with the same field names, containing the result of whichever completed first.
///
/// When multiple handles complete at the same time, fields are checked in declaration order
/// and the first ready handle is returned.
///
/// Example:
/// ```
/// // JoinHandles must be passed by pointer (they mutate self)
/// var h1 = try rt.spawn(task1, .{});
/// const result = try select(.{ .task = &h1, .recv = channel.asyncReceive() });
/// switch (result) {
///     .task => |val| ...,
///     .recv => |val| ...,
/// }
/// ```
pub fn select(futures: anytype) !SelectResult(@TypeOf(futures)) {
    const S = @TypeOf(futures);
    const U = SelectResult(S);
    const field_names = @typeInfo(S).@"struct".field_names;
    const field_types = @typeInfo(S).@"struct".field_types;

    // Self-wait detection: check all futures for self-wait
    const task = getCurrentTask();
    inline for (field_names) |name| {
        checkSelfWait(task, @field(futures, name));
    }

    // Winner tracking: NO_WINNER means no winner yet
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);

    // Bumped by claimers before their winner CAS; a change tells this select
    // that someone interacted with an arm while the sweep held the commit
    // fence, so the arms are worth re-polling.
    var gen: std.atomic.Value(u32) = .init(0);

    // Set by a notification whose winner CAS bounced off the commit fence, so
    // its arm survives a re-poll that no longer finds the source ready.
    var pending_winner: std.atomic.Value(usize) = .init(NO_WINNER);

    // Parent waiter that select waiters will signal when they win
    var waiter = Waiter.init();

    // Allocate WaitContext struct on stack for futures that need per-wait state
    const ContextsType = WaitContextsType(S);
    var contexts: ContextsType = .{};

    // Create waiter structures on the stack
    var waiters: [field_names.len]Waiter = undefined;
    inline for (&waiters, 0..) |*w, i| {
        w.* = Waiter.initSelect(&waiter, &winner, &gen, &pending_winner, i);
    }

    var registered = [_]bool{false} ** field_names.len;
    // Signals sent (or in flight) for registrations that were popped without a
    // claim, reported via .requeued/.ready_signaled. The settle phase must
    // outwait them before the frame can be released.
    var prior_signals: u32 = 0;
    // The winning arm claimed itself in our own sweep, so no claim signal
    // exists for it.
    var self_claimed = false;
    // The winner came from a fence bounce we promoted. Its signal accounting
    // is left to its own source in the settle loop below, because a re-poll
    // may already have counted that signal via .requeued.
    var promoted = false;
    var decided = false;

    // Registration sweep. On a first call .requeued means .queued and
    // .ready_signaled means .ready: a first registration has no earlier
    // signal (the source cannot tell a first call apart; we can).
    sweep: inline for (field_names, field_types, 0..) |name, FieldType, i| {
        const state = if (comptime hasWaitContext(FieldType))
            @field(futures, name).asyncWait(&waiters[i], &@field(contexts, name))
        else
            @field(futures, name).asyncWait(&waiters[i]);
        switch (state) {
            .ready, .ready_signaled => {
                self_claimed = true;
                decided = true;
                break :sweep;
            },
            .queued, .requeued => registered[i] = true,
            .decided => {
                decided = true;
                break :sweep;
            },
        }
    }

    const Poll = struct {
        /// Re-poll every registered arm. Returns true once the select is
        /// decided (an arm claimed itself, or an external claim won).
        fn repoll(
            futs: *const S,
            ws: *[field_names.len]Waiter,
            ctxs: *ContextsType,
            reg: *const [field_names.len]bool,
            prior: *u32,
            selfc: *bool,
        ) bool {
            inline for (field_names, field_types, 0..) |name, FieldType, i| {
                if (reg[i]) {
                    const state = if (comptime hasWaitContext(FieldType))
                        @field(futs.*, name).asyncWait(&ws[i], &@field(ctxs.*, name))
                    else
                        @field(futs.*, name).asyncWait(&ws[i]);
                    switch (state) {
                        .ready => {
                            selfc.* = true;
                            return true;
                        },
                        .ready_signaled => {
                            prior.* += 1;
                            selfc.* = true;
                            return true;
                        },
                        .queued => {},
                        .requeued => prior.* += 1,
                        .decided => return true,
                    }
                }
            }
            return false;
        }
    };

    var canceled = false;
    if (!decided) {
        // Wakes consumed without finding a winner (a claimer saw our commit
        // fence and signaled without claiming); each raises the next wait
        // threshold by one.
        var consumed_wakes: u32 = 0;
        var gen_seen: u32 = 0;
        park: while (true) {
            // The sweep, or the re-poll below, may have just released the
            // fence a notification bounced off. Promote before parking.
            if (Waiter.promotePending(&winner, &pending_winner)) {
                promoted = true;
                break :park;
            }
            const g = gen.load(.seq_cst);
            if (g != gen_seen) {
                // Someone interacted with an arm while the sweep or an
                // earlier re-poll held the commit fence. A rendezvous peer
                // that skipped us may be parked by now; re-poll before we
                // park, or both sides sleep through a valid pairing.
                gen_seen = g;
                if (Poll.repoll(&futures, &waiters, &contexts, &registered, &prior_signals, &self_claimed)) break :park;
                continue :park;
            }
            waiter.wait(consumed_wakes + 1, .allow_cancel) catch {
                canceled = true;
                break :park;
            };
            if (winner.load(.acquire) != NO_WINNER) break :park;
            // A bounce that landed just as the fence went down would have
            // missed the promotion above; this is the wake it sent.
            if (Waiter.promotePending(&winner, &pending_winner)) {
                promoted = true;
                break :park;
            }
            // A signal landed without a claim: the claimer saw our commit
            // fence. The readiness it reported is standing; re-poll finds it.
            consumed_wakes += 1;
            if (Poll.repoll(&futures, &waiters, &contexts, &registered, &prior_signals, &self_claimed)) break :park;
        }
    }

    // Settle: cancel losing registrations, then outwait every signal sent for
    // this frame. A claim can land during the cancel loop, so the final
    // winner decision comes after it (#700: a claimed result is delivered,
    // never dropped, even on the cancellation path).
    const hint = winner.load(.acquire);
    // A promoted winner goes through the cancel loop like a loser, because
    // only its source can say whether its bounced signal is still owed: a
    // re-poll may have already re-registered the arm and counted that signal
    // as .requeued, in which case asyncCancelWait removes the new
    // registration and reports nothing owed.
    const settled = if (promoted) NO_WINNER else hint;
    var expected: u32 = prior_signals;
    inline for (field_names, field_types, 0..) |name, FieldType, i| {
        if (registered[i] and i != settled) {
            const was_removed = if (comptime hasWaitContext(FieldType))
                @field(futures, name).asyncCancelWait(&waiters[i], &@field(contexts, name))
            else
                @field(futures, name).asyncCancelWait(&waiters[i]);
            if (!was_removed) expected += 1;
        }
    }
    // An external winner's claim carries one signal; a self-claimed win sends
    // none, and a promoted one was just accounted for above.
    if (hint != NO_WINNER and !self_claimed and !promoted) expected += 1;
    waiter.wait(expected, .no_cancel);

    const winner_index = winner.load(.acquire);
    if (winner_index == NO_WINNER) {
        std.debug.assert(canceled);
        return error.Canceled;
    }

    // On the canceled path the cancelable wait above consumed the
    // cancellation request; the claimed result still gets delivered, so put
    // the request back for the next cancelable operation. A null task
    // binding means the wait blocked the thread and consumed nothing.
    if (canceled) {
        if (waiter.mode.direct.task) |t| t.recancel();
    }

    // Return result from winner.
    inline for (field_names, field_types, 0..) |name, FieldType, i| {
        if (i == winner_index) {
            const result = if (comptime hasWaitContext(FieldType))
                @field(futures, name).getResult(&@field(contexts, name))
            else
                @field(futures, name).getResult();
            return @unionInit(U, name, result);
        }
    }

    // Should never reach here - the winner index is always a valid arm
    unreachable;
}

/// Select on a runtime slice of type-erased Awaitables.
/// Returns the index of the first awaitable to complete.
/// Used by std.Io.selectImpl.
pub fn selectAwaitables(awaitables: []const *Awaitable) Cancelable!usize {
    const max_awaitables = 64;
    if (awaitables.len > max_awaitables) {
        @panic("selectAwaitables: too many awaitables (max 64)");
    }

    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var gen: std.atomic.Value(u32) = .init(0);
    // Never written here: this select takes no commit fence (no channel
    // arms), so no notification can bounce. Present only to build the arms.
    var pending_winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiter = Waiter.init();
    var waiters: [max_awaitables]Waiter = undefined;

    for (waiters[0..awaitables.len], 0..) |*w, i| {
        w.* = Waiter.initSelect(&waiter, &winner, &gen, &pending_winner, i);
    }

    var registered = [_]bool{false} ** max_awaitables;
    var self_claimed = false;
    var decided = false;

    // Registration sweep. Awaitables are level sources: on a first call
    // .requeued means .queued and .ready_signaled means .ready.
    for (awaitables, waiters[0..awaitables.len], 0..) |awaitable, *w, i| {
        switch (awaitable.asyncWait(w)) {
            .ready, .ready_signaled => {
                self_claimed = true;
                decided = true;
            },
            .queued, .requeued => registered[i] = true,
            .decided => decided = true,
        }
        if (decided) break;
    }

    var canceled = false;
    if (!decided) {
        // This select never takes the commit fence (no channel arms), so
        // every completion's claim resolves to won or lost and a wake always
        // carries a decided winner; no re-poll loop is needed.
        waiter.wait(1, .allow_cancel) catch {
            canceled = true;
        };
    }

    // Settle: cancel losing registrations, then outwait in-flight signals. A
    // claim can land during the cancel loop, so the final winner decision
    // comes after it; a canceled select with a claimed winner reports the
    // winner (#700), and result extraction belongs to the caller.
    const hint = winner.load(.acquire);
    var expected: u32 = 0;
    for (awaitables, waiters[0..awaitables.len], 0..) |awaitable, *w, i| {
        if (registered[i] and i != hint) {
            if (!awaitable.asyncCancelWait(w)) expected += 1;
        }
    }
    if (hint != NO_WINNER and !self_claimed) expected += 1;
    waiter.wait(expected, .no_cancel);

    const winner_index = winner.load(.acquire);
    if (winner_index == NO_WINNER) {
        std.debug.assert(canceled);
        return error.Canceled;
    }
    // The cancelable wait consumed the cancellation request but a claimed
    // winner is still being reported; re-arm it for the next cancelable
    // operation. A null task binding means the wait blocked the thread and
    // consumed nothing.
    if (canceled) {
        if (waiter.mode.direct.task) |t| t.recancel();
    }
    return winner_index;
}

/// Internal wait implementation with configurable cancellation behavior.
fn waitInternal(future: anytype, comptime flags: WaitFlags) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    // Self-wait detection: only meaningful inside a task context.
    if (getCurrentTaskOrNull()) |task| {
        checkSelfWait(task, future);
    }

    var waiter = Waiter.init();

    // Allocate WaitContext if needed
    const WaitCtx = FutureWaitContext(@TypeOf(future));
    var context: WaitCtx = if (WaitCtx == void) {} else .{};
    const has_context = comptime (WaitCtx != void);

    // Fast path: check if already complete. A direct waiter cannot lose a
    // claim, so .decided is unreachable, and a first registration has no
    // earlier signal, so .requeued/.ready_signaled degrade to their plain
    // forms.
    var fut = future;
    const state = if (has_context)
        fut.asyncWait(&waiter, &context)
    else
        fut.asyncWait(&waiter);

    switch (state) {
        .ready, .ready_signaled => {
            const result = if (has_context) fut.getResult(&context) else fut.getResult();
            return .{ .value = result };
        },
        .queued, .requeued => {},
        .decided => unreachable,
    }

    // Clean up waiter on exit
    defer {
        const was_removed = if (has_context)
            fut.asyncCancelWait(&waiter, &context)
        else
            fut.asyncCancelWait(&waiter);

        if (!was_removed) {
            // Wake is in-flight, wait for it to complete (1 signal expected)
            waiter.wait(1, .no_cancel);
        }
    }

    if (flags.on_cancel == .cancel_and_continue) {
        // Wait with cancellation enabled first
        waiter.wait(1, .allow_cancel) catch |err| switch (err) {
            error.Canceled => {
                // On cancellation, cancel child and wait for completion
                fut.cancel();
                waiter.wait(1, .no_cancel);
                const result = if (has_context) fut.getResult(&context) else fut.getResult();
                return .{ .value = result };
            },
        };
    } else {
        // Propagate cancellation to caller (Waiter.wait handles spurious wakeups)
        try waiter.wait(1, .allow_cancel);
    }

    const result = if (has_context) fut.getResult(&context) else fut.getResult();
    return .{ .value = result };
}

/// Wait for a single future to complete.
/// Similar to select() but for a single future, returns the result.
/// `future` must be a pointer to a future type.
/// Works from both coroutines and threads.
/// Returns Cancelable error if the task is canceled while waiting (coroutine only).
///
/// Example:
/// ```
/// // For Future(error{Foo}!i32)
/// const result = try wait(&future); // returns Cancelable!WaitResult(error{Foo}!i32)
/// const value = try result.value; // handle the inner error union
/// ```
pub fn wait(future: anytype) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    return waitInternal(future, .{ .on_cancel = .propagate });
}

/// Wait for a single future to complete, never propagating cancellation.
/// When canceled, cancels the child task and continues waiting with shield enabled.
/// This ensures the function always returns a result and never returns error.Canceled.
/// `future` must be a pointer to a future type.
/// Works from both coroutines and threads.
///
/// Example:
/// ```
/// const value = waitUntilComplete(&future); // never returns error.Canceled
/// // value is directly FutureResult (e.g., error{Foo}!i32)
/// ```
pub fn waitUntilComplete(future: anytype) FutureResult(@TypeOf(future)) {
    const result = waitInternal(future, .{ .on_cancel = .cancel_and_continue }) catch unreachable;
    return result.value;
}

test "select: basic - first completes" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const slowTask = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 42;
        }
    }.call;

    const fastTask = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(10));
            return 99;
        }
    }.call;

    var slow = try runtime.spawn(slowTask, .{runtime});
    defer slow.cancel();
    var fast = try runtime.spawn(fastTask, .{runtime});
    defer fast.cancel();

    const result = try select(.{ .fast = &fast, .slow = &slow });
    switch (result) {
        .slow => |val| try std.testing.expectEqual(42, val),
        .fast => |val| try std.testing.expectEqual(99, val),
    }
    // Fast should win
    try std.testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
}

test "select: already complete - fast path" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const immediateTask = struct {
        fn call() i32 {
            return 123;
        }
    }.call;

    const slowTask = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 456;
        }
    }.call;

    var immediate = try runtime.spawn(immediateTask, .{});
    defer immediate.cancel();

    // Give immediate task a chance to complete
    try yield();
    try yield();

    var slow = try runtime.spawn(slowTask, .{runtime});
    defer slow.cancel();

    // immediate should already be complete, select should return immediately
    const result = try select(.{ .immediate = &immediate, .slow = &slow });
    switch (result) {
        .immediate => |val| try std.testing.expectEqual(123, val),
        .slow => return error.TestUnexpectedResult,
    }
}

test "select: heterogeneous types" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const intTask = struct {
        fn call(rt: *Runtime) Cancelable!i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 42;
        }
    }.call;

    const stringTask = struct {
        fn call(rt: *Runtime) Cancelable![]const u8 {
            try rt.sleep(.fromMilliseconds(10));
            return "hello";
        }
    }.call;

    const boolTask = struct {
        fn call(rt: *Runtime) Cancelable!bool {
            try rt.sleep(.fromMilliseconds(150));
            return true;
        }
    }.call;

    var int_handle = try runtime.spawn(intTask, .{runtime});
    defer int_handle.cancel();
    var string_handle = try runtime.spawn(stringTask, .{runtime});
    defer string_handle.cancel();
    var bool_handle = try runtime.spawn(boolTask, .{runtime});
    defer bool_handle.cancel();

    const result = try select(.{
        .string = &string_handle,
        .int = &int_handle,
        .bool = &bool_handle,
    });

    switch (result) {
        .int => |val| {
            try std.testing.expectEqual(42, try val);
            return error.TestUnexpectedResult; // Should not complete first
        },
        .string => |val| {
            try std.testing.expectEqualStrings("hello", try val);
            // This should win
        },
        .bool => |val| {
            try std.testing.expectEqual(true, try val);
            return error.TestUnexpectedResult; // Should not complete first
        },
    }
}

test "select: with cancellation" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const slowTask1 = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(1000));
            return 1;
        }
    }.call;

    const slowTask2 = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(1000));
            return 2;
        }
    }.call;

    const selectTask = struct {
        fn call(rt: *Runtime) !i32 {
            var h1 = try rt.spawn(slowTask1, .{rt});
            defer h1.cancel();
            var h2 = try rt.spawn(slowTask2, .{rt});
            defer h2.cancel();

            const result = try select(.{ .first = &h1, .second = &h2 });
            return switch (result) {
                .first => |v| v,
                .second => |v| v,
            };
        }
    }.call;

    var select_handle = try runtime.spawn(selectTask, .{runtime});
    defer select_handle.cancel();

    // Give it a chance to start waiting
    try yield();
    try yield();

    // Cancel the select operation
    select_handle.cancel();

    // Should return error.Canceled
    const result = select_handle.join();
    try std.testing.expectError(error.Canceled, result);
}

test "select: with error unions - success case" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ParseError = error{ InvalidFormat, OutOfRange };
    const ValidationError = error{ TooShort, TooLong };

    const parseTask = struct {
        fn call(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 42;
        }
    }.call;

    const validateTask = struct {
        fn call(rt: *Runtime) (ValidationError || Cancelable)![]const u8 {
            try rt.sleep(.fromMilliseconds(10));
            return "valid";
        }
    }.call;

    var parse_handle = try runtime.spawn(parseTask, .{runtime});
    defer parse_handle.cancel();
    var validate_handle = try runtime.spawn(validateTask, .{runtime});
    defer validate_handle.cancel();

    const result = try select(.{
        .validate = &validate_handle,
        .parse = &parse_handle,
    });

    // Result is a union where each field has the original error type
    switch (result) {
        .parse => |val_or_err| {
            // val_or_err is ParseError!i32
            const val = val_or_err catch |err| {
                try std.testing.expect(false); // Should not error
                return err;
            };
            try std.testing.expectEqual(42, val);
            return error.TestUnexpectedResult; // validate should win
        },
        .validate => |val_or_err| {
            // val_or_err is ValidationError![]const u8
            const val = val_or_err catch |err| {
                try std.testing.expect(false); // Should not error
                return err;
            };
            try std.testing.expectEqualStrings("valid", val);
            // This should win
        },
    }
}

test "select: with error unions - error case" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ParseError = error{ InvalidFormat, OutOfRange };

    const failingTask = struct {
        fn call(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(.fromMilliseconds(10));
            return error.OutOfRange;
        }
    }.call;

    const slowTask = struct {
        fn call(rt: *Runtime) !i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 99;
        }
    }.call;

    var failing = try runtime.spawn(failingTask, .{runtime});
    defer failing.cancel();
    var slow = try runtime.spawn(slowTask, .{runtime});
    defer slow.cancel();

    const result = try select(.{ .failing = &failing, .slow = &slow });

    switch (result) {
        .failing => |val_or_err| {
            // val_or_err is ParseError!i32
            _ = val_or_err catch |err| {
                // Should receive the original error
                try std.testing.expectEqual(ParseError.OutOfRange, err);
                return;
            };
            return error.TestUnexpectedResult; // Should have errored
        },
        .slow => |val| {
            try std.testing.expectEqual(99, val);
            return error.TestUnexpectedResult; // failing should win
        },
    }
}

test "select: with mixed error types" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const ParseError = error{ InvalidFormat, OutOfRange };
    const IOError = error{ FileNotFound, PermissionDenied };

    const task1 = struct {
        fn call(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(.fromMilliseconds(100));
            return 100;
        }
    }.call;

    const task2 = struct {
        fn call(rt: *Runtime) (IOError || Cancelable)![]const u8 {
            try rt.sleep(.fromMilliseconds(10));
            return error.FileNotFound;
        }
    }.call;

    const task3 = struct {
        fn call(rt: *Runtime) !bool {
            try rt.sleep(.fromMilliseconds(150));
            return true;
        }
    }.call;

    var h1 = try runtime.spawn(task1, .{runtime});
    defer h1.cancel();
    var h2 = try runtime.spawn(task2, .{runtime});
    defer h2.cancel();
    var h3 = try runtime.spawn(task3, .{runtime});
    defer h3.cancel();

    // select returns Cancelable!SelectUnion(...)
    // SelectUnion has: { .h2: IOError![]const u8, .h1: ParseError!i32, .h3: bool }
    const result = try select(.{ .h2 = &h2, .h1 = &h1, .h3 = &h3 });

    switch (result) {
        .h1 => |val_or_err| {
            _ = val_or_err catch return error.TestUnexpectedResult;
            return error.TestUnexpectedResult;
        },
        .h2 => |val_or_err| {
            // val_or_err is IOError![]const u8
            _ = val_or_err catch |err| {
                // Verify we got the original error type
                try std.testing.expectEqual(IOError.FileNotFound, err);
                return; // This is expected
            };
            return error.TestUnexpectedResult; // Should have errored
        },
        .h3 => |val| {
            try std.testing.expectEqual(true, val);
            return error.TestUnexpectedResult;
        },
    }
}

test "wait: plain type" {
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var future = Future(i32).init;

    // Spawn task to set the future
    var task = try runtime.spawn(struct {
        fn run(f: *Future(i32)) !void {
            f.set(42);
        }
    }.run, .{&future});
    defer task.cancel();

    // Wait for the future
    const result = try wait(&future);
    try std.testing.expectEqual(42, result.value);
}

test "wait: error union" {
    const Future = @import("sync/future.zig").Future;
    const MyError = error{Foo};

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var future = Future(MyError!i32).init;

    // Spawn task to set the future with success
    var task = try runtime.spawn(struct {
        fn run(f: *Future(MyError!i32)) !void {
            f.set(123);
        }
    }.run, .{&future});
    defer task.cancel();

    // Wait for the future
    const result = try wait(&future);
    const value = try result.value;
    try std.testing.expectEqual(123, value);
}

test "wait: error union with error" {
    const Future = @import("sync/future.zig").Future;
    const MyError = error{Foo};

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var future = Future(MyError!i32).init;

    // Spawn task to set the future with error
    var task = try runtime.spawn(struct {
        fn run(f: *Future(MyError!i32)) !void {
            f.set(MyError.Foo);
        }
    }.run, .{&future});
    defer task.cancel();

    // Wait for the future
    const result = try wait(&future);
    try std.testing.expectError(MyError.Foo, result.value);
}

test "wait: already complete (fast path)" {
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var future = Future(i32).init;
    future.set(99);

    // Wait should return immediately since already set
    const result = try wait(&future);
    try std.testing.expectEqual(99, result.value);
}

test "select: wait on JoinHandle from spawned task" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const workerTask = struct {
        fn call(rt: *Runtime, value: i32) !i32 {
            try rt.sleep(.fromMilliseconds(10));
            return value * 2;
        }
    }.call;

    // Spawn a task and get a JoinHandle
    var handle1 = try runtime.spawn(workerTask, .{ runtime, 21 });
    defer handle1.cancel();

    var handle2 = try runtime.spawn(workerTask, .{ runtime, 100 });
    defer handle2.cancel();

    // Wait on JoinHandles using select
    const result = try select(.{
        .first = &handle1,
        .second = &handle2,
    });

    // Verify we got a result
    switch (result) {
        .first => |val| {
            try std.testing.expectEqual(42, val);
        },
        .second => |val| {
            try std.testing.expectEqual(200, val);
        },
    }

    // Both should be valid results, though timing determines which completes first
    try std.testing.expect(std.meta.activeTag(result) == .first or std.meta.activeTag(result) == .second);
}

test "select: promotes a notification that bounced off the commit fence" {
    // End-to-end cover for the promotion path in select() itself: a synthetic
    // arm reproduces a channel rendezvous commit window (take the fence, do
    // work, abort) and, from inside it, fires a second arm whose readiness
    // then lapses. Only the recorded arm can deliver that event; a re-poll
    // cannot, because the event was reset.
    //
    // The synthetic arm becomes ready on its second poll, so a regression in
    // the promotion or settle wiring shows up as the wrong arm winning rather
    // than as a hang.
    const ResetEvent = @import("sync/ResetEvent.zig");

    const FenceArm = struct {
        event: *ResetEvent,

        pub const Result = void;
        pub const WaitContext = struct { fenced: bool = false };

        pub fn asyncWait(self: *@This(), waiter: *Waiter, ctx: *WaitContext) common.AsyncWaitState {
            if (ctx.fenced) {
                // Second poll: only reached if the recorded arm was dropped.
                return switch (waiter.tryClaim()) {
                    .won => .ready,
                    .busy => unreachable,
                    .lost => .decided,
                };
            }
            ctx.fenced = true;
            if (!waiter.beginCommit()) return .decided;
            // The event's signal lands while the fence is up, so its winner
            // CAS bounces; the reset then removes every trace of it except
            // the record the bounce left behind.
            self.event.set();
            self.event.reset();
            waiter.abortCommit();
            return .queued;
        }

        pub fn asyncCancelWait(self: *@This(), waiter: *Waiter, ctx: *WaitContext) bool {
            _ = self;
            _ = waiter;
            _ = ctx;
            return true; // never registered on a queue, so nothing is owed
        }

        pub fn getResult(self: *const @This(), ctx: *WaitContext) void {
            _ = self;
            _ = ctx;
        }
    };

    const Body = struct {
        fn run() !void {
            var event = ResetEvent.init;
            var fence_arm = FenceArm{ .event = &event };

            const result = try select(.{ .event = &event, .fence = &fence_arm });
            try std.testing.expectEqual(
                std.meta.Tag(@TypeOf(result)).event,
                std.meta.activeTag(result),
            );
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer runtime.deinit();
    var handle = try runtime.spawn(Body.run, .{});
    try handle.join();
}
