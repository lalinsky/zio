// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTask = @import("runtime.zig").getCurrentTask;
const getCurrentTaskOrNull = @import("runtime.zig").getCurrentTaskOrNull;
const yield = @import("runtime.zig").yield;
const random = @import("random.zig").random;
const common = @import("common.zig");
const Cancelable = common.Cancelable;
const Waiter = common.Waiter;
const NO_WINNER = common.NO_WINNER;
const AnyTask = @import("task.zig").AnyTask;
const meta = @import("meta.zig");

// AsyncWait protocol - a type can be used with select() and wait() iff it
// declares a nested `AsyncWait` namespace:
//
//   pub const AsyncWait = struct {
//       /// What a committed wait on this source yields.
//       pub const Result = T;
//
//       /// Per-operation state, allocated in the waiting frame and always
//       /// passed to prepare/commit/rollback. Use `struct {}` when empty.
//       pub const Context = ...;
//
//       /// True if peers may decide a select containing this arm from the
//       /// outside, through `claimArm`. Channel rendezvous arms set this:
//       /// a peer can complete a queued send or receive directly. A select
//       /// containing a claimable arm compiles in the winner-word fence; one
//       /// without never consults the winner word.
//       pub const claimable = false;   // optional, defaults to false
//
//       pub fn prepare(self: *Source, waiter: *Waiter, ctx: *Context) Prepare
//       pub fn commit(self: *Source, waiter: *Waiter, ctx: *Context) CommitResult(Result)
//       pub fn rollback(self: *Source, waiter: *Waiter, ctx: *Context) Rollback
//   };
//
// prepare - register as a candidate, unless already complete. The check and
// the registration are fused under the source's lock: `.ready` means the
// operation can complete right now and nothing was registered; `.pending`
// means the waiter is queued and a notification follows if the source becomes
// ready or closes. Called only on unregistered arms; never consumes.
//
// commit - the consume, under the source's lock: take the item, swap the
// counter, pop the completion. Called on an arm that prepared `.ready`, on an
// arm whose notification the caller consumed, or on an arm decided externally
// (a claimed send arm reports the outcome its claimer left in ctx). If
// readiness decayed, commit installs a new registration and returns `.pending`.
// A pending result may carry one deferred notification; the driver first
// publishes the arm as pending and releases the COMMITTING fence, then signals
// that waiter. This ordering is used by rendezvous channels to park one side
// before nudging a busy select peer.
//
// rollback - abandon a losing pending or notified attempt, under the source's
// lock. `.removed`: the registration was removed cleanly and no notification
// will come. `.signal_in_flight`: a notifier already consumed the
// registration, and exactly one signal is landed or in flight. Rollback must
// also release any readiness offer/reservation and hand it to another waiter.
// It is called for notified losers even though their registration is gone.
//
// Notification discipline: a source dequeues a registration exactly once,
// and, per dequeue, sets the waiter's notified flag and signals exactly once
// (`Waiter.signal` does both). A notification carries no decision, it only
// means "this arm's registration was consumed; try commit again".
// The select loop owns all remaining bookkeeping: which arms are registered,
// which notifications it has consumed, and how many signals to absorb before
// returning.
//
// The one externally decided case is a claimable arm: a rendezvous peer wins
// the select's winner word through `claimArm` under the channel lock, records
// the outcome in the arm's ctx, and then notifies. Every other notifier leaves
// the outcome at the source.
//
// Lifetime: sources must outlive the select()/wait() call using them.
// Completion paths that can free the source after waking its waiters
// (ResetEvent.set and friends) must not touch the source after signaling the
// last waiter; the waiting side may touch the source until its wait returns.

/// Result of `AsyncWait.prepare`.
pub const Prepare = enum {
    /// The operation can complete right now; nothing was registered.
    ready,
    /// The waiter was registered; a notification follows when the source
    /// becomes ready or closes.
    pending,
};

pub const Pending = struct {
    /// A registration consumed while this operation parked. The driver sends
    /// this notification only after publishing its own pending state and
    /// releasing the select commit fence.
    notify: ?*Waiter = null,
};

