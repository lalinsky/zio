// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const AnyTask = @import("core/task.zig").AnyTask;
const Awaitable = @import("core/awaitable.zig").Awaitable;
const WaitNode = @import("core/WaitNode.zig");
const meta = @import("meta.zig");

/// Sentinel value indicating no winner has been selected yet
const NO_WINNER = std.math.maxInt(usize);

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
//   fn asyncWait(self: *Self, rt: *Runtime, wait_node: *WaitNode) bool           // if WaitContext == void
//   fn asyncWait(self: *Self, rt: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) bool  // if WaitContext != void
//     Register for notification when this future completes.
//
//     If WaitContext != void, the ctx parameter points to caller-allocated per-wait state
//     that persists for the duration of this wait operation.
//
//     Returns:
//       - false: Operation already complete (fast path). Result is available via getResult().
//                The wait_node was NOT added to any queue.
//       - true: Operation pending (slow path). The wait_node was added to an internal wait
//               queue and will be woken via wait_node.wake() when the operation completes.
//
//     Guarantees:
//       - If returns false, getResult() can be called immediately
//       - If returns true, wait_node.wake() will be called exactly once when complete
//       - Thread-safe: can be called from any thread
//       - The ctx pointer (if present) remains valid until asyncCancelWait() or wait_node.wake()
//
//   fn asyncCancelWait(self: *Self, rt: *Runtime, wait_node: *WaitNode) void     // if WaitContext == void
//   fn asyncCancelWait(self: *Self, rt: *Runtime, wait_node: *WaitNode, ctx: *WaitContext) void  // if WaitContext != void
//     Cancel a pending wait operation by removing the wait_node from internal queues.
//
//     Must be called if asyncWait() returned true and the caller no longer wants to wait
//     (e.g., select() chose a different future).
//
//     Behavior:
//       - If wait_node is still queued: Removes it. The future will not wake this wait_node.
//       - If wait_node was already removed (race with completion): The future has committed
//         to waking this wait_node. For queuing operations (Channel, Notify), the
//         implementation must transfer the wakeup to another waiter to avoid losing the
//         signal/item.
//
//     Guarantees:
//       - Thread-safe: can be called from any thread
//       - Safe to call even if asyncWait() returned false (becomes a no-op)
//       - After calling, wait_node.wake() will not be called (unless race occurred, see above)
//
//   fn getResult(self: *Self) Result
//     Retrieve the result of the completed operation.
//
//     Must only be called after asyncWait() returns false or after wait_node.wake() is called.
//
//     Returns: The result value. For operations that can fail, Result may be an error union
//              (e.g., error{ChannelClosed}!T).
//
//     Guarantees:
//       - All side effects from the operation that produced the result are visible
//       - Thread-safe: can be called from any thread after completion

/// Extract the Future type from a pointer type
/// Enforces that T must be a pointer
fn FutureType(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) {
        @compileError("Future must be a pointer type, got: " ++ @typeName(T) ++
            ". Use '&' to pass by pointer (e.g., &future instead of future)");
    }
    return type_info.pointer.child;
}

/// Extract the Result type from a future pointer
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
    var context_fields: []const std.builtin.Type.StructField = &.{};

    inline for (fields) |field| {
        const WaitCtx = FutureWaitContext(field.type);
        if (WaitCtx != void) {
            const ctx_field = std.builtin.Type.StructField{
                .name = field.name,
                .type = WaitCtx,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(WaitCtx),
            };
            context_fields = context_fields ++ &[_]std.builtin.Type.StructField{ctx_field};
        }
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = context_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
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
    var fields: [struct_fields.len]std.builtin.Type.UnionField = undefined;
    for (&fields, struct_fields) |*union_field, struct_field| {
        const Future = FutureType(struct_field.type);
        const Result = Future.Result;
        union_field.* = .{
            .name = struct_field.name,
            .type = Result,
            .alignment = @alignOf(Result),
        };
    }
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = std.meta.FieldEnum(S),
        .fields = &fields,
        .decls = &.{},
    } });
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

