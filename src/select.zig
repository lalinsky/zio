const std = @import("std");
const builtin = @import("builtin");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("common.zig").Cancelable;
const AnyTask = @import("core/task.zig").AnyTask;
const WaitNode = @import("core/WaitNode.zig");
const meta = @import("meta.zig");

/// Thread waiter for non-coroutine contexts
const ThreadWaiter = struct {
    wait_node: WaitNode,
    futex_state: std.atomic.Value(u32),

    const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    pub fn init() ThreadWaiter {
        return .{
            .wait_node = .{
                .vtable = &wait_node_vtable,
            },
            .futex_state = std.atomic.Value(u32).init(0),
        };
    }

    fn waitNodeWake(wait_node: *WaitNode) void {
        const self: *ThreadWaiter = @fieldParentPtr("wait_node", wait_node);
        self.futex_state.store(1, .release);
        std.Thread.Futex.wake(&self.futex_state, 1);
    }
};

// Future protocol:
//   * needs to have const Result = T
//   * needs to have asyncWait(*WaitNode) bool method (returns false if already complete)
//   * needs to have asyncCancelWait(*WaitNode) void method
//   * needs to have getResult() Result method

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
    wake_counter: *std.atomic.Value(u32),
    signaled: std.atomic.Value(bool) = .init(false),

    const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    pub fn init(parent: *WaitNode, wake_counter: *std.atomic.Value(u32)) SelectWaiter {
        return .{
            .wait_node = .{
                .vtable = &wait_node_vtable,
            },
            .parent = parent,
            .wake_counter = wake_counter,
            .signaled = .init(false),
        };
    }

    fn waitNodeWake(wait_node: *WaitNode) void {
        const self: *SelectWaiter = @fieldParentPtr("wait_node", wait_node);
        self.signaled.store(true, .release);
        const prev_val = self.wake_counter.fetchAdd(1, .acq_rel);
        if (prev_val == 0) {
            self.parent.wake();
        }
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
    const task = rt.getCurrentTask() orelse @panic("no active task");
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

    // Keep track of the number of wakeups (== number of futures that became ready)
    var ready: std.atomic.Value(u32) = .init(0);

    // Create waiter structures on the stack
    var waiters: [fields.len]SelectWaiter = undefined;
    inline for (&waiters) |*waiter| {
        waiter.* = SelectWaiter.init(&task.awaitable.wait_node, &ready);
    }

    // Clean up waiters on all exit paths
    defer {
        inline for (fields, 0..) |field, i| {
            if (!waiters[i].signaled.load(.acquire)) {
                var future = @field(futures, field.name);
                future.asyncCancelWait(&waiters[i].wait_node);
            }
        }
    }

    // Add waiters to all waiting lists - fast path: return immediately if already complete
    inline for (fields, 0..) |field, i| {
        var future = @field(futures, field.name);
        const waiting = future.asyncWait(&waiters[i].wait_node);
        if (!waiting) {
            return @unionInit(U, field.name, future.getResult());
        }
    }

    // Yield and wait for one to complete
    try executor.yield(.preparing_to_wait, .waiting, .allow_cancel);

    // We should have at least one future with result
    // TODO What to do if we have multiple?
    std.debug.assert(ready.load(.acquire) > 0);

    // Find which one completed by checking signaled flags
    inline for (fields, 0..) |field, i| {
        if (waiters[i].signaled.load(.acquire)) {
            var future = @field(futures, field.name);
            return @unionInit(U, field.name, future.getResult());
        }
    }

    // Should never reach here - we were woken up, so something must be signaled
    unreachable;
}