/// Result of the consuming phase. A tagged union keeps protocol pending
/// separate from operation results that may themselves contain optional or
/// error-union values (including an application-level `error.Retry`).
pub fn CommitResult(comptime Result: type) type {
    return union(enum) {
        pending: Pending,
        done: Result,
    };
}

test "CommitResult keeps protocol pending separate from user results" {
    const ErrorResult = CommitResult(error{Retry}!u8);
    const application_retry: ErrorResult = .{ .done = error.Retry };
    switch (application_retry) {
        .done => |result| try std.testing.expectError(error.Retry, result),
        .pending => return error.TestUnexpectedResult,
    }

    const OptionalResult = CommitResult(?u8);
    const application_null: OptionalResult = .{ .done = null };
    switch (application_null) {
        .done => |result| try std.testing.expectEqual(null, result),
        .pending => return error.TestUnexpectedResult,
    }
}

/// Result of abandoning an active wait attempt.
pub const Rollback = enum {
    /// The registration was removed, or had never been queued. No signal is
    /// owed for this attempt.
    removed,
    /// A notifier consumed the registration. Exactly one signal is already
    /// landed or will land, and must be absorbed before the waiter can die.
    signal_in_flight,
};

// Winner-word states. NO_WINNER (common.zig) means undecided and an arm index
// means decided; the values and transitions are owned here. The sentinels:
// COMMITTING is held by the select's own sweep while an arm's commit may
// consume, CANCELED is set by the cancel path and means the select will never
// commit.
const COMMITTING = std.math.maxInt(usize) - 1;
const CANCELED = std.math.maxInt(usize) - 2;

pub const ClaimResult = enum {
    /// The claim landed (direct waiters are always won). The claimer must
    /// complete the committed side effect under the source lock, record the
    /// outcome in the arm's ctx, dequeue the registration and notify.
    won,
    /// The select's own sweep holds the fence right now. The claimer must
    /// not consume. A blocking rendezvous may park itself, dequeue this
    /// registration, and return a deferred notification so the select tries
    /// commit on the arm after the requester is externally claimable.
    busy,
    /// The select is already decided (another arm won, or it canceled). Skip
    /// the registration in place; the select's cleanup removes it.
    lost,
};

/// Decide a select from the outside. This is the single external entry point
/// into select arbitration, used only for parked channel rendezvous arms. Must
/// be called under the same source lock that guards the arm's registration and
/// rollback.
pub fn claimArm(waiter: *Waiter) ClaimResult {
    switch (waiter.mode) {
        .direct => return .won,
        .select => |*s| {
            const cur = s.winner.cmpxchgStrong(NO_WINNER, s.index, .acq_rel, .acquire) orelse return .won;
            return if (cur == COMMITTING) .busy else .lost;
        },
    }
}

/// Non-committal read of an arm's arbitration state, for a source deciding
/// whether a parked registration is worth reporting as ready. Racy by nature:
/// the consuming path re-checks through `claimArm`. `.won` means open.
pub fn peekArm(waiter: *Waiter) ClaimResult {
    switch (waiter.mode) {
        .direct => return .won,
        .select => |*s| {
            const cur = s.winner.load(.acquire);
            if (cur == NO_WINNER) return .won;
            return if (cur == COMMITTING) .busy else .lost;
        },
    }
}

/// Consume a select arm's notification. Owned by the select loop; a consumed
/// notification means the arm is unregistered and ready for commit.
fn consumeNotified(waiter: *Waiter) bool {
    return waiter.mode.select.notified.swap(false, .acq_rel);
}

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

fn AsyncWaitOf(comptime future_type: type) type {
    return FutureType(future_type).AsyncWait;
}

/// Extract the Result type from a future (pointer or value)
fn FutureResult(comptime future_type: type) type {
    return AsyncWaitOf(future_type).Result;
}

/// Extract the Context type from a future (pointer or value)
fn FutureContext(comptime future_type: type) type {
    return AsyncWaitOf(future_type).Context;
}

fn isClaimable(comptime future_type: type) bool {
    const AW = AsyncWaitOf(future_type);
    return @hasDecl(AW, "claimable") and AW.claimable;
}

fn anyClaimable(comptime futures_type: type) bool {
    for (@typeInfo(futures_type).@"struct".fields) |field| {
        if (isClaimable(field.type)) return true;
    }
    return false;
}

