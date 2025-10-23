const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("runtime.zig").Cancelable;
const WaitNode = @import("core/WaitNode.zig");

// Future protocol:
//   * needs to have const Result = T
//   * needs to have asyncWait(*WaitNode) bool method (returns false if already complete)
//   * needs to have asyncCancelWait(*WaitNode) void method
//   * needs to have getResult() Result method

/// Extract the Future type, handling both direct types and pointers
fn FutureType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
}

pub fn SelectUnion(comptime S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var fields: [struct_fields.len]std.builtin.Type.UnionField = undefined;
    for (&fields, struct_fields) |*union_field, struct_field| {
        const Future = FutureType(struct_field.type);
        const Result = Future.Result;
        union_field.* = .{
            .name = struct_field.name,
            .type = Result,
            .alignment = struct_field.alignment,
        };
    }
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = std.meta.FieldEnum(S),
        .fields = &fields,
        .decls = &.{},
    } });
}

test "SelectUnion: result types" {
    const Future1 = struct {
        const Result = void;
    };
    const Future2 = struct {
        const Result = u32;
    };

    const Select = SelectUnion(struct {
        future1: Future1,
        future2: Future2,
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
/// `handles` is a struct with each field a `JoinHandle(T)`, where `T` can be different for each field.
/// Returns a tagged union with the same field names, containing the result of whichever completed first.
///
/// When multiple handles complete at the same time, fields are checked in declaration order
/// and the first ready handle is returned.
///
/// Example:
/// ```
/// var h1 = try rt.spawn(task1, .{}, .{});
/// var h2 = try rt.spawn(task2, .{}, .{});
/// const result = rt.select(.{ .first = h1, .second = h2 });
/// switch (result) {
///     .first => |val| ...,
///     .second => |val| ...,
/// }
/// ```
pub fn select(rt: *Runtime, futures: anytype) !SelectUnion(@TypeOf(futures)) {
    const S = @TypeOf(futures);
    const U = SelectUnion(S);
    const fields = @typeInfo(S).@"struct".fields;

    // Multi-wait path: Create separate waiter awaitables for each handle
    // We can't add the same awaitable to multiple lists (next/prev pointers conflict)
    const task = rt.getCurrentTask() orelse @panic("no active task");
    const executor = task.getExecutor();

    task.coro.state.store(.preparing_to_wait, .release);
    defer {
        const prev = task.coro.state.swap(.ready, .release);
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
    try executor.yield(.preparing_to_wait, .waiting_completion, .allow_cancel);

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

test "select: basic - first completes" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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

            const result = try select(rt, .{ .fast = fast, .slow = slow });
            switch (result) {
                .slow => |val| try testing.expectEqual(@as(i32, 42), val),
                .fast => |val| try testing.expectEqual(@as(i32, 99), val),
            }
            // Fast should win
            try testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: already complete - fast path" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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
            const result = try select(rt, .{ .immediate = immediate, .slow = slow });
            switch (result) {
                .immediate => |val| try testing.expectEqual(@as(i32, 123), val),
                .slow => return error.TestUnexpectedResult,
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: heterogeneous types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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
                .string = string_handle,
                .int = int_handle,
                .bool = bool_handle,
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

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: with cancellation" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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

            const result = try select(rt, .{ .first = h1, .second = h2 });
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
            select_handle.cancel();

            // Should return error.Canceled
            const result = select_handle.join();
            try testing.expectError(error.Canceled, result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: with error unions - success case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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
                .validate = validate_handle,
                .parse = parse_handle,
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

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: with error unions - error case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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

            const result = try select(rt, .{ .failing = failing, .slow = slow });

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "select: with mixed error types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
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
            const result = try select(rt, .{ .h2 = h2, .h1 = h1, .h3 = h3 });

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

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