// SelectWaiter - used by Runtime.select to wait on multiple handles
pub const SelectWaiter = struct {
    wait_node: WaitNode,
    parent: *WaitNode,
    winner: *std.atomic.Value(usize),
    index: usize,

    const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    pub fn init(parent: *WaitNode, winner: *std.atomic.Value(usize), index: usize) SelectWaiter {
        return .{
            .wait_node = .{
                .vtable = &wait_node_vtable,
            },
            .parent = parent,
            .winner = winner,
            .index = index,
        };
    }

    fn waitNodeWake(wait_node: *WaitNode) void {
        const self: *SelectWaiter = @fieldParentPtr("wait_node", wait_node);

        // Try to claim winner slot with our index
        const prev = self.winner.cmpxchgStrong(NO_WINNER, self.index, .acq_rel, .acquire);

        if (prev == null) {
            // We won! Wake parent task
            self.parent.wake();
        }
        // else: someone else already won, don't wake parent again
    }
};

/// Wait for multiple futures simultaneously and return whichever completes first.
///
/// **Important**: All futures MUST be passed as pointers (use `&` prefix).
/// This ensures consistent behavior and prevents accidental copies.
///
/// `futures` is a struct with each field a pointer to a future (e.g., `*JoinHandle(T)`),
/// where `T` can be different for each field.
/// Returns a tagged union with the same field names, containing the result of whichever completed first.
///
/// When multiple handles complete at the same time, fields are checked in declaration order
/// and the first ready handle is returned.
///
/// Example:
/// ```
/// var h1 = try rt.spawn(task1, .{}, .{});
/// var h2 = try rt.spawn(task2, .{}, .{});
/// const result = rt.select(.{ .first = &h1, .second = &h2 });
/// switch (result) {
///     .first => |val| ...,
///     .second => |val| ...,
/// }
/// ```
pub fn select(rt: *Runtime, futures: anytype) !SelectResult(@TypeOf(futures)) {
    const S = @TypeOf(futures);
    const U = SelectResult(S);
    const fields = @typeInfo(S).@"struct".fields;

    // Multi-wait path: Create separate waiter awaitables for each handle
    // We can't add the same awaitable to multiple lists (next/prev pointers conflict)
    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    // Self-wait detection: check all futures for self-wait
    inline for (fields) |field| {
        checkSelfWait(task, @field(futures, field.name));
    }

    task.state.store(.preparing_to_wait, .release);
    defer {
        const prev = task.state.swap(.ready, .release);
        std.debug.assert(prev == .preparing_to_wait or prev == .ready);
    }

    // Winner tracking: NO_WINNER means no winner yet
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);

    // Allocate WaitContext struct on stack for futures that need per-wait state
    const ContextsType = WaitContextsType(S);
    var contexts: ContextsType = undefined;

    // Create waiter structures on the stack
    var waiters: [fields.len]SelectWaiter = undefined;
    inline for (&waiters, 0..) |*waiter, i| {
        waiter.* = SelectWaiter.init(&task.awaitable.wait_node, &winner, i);
    }

    // Track how many futures we've registered with (for cleanup)
    var registered_count: usize = 0;

    // Clean up waiters on all exit paths
    defer {
        const winner_index = winner.load(.acquire);
        inline for (fields, 0..) |field, i| {
            // Only cancel if we registered and didn't win
            if (i < registered_count and winner_index != i) {
                var future = @field(futures, field.name);
                if (comptime hasWaitContext(field.type)) {
                    future.asyncCancelWait(rt, &waiters[i].wait_node, &@field(contexts, field.name));
                } else {
                    future.asyncCancelWait(rt, &waiters[i].wait_node);
                }
            }
        }
    }

    // Add waiters to all waiting lists - fast path: return immediately if already complete
    inline for (fields, 0..) |field, i| {
        var future = @field(futures, field.name);
        const waiting = if (comptime hasWaitContext(field.type))
            future.asyncWait(rt, &waiters[i].wait_node, &@field(contexts, field.name))
        else
            future.asyncWait(rt, &waiters[i].wait_node);

        registered_count += 1;

        if (!waiting) {
            winner.store(i, .release);
            return @unionInit(U, field.name, future.getResult());
        }
    }

    // Yield and wait for one to complete
    try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);

    // O(1) winner lookup
    const winner_index = winner.load(.acquire);
    std.debug.assert(winner_index != NO_WINNER);

    // Return result from winner
    inline for (fields, 0..) |field, i| {
        if (i == winner_index) {
            var future = @field(futures, field.name);
            return @unionInit(U, field.name, future.getResult());
        }
    }

    // Should never reach here - we were woken up, so something must be signaled
    unreachable;
}