/// Check for self-wait deadlock if the future has a toAwaitable() method
fn checkSelfWait(task: *AnyTask, future: anytype) void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (std.meta.hasMethod(@TypeOf(future), "toAwaitable")) {
            const awaitable_ptr = future.toAwaitable();
            if (awaitable_ptr == &task.awaitable) {
                std.debug.panic("cannot wait on self (would deadlock)", .{});
            }
        }
    }
}

/// Build a struct type containing one Context field per future.
fn WaitContextsType(comptime futures_type: type) type {
    const fields = @typeInfo(futures_type).@"struct".fields;

    var field_names: [fields.len][:0]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;

    comptime var i: usize = 0;
    inline for (fields) |field| {
        const Context = FutureContext(field.type);
        const default_value: Context = .{};
        field_names[i] = field.name;
        field_types[i] = Context;
        field_attrs[i] = .{ .default_value_ptr = @ptrCast(&default_value) };
        i += 1;
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn ResultSlot(comptime Result: type) type {
    return struct { value: Result };
}

/// Build a struct type with an optional result wrapper per arm, all defaulting
/// to null. The wrapper keeps "no committed result" distinct from a legitimate
/// optional Result whose value is null. Results are stored here at commit time,
/// because signals may still be in flight when an arm commits and the frame
/// must not return until they are absorbed.
fn ResultsType(comptime futures_type: type) type {
    const fields = @typeInfo(futures_type).@"struct".fields;

    var field_names: [fields.len][:0]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    var field_attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;

    comptime var i: usize = 0;
    inline for (fields) |field| {
        const R = ?ResultSlot(FutureResult(field.type));
        const default_value: R = null;
        field_names[i] = field.name;
        field_types[i] = R;
        field_attrs[i] = .{
            .default_value_ptr = @ptrCast(&default_value),
        };
        i += 1;
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
    const struct_fields = @typeInfo(S).@"struct".fields;

    var field_names: [struct_fields.len][:0]const u8 = undefined;
    var field_types: [struct_fields.len]type = undefined;
    var field_attrs: [struct_fields.len]std.builtin.Type.UnionField.Attributes = undefined;

    for (struct_fields, 0..) |struct_field, i| {
        field_names[i] = struct_field.name;
        field_types[i] = FutureResult(struct_field.type);
        field_attrs[i] = .{};
    }

    return @Union(.auto, std.meta.FieldEnum(S), &field_names, &field_types, &field_attrs);
}

test "SelectResult: result types" {
    const Future1 = struct {
        pub const AsyncWait = struct {
            pub const Result = void;
            pub const Context = struct {};
        };
    };
    const Future2 = struct {
        pub const AsyncWait = struct {
            pub const Result = u32;
            pub const Context = struct {};
        };
    };

    const Select = SelectResult(struct {
        future1: *Future1,
        future2: *Future2,
    });

    _ = Select{ .future1 = {} };
    _ = Select{ .future2 = 32 };
}

/// Reshuffle the sweep order (Fisher-Yates over per-round random bytes).
fn shuffle(order: []usize) void {
    if (order.len < 2) return;
    std.debug.assert(order.len <= 64);
    var bytes: [64]u8 = undefined;
    random(bytes[0..order.len]);
    var i: usize = order.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = bytes[i] % @as(u8, @intCast(i + 1));
        std.mem.swap(usize, &order[i], &order[j]);
    }
}

const ArmPhase = enum { inactive, pending, ready };

/// Loop-owned state for one prepare/commit attempt. A ready arm with
/// `signal_expected` came from a notification; its losing rollback may report
/// `.signal_in_flight`, but that signal is already included in the select's
/// expected-signal count.
const ArmState = struct {
    phase: ArmPhase = .inactive,
    signal_expected: bool = false,
};

/// Wait for multiple futures simultaneously and return whichever completes first.
///
/// `futures` is a struct with each field being either:
/// - A pointer to a future (e.g., `*JoinHandle(T)`) for futures that mutate self
/// - A value future (e.g., `channel.asyncReceive()`) for futures using a Context
///
/// Returns a tagged union with the same field names, containing the result of
/// whichever completed first. When several arms are ready in the same round, a
/// random one wins. A select may contain at most 64 arms; larger selects fail
/// at compile time.
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
    const fields = @typeInfo(S).@"struct".fields;
    const has_claimable = comptime anyClaimable(S);

    if (fields.len > 64) @compileError("select: too many arms (max 64)");

    // Self-wait detection: check all futures for self-wait
    const task = getCurrentTask();
    inline for (fields) |field| {
        checkSelfWait(task, @field(futures, field.name));
    }

    // Winner word: consulted only when a claimable arm exists; everything else
    // is decided by the sweep alone.
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);

    // Parent waiter that arm notifications land on
    var parent = Waiter.init();

    // Allocate Context struct on stack for futures that need per-wait state
    const ContextsType = WaitContextsType(S);
    var contexts: ContextsType = .{};

    var results: ResultsType(S) = .{};

    var waiters: [fields.len]Waiter = undefined;
    inline for (&waiters, 0..) |*w, i| {
        w.* = Waiter.initSelect(&parent, &winner, i);
    }

    var states: [fields.len]ArmState = @splat(.{});
    var order: [fields.len]usize = undefined;
    inline for (&order, 0..) |*slot, i| slot.* = i;

    // Signals accounted for so far: one per consumed notification. Each round
    // parks until one more lands.
    var signals_expected: u32 = 0;
    var deliver_recancel = false;

    const winner_index: usize = main: while (true) {
        shuffle(&order);
        sweep: for (order) |arm| {
            inline for (fields, 0..) |field, i| {
                if (arm == i) {
                    if (states[i].phase == .pending) {
                        // Registered arms are dormant until notified; a
                        // consumed notification means the registration is
                        // gone and the arm must re-run prepare/commit.
                        if (!consumeNotified(&waiters[i])) continue :sweep;
                        signals_expected += 1;
                        states[i] = .{ .phase = .ready, .signal_expected = true };
                    }
                    var future = @field(futures, field.name);
                    const fp = if (comptime isPointerFuture(field.type)) future else &future;
                    while (true) {
                        if (states[i].phase == .inactive) {
                            const prep = AsyncWaitOf(field.type).prepare(fp, &waiters[i], &@field(contexts, field.name));
                            if (prep == .pending) {
                                states[i] = .{ .phase = .pending };
                                continue :sweep;
                            }
                            states[i] = .{ .phase = .ready };
                        }
                        // Ready: commit, holding the fence so no peer can
                        // decide a claimable arm while this one consumes.
                        if (has_claimable) {
                            if (winner.cmpxchgStrong(NO_WINNER, COMMITTING, .acq_rel, .acquire)) |decided| {
                                std.debug.assert(decided < fields.len);
                                break :main decided;
                            }
                        }
                        const committed = AsyncWaitOf(field.type).commit(fp, &waiters[i], &@field(contexts, field.name));
                        switch (committed) {
                            .done => |value| {
                                states[i] = .{};
                                if (has_claimable) winner.store(i, .release);
                                @field(results, field.name) = .{ .value = value };
                                break :main i;
                            },
                            .pending => |pending| {
                                states[i] = .{ .phase = .pending };
                                if (has_claimable) winner.store(NO_WINNER, .release);
                                if (pending.notify) |notified| notified.signal();
                                continue :sweep;
                            },
                        }
                    }
                }
            }
        }

        parent.wait(signals_expected + 1, .allow_cancel) catch {
            if (has_claimable) {
                // A claim that landed before this transition decided the
                // select: its arm consumed on our behalf, so the result must
                // be delivered, with the cancellation re-armed to fire at the
                // next cancelable operation.
                if (winner.cmpxchgStrong(NO_WINNER, CANCELED, .acq_rel, .acquire)) |decided| {
                    std.debug.assert(decided < fields.len);
                    deliver_recancel = true;
                    break :main decided;
                }
            }
            break :main NO_WINNER;
        };
    };

    // An externally decided arm carries its outcome in ctx; commit reports it.
    if (winner_index != NO_WINNER) {
        inline for (fields, 0..) |field, i| {
            if (winner_index == i and @field(results, field.name) == null) {
                var future = @field(futures, field.name);
                const fp = if (comptime isPointerFuture(field.type)) future else &future;
                const committed = AsyncWaitOf(field.type).commit(fp, &waiters[i], &@field(contexts, field.name));
                @field(results, field.name) = switch (committed) {
                    .done => |value| .{ .value = value },
                    .pending => unreachable,
                };

                // An external claim consumes a queued registration and owes
                // exactly one signal. It may not have reached `notified` yet,
                // so account it from the claim rather than the flag.
                if (!states[i].signal_expected) signals_expected += 1;
                states[i] = .{};
            }
        }
    }

    // Deregister every pending arm and absorb every signal: one per consumed
    // notification, plus one per registration a notifier already consumed
    // (rollback false), whose signal may still be in flight.
    inline for (fields, 0..) |field, i| {
        const needs_rollback = states[i].phase == .pending or
            (states[i].phase == .ready and states[i].signal_expected);
        if (needs_rollback) {
            var future = @field(futures, field.name);
            const fp = if (comptime isPointerFuture(field.type)) future else &future;
            const rolled_back = AsyncWaitOf(field.type).rollback(fp, &waiters[i], &@field(contexts, field.name));
            if (rolled_back == .signal_in_flight and !states[i].signal_expected) signals_expected += 1;
        }
        states[i] = .{};
    }
    parent.wait(signals_expected, .no_cancel);

    if (winner_index == NO_WINNER) return error.Canceled;
    if (deliver_recancel) task.recancel();

    inline for (fields, 0..) |field, i| {
        if (winner_index == i) {
            return @unionInit(U, field.name, @field(results, field.name).?.value);
        }
    }
    unreachable;
}

