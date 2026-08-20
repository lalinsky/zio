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
//     Register for notification when this future completes.
//
//     If WaitContext != void, the ctx parameter points to caller-allocated per-wait state
//     that persists for the duration of this wait operation.
//
//     Returns (see common.AsyncWaitState):
//       - .ready: Operation complete (fast path) AND this waiter WON the select
//                 (the future called waiter.tryClaim() BEFORE any consuming side
//                 effect). Result is available via getResult(). Nothing was
//                 registered.
//       - .queued: Operation pending (slow path). The waiter was added to an
//                  internal wait queue and will be woken via waiter.wake() when
//                  the operation completes.
//       - .lost: Another branch of the same select already won. The future
//                consumed NOTHING and registered NOTHING. Only select waiters
//                can lose; a direct waiter's claim always succeeds.
//
//     The claim-before-consume rule is the load-bearing invariant: a fast path
//     that consumed first and reported ready afterwards let select() overwrite
//     a concurrent claim of an earlier-registered branch, and the claimed item
//     died on the select's dead stack frame.
//
//     Guarantees:
//       - If .ready, getResult() can be called immediately and the winner slot
//         holds this branch's index
//       - If .queued, waiter.wake() will be called exactly once when complete
//       - Thread-safe: can be called from any thread
//       - The ctx pointer (if present) remains valid until asyncCancelWait() or waiter.wake()
//
//   fn asyncCancelWait(self: *Self, waiter: *Waiter) bool     // if WaitContext == void
//   fn asyncCancelWait(self: *Self, waiter: *Waiter, ctx: *WaitContext) bool  // if WaitContext != void
//     Cancel a pending wait operation by removing the waiter from internal queues.
//
//     Must be called if asyncWait() returned true and the caller no longer wants to wait
//     (e.g., select() chose a different future).
//
//     Returns:
//       - true: Successfully removed from queue. The future will not wake this waiter.
//       - false: Already removed by completion. The future has committed to waking this
//                waiter (wake is in-flight or already happened).
//
//     For queuing operations (Channel, Notify), when returning false the implementation
//     must transfer the wakeup to another waiter to avoid losing the signal/item.
//
//     Guarantees:
//       - Thread-safe: can be called from any thread
//       - Safe to call even if asyncWait() returned false (returns false, no-op)
//
//   fn getResult(self: *const Self) Result                                        // if WaitContext == void
//   fn getResult(self: *const Self, ctx: *WaitContext) Result                      // if WaitContext != void
//     Retrieve the result of the completed operation.
//
//     Must only be called after asyncWait() returns false or after waiter.wake() is called.
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
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
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
    const fields = @typeInfo(futures_type).@"struct".fields;

    // Count how many fields have non-void WaitContext
    comptime var count: usize = 0;
    inline for (fields) |field| {
        if (FutureWaitContext(field.type) != void) {
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
    var field_attrs: [count]std.builtin.Type.StructField.Attributes = undefined;

    comptime var i: usize = 0;
    inline for (fields) |field| {
        const WaitCtx = FutureWaitContext(field.type);
        if (WaitCtx != void) {
            const default_value: WaitCtx = .{};
            field_names[i] = field.name;
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
    const struct_fields = @typeInfo(S).@"struct".fields;

    var field_names: [struct_fields.len][:0]const u8 = undefined;
    var field_types: [struct_fields.len]type = undefined;
    var field_attrs: [struct_fields.len]std.builtin.Type.UnionField.Attributes = undefined;

    for (struct_fields, 0..) |struct_field, i| {
        const Future = FutureType(struct_field.type);
        field_names[i] = struct_field.name;
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
    const fields = @typeInfo(S).@"struct".fields;

    // Self-wait detection: check all futures for self-wait
    const task = getCurrentTask();
    inline for (fields) |field| {
        checkSelfWait(task, @field(futures, field.name));
    }

    // Winner tracking: NO_WINNER means no winner yet
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);

    // Parent waiter that select waiters will signal when they win
    var waiter = Waiter.init();

    // Allocate WaitContext struct on stack for futures that need per-wait state
    const ContextsType = WaitContextsType(S);
    var contexts: ContextsType = .{};

    // Create waiter structures on the stack
    var waiters: [fields.len]Waiter = undefined;
    inline for (&waiters, 0..) |*w, i| {
        w.* = Waiter.initSelect(&waiter, &winner, i);
    }

    // Per-branch registration state. A prefix count is not enough once a
    // branch can report `.lost` (nothing registered) between two `.queued`
    // branches; cancel/cleanup must touch exactly the queued set.
    const BranchState = enum { untouched, queued, lost };
    var states = [_]BranchState{.untouched} ** fields.len;

    // The cancel path runs its own epilogue (it must resolve every branch
    // BEFORE deciding whether a claim won); this flag keeps the defer from
    // double-canceling and double-counting signals after it has.
    var cleanup_done = false;

    // Clean up waiters on all exit paths
    defer if (!cleanup_done) {
        const winner_index = winner.load(.acquire);

        // Count expected signals: every queued branch will signal unless we
        // cancel it; `.lost` and `.untouched` branches registered nothing
        // and never signal.
        var expected: u32 = 0;
        inline for (fields, 0..) |field, i| {
            if (states[i] == .queued) {
                if (winner_index != i) {
                    var future = @field(futures, field.name);
                    const was_removed = if (comptime hasWaitContext(field.type))
                        future.asyncCancelWait(&waiters[i], &@field(contexts, field.name))
                    else
                        future.asyncCancelWait(&waiters[i]);

                    if (!was_removed) {
                        // Claimed or completing: its signal is in flight.
                        expected += 1;
                    }
                } else {
                    // The winner signals exactly once.
                    expected += 1;
                }
            }
        }

        // Wait for all expected signals (winner + in-flight non-winners)
        waiter.wait(expected, .no_cancel);
    };

    // Fast-path/registration pass. The claim-before-ready contract
    // (`AsyncWaitState` in common.zig) makes the old clobber unsayable:
    // `.ready` means the future already WON the winner slot before it
    // consumed anything, so no concurrent claim of an earlier branch can be
    // overwritten. `.lost` means another branch won during this pass; that
    // branch's signal is in flight and drives the wait below.
    var lost_any = false;
    inline for (fields, 0..) |field, i| {
        const future = @field(futures, field.name);
        const state = if (comptime hasWaitContext(field.type))
            future.asyncWait(&waiters[i], &@field(contexts, field.name))
        else
            future.asyncWait(&waiters[i]);

        switch (state) {
            .ready => {
                std.debug.assert(winner.load(.acquire) == i);
                const result = if (comptime hasWaitContext(field.type))
                    future.getResult(&@field(contexts, field.name))
                else
                    future.getResult();
                return @unionInit(U, field.name, result);
            },
            .queued => states[i] = .queued,
            .lost => {
                states[i] = .lost;
                lost_any = true;
            },
        }
    }
    if (lost_any) {
        // Some queued branch was claimed while this pass ran; absorb its
        // signal (which also orders its result copy) and deliver it.
        waiter.wait(1, .no_cancel);
        const winner_index = winner.load(.acquire);
        std.debug.assert(winner_index != NO_WINNER);
        inline for (fields, 0..) |field, i| {
            if (i == winner_index) {
                const future = @field(futures, field.name);
                const result = if (comptime hasWaitContext(field.type))
                    future.getResult(&@field(contexts, field.name))
                else
                    future.getResult();
                return @unionInit(U, field.name, result);
            }
        }
        unreachable;
    }

    // Wait for one to complete (Waiter.wait handles spurious wakeups)
    waiter.wait(1, .allow_cancel) catch |err| {
        // Canceled while parked. A queuing future may have COMMITTED an item
        // to this select already, or may still commit one while the cancel
        // loop below runs (asyncCancelWait returning false is that commitment,
        // per the protocol contract above). Dropping a committed item would
        // un-send it — Channel.receive keeps the same promise by returning
        // the item instead of error.Canceled, and select must too. So: cancel
        // every branch, absorb every in-flight signal, and only then decide.
        // The task's cancellation stays pending and re-fires at the next
        // cancelable operation.
        var expected: u32 = 0;
        inline for (fields, 0..) |field, i| {
            if (states[i] == .queued) {
                var future = @field(futures, field.name);
                const was_removed = if (comptime hasWaitContext(field.type))
                    future.asyncCancelWait(&waiters[i], &@field(contexts, field.name))
                else
                    future.asyncCancelWait(&waiters[i]);
                if (!was_removed) {
                    expected += 1;
                }
            }
        }
        // Absorbing the winner's signal is also what orders its result copy
        // before the read below.
        waiter.wait(expected, .no_cancel);
        cleanup_done = true;

        const canceled_winner = winner.load(.acquire);
        if (canceled_winner == NO_WINNER) return err;
        inline for (fields, 0..) |field, i| {
            if (i == canceled_winner) {
                const future = @field(futures, field.name);
                const result = if (comptime hasWaitContext(field.type))
                    future.getResult(&@field(contexts, field.name))
                else
                    future.getResult();
                return @unionInit(U, field.name, result);
            }
        }
        unreachable;
    };

    // O(1) winner lookup
    const winner_index = winner.load(.acquire);

    // Return result from winner
    inline for (fields, 0..) |field, i| {
        if (i == winner_index) {
            const future = @field(futures, field.name);
            const result = if (comptime hasWaitContext(field.type))
                future.getResult(&@field(contexts, field.name))
            else
                future.getResult();
            return @unionInit(U, field.name, result);
        }
    }

    // Should never reach here - we were woken up, so something must be signaled
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
    var waiter = Waiter.init();
    var waiters: [max_awaitables]Waiter = undefined;

    for (waiters[0..awaitables.len], 0..) |*w, i| {
        w.* = Waiter.initSelect(&waiter, &winner, i);
    }

    // Per-branch registration state; see select() for why a prefix count
    // is not enough.
    const BranchState = enum { untouched, queued, lost };
    var states = [_]BranchState{.untouched} ** max_awaitables;

    defer {
        const winner_index = winner.load(.acquire);

        // Count expected signals: every queued branch signals unless its
        // cancel removed it; `.lost`/`.untouched` registered nothing.
        var expected: u32 = 0;
        for (awaitables, waiters[0..awaitables.len], 0..) |awaitable, *w, i| {
            if (states[i] != .queued) continue;
            if (winner_index != i) {
                const was_removed = awaitable.asyncCancelWait(w);
                if (!was_removed) {
                    expected += 1;
                }
            } else {
                expected += 1;
            }
        }

        // Wait for all expected signals (winner + in-flight non-winners)
        waiter.wait(expected, .no_cancel);
    }

    var lost_any = false;
    for (awaitables, waiters[0..awaitables.len], 0..) |awaitable, *w, i| {
        switch (awaitable.asyncWait(w)) {
            .ready => {
                std.debug.assert(winner.load(.acquire) == i);
                return i;
            },
            .queued => states[i] = .queued,
            .lost => {
                states[i] = .lost;
                lost_any = true;
            },
        }
    }
    if (lost_any) {
        // A queued branch was claimed during this pass; absorb its signal
        // and deliver it.
        waiter.wait(1, .no_cancel);
        const winner_index = winner.load(.acquire);
        std.debug.assert(winner_index != NO_WINNER);
        return winner_index;
    }

    // Wait for one to complete (Waiter.wait handles spurious wakeups)
    try waiter.wait(1, .allow_cancel);

    return winner.load(.acquire);
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

    // Fast path: check if already complete
    var fut = future;
    const state = if (has_context)
        fut.asyncWait(&waiter, &context)
    else
        fut.asyncWait(&waiter);

    switch (state) {
        .ready => {
            const result = if (has_context) fut.getResult(&context) else fut.getResult();
            return .{ .value = result };
        },
        // A direct waiter's claim always succeeds.
        .lost => unreachable,
        .queued => {},
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

test "select: canceled select delivers a claimed channel item" {
    // Conservation law: an item sent while the selecting task is being
    // canceled is EITHER still in the channel OR returned by the select.
    // Before the cancel-path epilogue, the claim's copy died on the dead
    // select frame and the item vanished (starh2 t-882: a dropped write
    // ack leaked its accounting on every teardown race).
    const Channel = @import("sync/channel.zig").Channel;
    const ResetEvent = @import("sync/ResetEvent.zig");

    const Shared = struct {
        ch: *Channel(u64),
        never: *ResetEvent,
        received: std.atomic.Value(u64) = .init(0),
        parked: std.atomic.Value(bool) = .init(false),

        fn waiterTask(sh: *@This()) !void {
            sh.parked.store(true, .release);
            const result = select(.{
                .item = sh.ch.asyncReceive(),
                .never = sh.never,
            }) catch return;
            switch (result) {
                .item => |r| {
                    const v = r catch return;
                    sh.received.store(v, .release);
                },
                .never => unreachable,
            }
        }

        fn senderTask(sh: *@This()) !void {
            sh.ch.trySend(1) catch {};
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const Body = struct {
        fn run(rt: *Runtime) !void {
            var buf: [4]u64 = undefined;
            var iter: usize = 0;
            while (iter < 2000) : (iter += 1) {
                var ch = Channel(u64).init(&buf);
                var never = ResetEvent.init;
                var sh: Shared = .{ .ch = &ch, .never = &never };

                var w = try rt.spawn(Shared.waiterTask, .{&sh});
                while (!sh.parked.load(.acquire)) try yield();
                try yield();

                var snd = try rt.spawn(Shared.senderTask, .{&sh});
                w.cancel();
                w.join() catch {};
                snd.join() catch {};

                const in_channel: u64 = ch.tryReceive() catch 0;
                const got = sh.received.load(.acquire);
                if (in_channel == 0 and got == 0) {
                    std.debug.print("item dropped at iteration {d}\n", .{iter});
                    return error.ItemDropped;
                }
            }
        }
    };

    var handle = try runtime.spawn(Body.run, .{runtime});
    try handle.join();
}

test "select: fast path does not clobber an earlier branch's claim" {
    // Conservation law: an item sent to channel A while the select is
    // registering is EITHER still in A OR returned by the select. Branch
    // `.a` (A, empty) registers first; branch `.b` (B, already buffered)
    // takes the fast path. Before claim-before-consume, that fast path
    // did a blind `winner.store(b)` over a concurrent claim of `.a`, and
    // the item copied into the select frame vanished.
    //
    // The race needs a sender on ANOTHER executor: one long-lived sender
    // task spins on a per-round counter and fires `trySend` into the
    // registration window. On one executor the sender could only run
    // when the select task yields, and the registration pass never does.
    const Channel = @import("sync/channel.zig").Channel;
    const rounds: u64 = 50000;

    const Shared = struct {
        ch_a: std.atomic.Value(?*Channel(u64)) = .init(null),
        go: std.atomic.Value(u64) = .init(0),
        sent: std.atomic.Value(u64) = .init(0),
        running: std.atomic.Value(bool) = .init(false),
        // Set when the select side stops early (a detected drop), so the
        // sender does not spin forever on a round that never comes.
        stop: std.atomic.Value(bool) = .init(false),

        fn senderTask(sh: *@This()) !void {
            sh.running.store(true, .release);
            var round: u64 = 1;
            while (round <= rounds) : (round += 1) {
                while (sh.go.load(.acquire) < round) {
                    if (sh.stop.load(.acquire)) return;
                    std.atomic.spinLoopHint();
                }
                // Sweep the arrival phase: the two threads otherwise settle
                // into a fixed offset that can miss the window for a whole run.
                var delay: u64 = round % 64;
                while (delay > 0) : (delay -= 1) std.atomic.spinLoopHint();
                sh.ch_a.load(.acquire).?.trySend(1) catch {};
                sh.sent.store(round, .release);
            }
        }
    };

    const runtime = try Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer runtime.deinit();

    const Body = struct {
        fn run(rt: *Runtime) !void {
            var sh: Shared = .{};
            var snd = try rt.spawn(Shared.senderTask, .{&sh});
            defer snd.join() catch {};
            defer sh.stop.store(true, .release);
            while (!sh.running.load(.acquire)) try yield();

            var buf_a: [4]u64 = undefined;
            var buf_b: [4]u64 = undefined;
            var buf_f: [4]u64 = undefined;
            var round: u64 = 1;
            while (round <= rounds) : (round += 1) {
                var ch_a = Channel(u64).init(&buf_a);
                var ch_b = Channel(u64).init(&buf_b);
                // Idle filler branches between `.a` and `.b` stretch the
                // registration pass from tens of nanoseconds to a window the
                // sender's claim can land in. They never fire.
                var f1 = Channel(u64).init(&buf_f);
                var f2 = Channel(u64).init(&buf_f);
                var f3 = Channel(u64).init(&buf_f);
                var f4 = Channel(u64).init(&buf_f);
                var f5 = Channel(u64).init(&buf_f);
                var f6 = Channel(u64).init(&buf_f);
                // `.b` is ready before the select starts: its fast path fires.
                try ch_b.trySend(7);
                sh.ch_a.store(&ch_a, .release);
                sh.go.store(round, .release);
                var got_a: u64 = 0;
                const result = try select(.{
                    .a = ch_a.asyncReceive(),
                    .f1 = f1.asyncReceive(),
                    .f2 = f2.asyncReceive(),
                    .f3 = f3.asyncReceive(),
                    .f4 = f4.asyncReceive(),
                    .f5 = f5.asyncReceive(),
                    .f6 = f6.asyncReceive(),
                    .b = ch_b.asyncReceive(),
                });
                switch (result) {
                    .a => |r| got_a = r catch 0,
                    .b => |r| _ = r catch 0,
                    else => unreachable,
                }
                // The sender must be done with this round's channel before
                // the frame holding it is reused.
                while (sh.sent.load(.acquire) < round) std.atomic.spinLoopHint();

                const in_a: u64 = ch_a.tryReceive() catch 0;
                if (in_a == 0 and got_a == 0) {
                    std.debug.print("item dropped at round {d}\n", .{round});
                    return error.ItemDropped;
                }
            }
        }
    };

    var handle = try runtime.spawn(Body.run, .{runtime});
    try handle.join();
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