/// Select on a runtime slice of type-erased Awaitables.
/// Returns the index of the first awaitable to complete.
/// Used by std.Io.selectImpl.
pub fn selectAwaitables(rt: *Runtime, awaitables: []const *Awaitable) Cancelable!usize {
    const max_awaitables = 64;
    if (awaitables.len > max_awaitables) {
        @panic("selectAwaitables: too many awaitables (max 64)");
    }

    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    task.state.store(.preparing_to_wait, .release);
    defer {
        const prev = task.state.swap(.ready, .release);
        std.debug.assert(prev == .preparing_to_wait or prev == .ready);
    }

    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiters: [max_awaitables]SelectWaiter = undefined;

    for (waiters[0..awaitables.len], 0..) |*waiter, i| {
        waiter.* = SelectWaiter.init(&task.awaitable.wait_node, &winner, i);
    }

    var registered_count: usize = 0;
    defer {
        const winner_index = winner.load(.acquire);
        for (awaitables[0..registered_count], 0..) |awaitable, i| {
            if (winner_index != i) {
                awaitable.asyncCancelWait(rt, &waiters[i].wait_node);
            }
        }
    }

    for (awaitables, 0..) |awaitable, i| {
        const waiting = awaitable.asyncWait(rt, &waiters[i].wait_node);
        registered_count += 1;

        if (!waiting) {
            winner.store(i, .release);
            return i;
        }
    }

    try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);

    const winner_index = winner.load(.acquire);
    std.debug.assert(winner_index != NO_WINNER);
    return winner_index;
}

/// Internal wait implementation with configurable cancellation behavior.
fn waitInternal(rt: *Runtime, future: anytype, comptime flags: WaitFlags) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    const task = rt.getCurrentTask();
    const wait_node = &task.awaitable.wait_node;

    // Self-wait detection: check if waiting on own task (would deadlock)
    checkSelfWait(task, future);

    task.state.store(.preparing_to_wait, .release);
    defer {
        const prev = task.state.swap(.ready, .release);
        std.debug.assert(prev == .preparing_to_wait or prev == .ready);
    }

    // Winner tracking: for single future, winner is always 0 if signaled
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiter = SelectWaiter.init(wait_node, &winner, 0);

    // Allocate WaitContext if needed
    const WaitCtx = FutureWaitContext(@TypeOf(future));
    var context: WaitCtx = undefined;
    const has_context = comptime (WaitCtx != void);

    // Fast path: check if already complete
    var fut = future;
    const added = if (has_context)
        fut.asyncWait(rt, &waiter.wait_node, &context)
    else
        fut.asyncWait(rt, &waiter.wait_node);

    if (!added) {
        return .{ .value = fut.getResult() };
    }

    // Clean up waiter on exit
    defer {
        if (winner.load(.acquire) == NO_WINNER) {
            if (has_context) {
                fut.asyncCancelWait(rt, &waiter.wait_node, &context);
            } else {
                fut.asyncCancelWait(rt, &waiter.wait_node);
            }
        }
    }

    const executor = task.getExecutor();

    if (flags.on_cancel == .cancel_and_continue) {
        // Stay subscribed to wait queue during cancel-and-retry
        var shielded = false;
        defer if (shielded) rt.endShield();

        while (true) {
            executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| switch (err) {
                error.Canceled => {
                    if (shielded) unreachable;
                    rt.beginShield();
                    shielded = true;
                    fut.cancel();
                    continue;
                },
            };
            break;
        }
    } else {
        // Propagate cancellation to caller
        try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);
    }

    // We should have been signaled
    std.debug.assert(winner.load(.acquire) == 0);

    return .{ .value = fut.getResult() };
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
/// const result = try rt.wait(&future); // returns Cancelable!WaitResult(error{Foo}!i32)
/// const value = try result.value; // handle the inner error union
/// ```
pub fn wait(rt: *Runtime, future: anytype) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    return waitInternal(rt, future, .{ .on_cancel = .propagate });
}