/// Internal wait implementation with configurable cancellation behavior.
fn waitInternal(future: anytype, comptime flags: WaitFlags) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    // Self-wait detection: only meaningful inside a task context.
    if (getCurrentTaskOrNull()) |task| {
        checkSelfWait(task, future);
    }

    const FT = @TypeOf(future);
    const AW = AsyncWaitOf(FT);
    var fut = future;
    const fp = if (comptime isPointerFuture(FT)) fut else &fut;

    var waiter = Waiter.init();
    var context: FutureContext(FT) = .{};

    // For a direct waiter every signal reports a consumed registration, so
    // the landed count doubles as the notification flag.
    var registered = false;
    var signals_landed: u32 = 0;

    const result: AW.Result = main: while (true) {
        if (!registered) {
            const prep = AW.prepare(fp, &waiter, &context);
            if (prep == .pending) {
                registered = true;
                continue;
            }
            switch (AW.commit(fp, &waiter, &context)) {
                .done => |value| break :main value,
                .pending => |pending| {
                    registered = true;
                    if (pending.notify) |notified| notified.signal();
                    continue;
                },
            }
        }

        waiter.wait(signals_landed + 1, .allow_cancel) catch |err| switch (err) {
            error.Canceled => {
                if (flags.on_cancel == .cancel_and_continue) {
                    // On cancellation, cancel the future and keep waiting for
                    // its completion.
                    fp.cancel();
                    while (true) {
                        if (!registered) {
                            const prep = AW.prepare(fp, &waiter, &context);
                            if (prep == .pending) {
                                registered = true;
                                continue;
                            }
                            switch (AW.commit(fp, &waiter, &context)) {
                                .done => |value| break :main value,
                                .pending => |pending| {
                                    registered = true;
                                    if (pending.notify) |notified| notified.signal();
                                    continue;
                                },
                            }
                        }
                        waiter.wait(signals_landed + 1, .no_cancel);
                        signals_landed = waiter.landedSignals();
                        registered = false;
                        switch (AW.commit(fp, &waiter, &context)) {
                            .done => |value| break :main value,
                            .pending => |pending| {
                                registered = true;
                                if (pending.notify) |notified| notified.signal();
                            },
                        }
                    }
                }

                var signals_to_wait_for = signals_landed;
                var notification_pending = false;
                if (registered) {
                    const rolled_back = AW.rollback(fp, &waiter, &context);
                    if (rolled_back == .signal_in_flight) {
                        signals_to_wait_for += 1;
                        notification_pending = true;
                    }
                    registered = false;
                }
                while (notification_pending) {
                    waiter.wait(signals_to_wait_for, .no_cancel);
                    // A signal to a direct waiter reports a completed
                    // operation: deliver its result rather than dropping it,
                    // and re-arm the cancellation for the next cancelable
                    // operation.
                    switch (AW.commit(fp, &waiter, &context)) {
                        .done => |value| {
                            if (waiter.mode.direct.task) |t| t.recancel();
                            return .{ .value = value };
                        },
                        .pending => |pending| {
                            if (pending.notify) |notified| notified.signal();
                            const rolled_back = AW.rollback(fp, &waiter, &context);
                            if (rolled_back == .signal_in_flight) {
                                signals_to_wait_for += 1;
                            } else {
                                notification_pending = false;
                            }
                        },
                    }
                }
                return err;
            },
        };
        signals_landed = waiter.landedSignals();
        registered = false;
        switch (AW.commit(fp, &waiter, &context)) {
            .done => |value| break :main value,
            .pending => |pending| {
                registered = true;
                if (pending.notify) |notified| notified.signal();
            },
        }
    };

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