/// Internal wait implementation with configurable cancellation behavior.
fn waitInternal(rt: *Runtime, future: anytype, comptime flags: WaitFlags) Cancelable!WaitResult(FutureResult(@TypeOf(future))) {
    var thread_waiter = ThreadWaiter.init();
    const task = rt.getCurrentTask();
    const wait_node = if (task) |t| &t.awaitable.wait_node else &thread_waiter.wait_node;

    // Self-wait detection: check if waiting on own task (would deadlock)
    if (task) |t| checkSelfWait(t, future);

    if (task) |t| {
        t.state.store(.preparing_to_wait, .release);
    }
    defer {
        if (task) |t| {
            const prev = t.state.swap(.ready, .release);
            std.debug.assert(prev == .preparing_to_wait or prev == .ready);
        }
    }

    var ready: std.atomic.Value(u32) = .init(0);
    var waiter = SelectWaiter.init(wait_node, &ready);

    // Fast path: check if already complete
    var fut = future;
    const added = fut.asyncWait(&waiter.wait_node);
    if (!added) {
        return .{ .value = fut.getResult() };
    }

    // Clean up waiter on exit
    defer {
        if (!waiter.signaled.load(.acquire)) {
            fut.asyncCancelWait(&waiter.wait_node);
        }
    }

    if (task) |t| {
        // Coroutine path: yield with cancellation handling
        const executor = t.getExecutor();

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
    } else {
        // Thread path: park on futex
        while (thread_waiter.futex_state.load(.acquire) == 0) {
            std.Thread.Futex.wait(&thread_waiter.futex_state, 0);
        }
    }

    // We should have been signaled
    std.debug.assert(ready.load(.acquire) > 0);
    std.debug.assert(waiter.signaled.load(.acquire));

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
            defer slow.deinit();
            var fast = try rt.spawn(fastTask, .{rt}, .{});
            defer fast.deinit();

            const result = try select(rt, .{ .fast = &fast, .slow = &slow });
            switch (result) {
                .slow => |val| try testing.expectEqual(@as(i32, 42), val),
                .fast => |val| try testing.expectEqual(@as(i32, 99), val),
            }
            // Fast should win
            try testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer immediate.deinit();

            // Give immediate task a chance to complete
            try rt.yield();
            try rt.yield();

            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.deinit();

            // immediate should already be complete, select should return immediately
            const result = try select(rt, .{ .immediate = &immediate, .slow = &slow });
            switch (result) {
                .immediate => |val| try testing.expectEqual(@as(i32, 123), val),
                .slow => return error.TestUnexpectedResult,
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer int_handle.deinit();
            var string_handle = try rt.spawn(stringTask, .{rt}, .{});
            defer string_handle.deinit();
            var bool_handle = try rt.spawn(boolTask, .{rt}, .{});
            defer bool_handle.deinit();

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer h1.deinit();
            var h2 = try rt.spawn(slowTask2, .{rt}, .{});
            defer h2.deinit();

            const result = try select(rt, .{ .first = &h1, .second = &h2 });
            return switch (result) {
                .first => |v| v,
                .second => |v| v,
            };
        }

        fn asyncTask(rt: *Runtime) !void {
            var select_handle = try rt.spawn(selectTask, .{rt}, .{});
            defer select_handle.deinit();

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer parse_handle.deinit();
            var validate_handle = try rt.spawn(validateTask, .{rt}, .{});
            defer validate_handle.deinit();

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer failing.deinit();
            var slow = try rt.spawn(slowTask, .{rt}, .{});
            defer slow.deinit();

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer h1.deinit();
            var h2 = try rt.spawn(task2, .{rt}, .{});
            defer h2.deinit();
            var h3 = try rt.spawn(task3, .{rt}, .{});
            defer h3.deinit();

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer task.deinit();

            // Wait for the future
            const result = try wait(rt, &future);
            try testing.expectEqual(@as(i32, 42), result.value);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer task.deinit();

            // Wait for the future
            const result = try wait(rt, &future);
            const value = try result.value;
            try testing.expectEqual(@as(i32, 123), value);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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
            defer task.deinit();

            // Wait for the future
            const result = try wait(rt, &future);
            try testing.expectError(MyError.Foo, result.value);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
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

    try runtime.runUntilComplete(TestContext.asyncTask, .{runtime}, .{});
}