/// Wait for a single future to complete, never propagating cancellation.
/// When canceled, cancels the child task and continues waiting with shield enabled.
/// This ensures the function always returns a result and never returns error.Canceled.
/// `future` must be a pointer to a future type.
/// Works from both coroutines and threads.
///
/// Example:
/// ```
/// const value = rt.waitUntilComplete(&future); // never returns error.Canceled
/// // value is directly FutureResult (e.g., error{Foo}!i32)
/// ```
pub fn waitUntilComplete(rt: *Runtime, future: anytype) FutureResult(@TypeOf(future)) {
    const result = waitInternal(rt, future, .{ .on_cancel = .cancel_and_continue }) catch unreachable;
    return result.value;
}

test "select: basic - first completes" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask(rt: *Runtime) !i32 {
            try rt.sleep(100);
            return 42;
        }

        fn fastTask(rt: *Runtime) !i32 {
            try rt.sleep(10);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.cancel(rt);
            var fast = try rt.spawn(fastTask, .{rt}, .{});
            defer fast.cancel(rt);

            const result = try select(rt, .{ .fast = &fast, .slow = &slow });
            switch (result) {
                .slow => |val| try testing.expectEqual(@as(i32, 42), val),
                .fast => |val| try testing.expectEqual(@as(i32, 99), val),
            }
            // Fast should win
            try testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: already complete - fast path" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn immediateTask() i32 {
            return 123;
        }

        fn slowTask(rt: *Runtime) !i32 {
            try rt.sleep(100);
            return 456;
        }

        fn asyncTask(rt: *Runtime) !void {
            var immediate = try rt.spawn(immediateTask, .{}, .{});
            defer immediate.cancel(rt);

            // Give immediate task a chance to complete
            try rt.yield();
            try rt.yield();

            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.cancel(rt);

            // immediate should already be complete, select should return immediately
            const result = try select(rt, .{ .immediate = &immediate, .slow = &slow });
            switch (result) {
                .immediate => |val| try testing.expectEqual(@as(i32, 123), val),
                .slow => return error.TestUnexpectedResult,
            }
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: heterogeneous types" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn intTask(rt: *Runtime) Cancelable!i32 {
            try rt.sleep(100);
            return 42;
        }

        fn stringTask(rt: *Runtime) Cancelable![]const u8 {
            try rt.sleep(10);
            return "hello";
        }

        fn boolTask(rt: *Runtime) Cancelable!bool {
            try rt.sleep(150);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var int_handle = try rt.spawn(intTask, .{rt}, .{});
            defer int_handle.cancel(rt);
            var string_handle = try rt.spawn(stringTask, .{rt}, .{});
            defer string_handle.cancel(rt);
            var bool_handle = try rt.spawn(boolTask, .{rt}, .{});
            defer bool_handle.cancel(rt);

            const result = try select(rt, .{
                .string = &string_handle,
                .int = &int_handle,
                .bool = &bool_handle,
            });

            switch (result) {
                .int => |val| {
                    try testing.expectEqual(@as(i32, 42), try val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
                .string => |val| {
                    try testing.expectEqualStrings("hello", try val);
                    // This should win
                },
                .bool => |val| {
                    try testing.expectEqual(true, try val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
            }
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: with cancellation" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask1(rt: *Runtime) !i32 {
            try rt.sleep(1000);
            return 1;
        }

        fn slowTask2(rt: *Runtime) !i32 {
            try rt.sleep(1000);
            return 2;
        }

        fn selectTask(rt: *Runtime) !i32 {
            var h1 = try rt.spawn(slowTask1, .{rt}, .{});
            defer h1.cancel(rt);
            var h2 = try rt.spawn(slowTask2, .{rt}, .{});
            defer h2.cancel(rt);

            const result = try select(rt, .{ .first = &h1, .second = &h2 });
            return switch (result) {
                .first => |v| v,
                .second => |v| v,
            };
        }

        fn asyncTask(rt: *Runtime) !void {
            var select_handle = try rt.spawn(selectTask, .{rt}, .{});
            defer select_handle.cancel(rt);

            // Give it a chance to start waiting
            try rt.yield();
            try rt.yield();

            // Cancel the select operation
            select_handle.cancel(rt);

            // Should return error.Canceled
            const result = select_handle.join(rt);
            try testing.expectError(error.Canceled, result);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: with error unions - success case" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const ValidationError = error{ TooShort, TooLong };

        fn parseTask(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(100);
            return 42;
        }

        fn validateTask(rt: *Runtime) (ValidationError || Cancelable)![]const u8 {
            try rt.sleep(10);
            return "valid";
        }

        fn asyncTask(rt: *Runtime) !void {
            var parse_handle = try rt.spawn(parseTask, .{rt}, .{});
            defer parse_handle.cancel(rt);
            var validate_handle = try rt.spawn(validateTask, .{rt}, .{});
            defer validate_handle.cancel(rt);

            const result = try select(rt, .{
                .validate = &validate_handle,
                .parse = &parse_handle,
            });

            // Result is a union where each field has the original error type
            switch (result) {
                .parse => |val_or_err| {
                    // val_or_err is ParseError!i32
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqual(@as(i32, 42), val);
                    return error.TestUnexpectedResult; // validate should win
                },
                .validate => |val_or_err| {
                    // val_or_err is ValidationError![]const u8
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqualStrings("valid", val);
                    // This should win
                },
            }
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: with error unions - error case" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };

        fn failingTask(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(10);
            return error.OutOfRange;
        }

        fn slowTask(rt: *Runtime) !i32 {
            try rt.sleep(100);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var failing = try rt.spawn(failingTask, .{rt}, .{});
            defer failing.cancel(rt);
            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.cancel(rt);

            const result = try select(rt, .{ .failing = &failing, .slow = &slow });

            switch (result) {
                .failing => |val_or_err| {
                    // val_or_err is ParseError!i32
                    _ = val_or_err catch |err| {
                        // Should receive the original error
                        try testing.expectEqual(ParseError.OutOfRange, err);
                        return;
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .slow => |val| {
                    try testing.expectEqual(@as(i32, 99), val);
                    return error.TestUnexpectedResult; // failing should win
                },
            }
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: with mixed error types" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const IOError = error{ FileNotFound, PermissionDenied };

        fn task1(rt: *Runtime) (ParseError || Cancelable)!i32 {
            try rt.sleep(100);
            return 100;
        }

        fn task2(rt: *Runtime) (IOError || Cancelable)![]const u8 {
            try rt.sleep(10);
            return error.FileNotFound;
        }

        fn task3(rt: *Runtime) !bool {
            try rt.sleep(150);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var h1 = try rt.spawn(task1, .{rt}, .{});
            defer h1.cancel(rt);
            var h2 = try rt.spawn(task2, .{rt}, .{});
            defer h2.cancel(rt);
            var h3 = try rt.spawn(task3, .{rt}, .{});
            defer h3.cancel(rt);

            // select returns Cancelable!SelectUnion(...)
            // SelectUnion has: { .h2: IOError![]const u8, .h1: ParseError!i32, .h3: bool }
            const result = try select(rt, .{ .h2 = &h2, .h1 = &h1, .h3 = &h3 });

            switch (result) {
                .h1 => |val_or_err| {
                    _ = val_or_err catch return error.TestUnexpectedResult;
                    return error.TestUnexpectedResult;
                },
                .h2 => |val_or_err| {
                    // val_or_err is IOError![]const u8
                    _ = val_or_err catch |err| {
                        // Verify we got the original error type
                        try testing.expectEqual(IOError.FileNotFound, err);
                        return; // This is expected
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .h3 => |val| {
                    try testing.expectEqual(true, val);
                    return error.TestUnexpectedResult;
                },
            }
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "wait: plain type" {
    const testing = std.testing;
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;

            // Spawn task to set the future
            var task = try rt.spawn(struct {
                fn run(f: *Future(i32)) !void {
                    f.set(42);
                }
            }.run, .{&future}, .{});
            defer task.cancel(rt);

            // Wait for the future
            const result = try wait(rt, &future);
            try testing.expectEqual(@as(i32, 42), result.value);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "wait: error union" {
    const testing = std.testing;
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const MyError = error{Foo};

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(MyError!i32).init;

            // Spawn task to set the future with success
            var task = try rt.spawn(struct {
                fn run(f: *Future(MyError!i32)) !void {
                    f.set(123);
                }
            }.run, .{&future}, .{});
            defer task.cancel(rt);

            // Wait for the future
            const result = try wait(rt, &future);
            const value = try result.value;
            try testing.expectEqual(@as(i32, 123), value);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "wait: error union with error" {
    const testing = std.testing;
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const MyError = error{Foo};

        fn asyncTask(rt: *Runtime) !void {
            var future = Future(MyError!i32).init;

            // Spawn task to set the future with error
            var task = try rt.spawn(struct {
                fn run(f: *Future(MyError!i32)) !void {
                    f.set(MyError.Foo);
                }
            }.run, .{&future}, .{});
            defer task.cancel(rt);

            // Wait for the future
            const result = try wait(rt, &future);
            try testing.expectError(MyError.Foo, result.value);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "wait: already complete (fast path)" {
    const testing = std.testing;
    const Future = @import("sync/future.zig").Future;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            var future = Future(i32).init;
            future.set(99);

            // Wait should return immediately since already set
            const result = try wait(rt, &future);
            try testing.expectEqual(@as(i32, 99), result.value);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}

test "select: wait on JoinHandle from spawned task" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn workerTask(rt: *Runtime, value: i32) !i32 {
            try rt.sleep(10);
            return value * 2;
        }

        fn asyncTask(rt: *Runtime) !void {
            // Spawn a task and get a JoinHandle
            var handle1 = try rt.spawn(workerTask, .{ rt, 21 }, .{});
            defer handle1.cancel(rt);

            var handle2 = try rt.spawn(workerTask, .{ rt, 100 }, .{});
            defer handle2.cancel(rt);

            // Wait on JoinHandles using select
            const result = try select(rt, .{
                .first = &handle1,
                .second = &handle2,
            });

            // Verify we got a result
            switch (result) {
                .first => |val| {
                    try testing.expectEqual(@as(i32, 42), val);
                },
                .second => |val| {
                    try testing.expectEqual(@as(i32, 200), val);
                },
            }

            // Both should be valid results, though timing determines which completes first
            try testing.expect(std.meta.activeTag(result) == .first or std.meta.activeTag(result) == .second);
        }
    };

    var handle = try runtime.spawn(TestContext.asyncTask, .{runtime}, .{});
    try handle.join(runtime);
}