test "select: sixteen arms fit the comptime quota" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const Ready = struct {
        value: u8,
        const Source = @This();

        pub const AsyncWait = struct {
            pub const Result = u8;
            pub const Context = struct {};

            pub fn prepare(self: *const Source, waiter: *Waiter, ctx: *Context) Prepare {
                _ = self;
                _ = waiter;
                _ = ctx;
                return .ready;
            }

            pub fn commit(self: *const Source, waiter: *Waiter, ctx: *Context) CommitResult(Result) {
                _ = waiter;
                _ = ctx;
                return .{ .done = self.value };
            }

            pub fn rollback(self: *const Source, waiter: *Waiter, ctx: *Context) Rollback {
                _ = self;
                _ = waiter;
                _ = ctx;
                return .removed;
            }
        };
    };

    const result = try select(.{
        .arm00 = Ready{ .value = 0 },
        .arm01 = Ready{ .value = 1 },
        .arm02 = Ready{ .value = 2 },
        .arm03 = Ready{ .value = 3 },
        .arm04 = Ready{ .value = 4 },
        .arm05 = Ready{ .value = 5 },
        .arm06 = Ready{ .value = 6 },
        .arm07 = Ready{ .value = 7 },
        .arm08 = Ready{ .value = 8 },
        .arm09 = Ready{ .value = 9 },
        .arm10 = Ready{ .value = 10 },
        .arm11 = Ready{ .value = 11 },
        .arm12 = Ready{ .value = 12 },
        .arm13 = Ready{ .value = 13 },
        .arm14 = Ready{ .value = 14 },
        .arm15 = Ready{ .value = 15 },
    });
    switch (result) {
        inline else => |value, tag| {
            const expected = comptime std.fmt.parseInt(u8, @tagName(tag)["arm".len..], 10) catch unreachable;
            try std.testing.expectEqual(expected, value);
        },
    }
}

test "select: null is a committed optional result" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const NullReady = struct {
        commits: *usize,
        const Source = @This();

        pub const AsyncWait = struct {
            pub const Result = ?u8;
            pub const Context = struct {};

            pub fn prepare(self: *const Source, waiter: *Waiter, ctx: *Context) Prepare {
                _ = self;
                _ = waiter;
                _ = ctx;
                return .ready;
            }

            pub fn commit(self: *const Source, waiter: *Waiter, ctx: *Context) CommitResult(Result) {
                _ = waiter;
                _ = ctx;
                self.commits.* += 1;
                return .{ .done = null };
            }

            pub fn rollback(self: *const Source, waiter: *Waiter, ctx: *Context) Rollback {
                _ = self;
                _ = waiter;
                _ = ctx;
                return .removed;
            }
        };
    };

    var commits: usize = 0;
    const result = try select(.{ .optional = NullReady{ .commits = &commits } });
    try std.testing.expectEqual(null, result.optional);
    try std.testing.expectEqual(1, commits);
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
    try std.testing.expectEqual(true, std.meta.activeTag(result) == .first or std.meta.activeTag(result) == .second);
}
