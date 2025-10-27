const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const resumeTask = @import("../core/task.zig").resumeTask;
const AnyTask = @import("../core/task.zig").AnyTask;
const meta = @import("../meta.zig");
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;

pub fn cancelIo(rt: *Runtime, completion: *xev.Completion) void {
    var cancel_completion: xev.Completion = .{ .op = .{ .cancel = .{ .c = completion } } };

    rt.beginShield();
    defer rt.endShield();

    runIo(rt, &cancel_completion, "cancel") catch {};
}

pub fn waitForIo(rt: *Runtime, completion: *xev.Completion) !void {
    const task = rt.getCurrentTask() orelse @panic("no active task");

    // Check if there's an active timeout deadline
    if (task.timeout_heap.peek()) |timeout| {
        const executor = task.getExecutor();
        const now_ns = @as(u64, @intCast(executor.loop.now())) * 1_000_000;

        // Check if already past deadline
        if (now_ns >= timeout.deadline_ns) {
            return error.Timeout;
        }

        // Use timed wait with remaining time
        return timedWaitForIo(rt, completion, timeout.deadline_ns - now_ns);
    }

    // No timeout - use original infinite wait logic
    var canceled = false;
    defer if (canceled) rt.endShield();

    while (completion.state() == .active) {
        var executor = rt.getCurrentExecutor() orelse @panic("no active executor");
        executor.yield(.ready, .waiting_io, .allow_cancel) catch |err| switch (err) {
            error.Canceled => {
                if (!canceled) {
                    canceled = true;
                    rt.beginShield();
                    cancelIo(rt, completion);
                }
                continue;
            },
        };
        std.debug.assert(completion.state() == .dead);
        break;
    }

    if (canceled) {
        return error.Canceled;
    }
}

pub fn timedWaitForIo(rt: *Runtime, completion: *xev.Completion, timeout_ns: u64) (Timeoutable || Cancelable)!void {
    const task = rt.getCurrentTask() orelse @panic("no active task");

    var canceled = false;
    var timed_out = false;
    defer if (canceled or timed_out) rt.endShield();

    const TimeoutContext = struct {
        completion: *xev.Completion,
        canceled: *bool,
    };

    var timeout_ctx = TimeoutContext{
        .completion = completion,
        .canceled = &canceled,
    };

    while (completion.state() == .active) {
        task.getExecutor().timedWaitForReadyWithCallback(
            .ready,
            .waiting_io,
            timeout_ns,
            TimeoutContext,
            &timeout_ctx,
            struct {
                fn onTimeout(ctx: *TimeoutContext) bool {
                    // Only timeout if I/O hasn't completed and hasn't been canceled
                    return ctx.completion.state() == .active and ctx.canceled.* == false;
                }
            }.onTimeout,
        ) catch |err| switch (err) {
            error.Timeout => {
                // Cancel the I/O operation on timeout
                if (!timed_out) {
                    timed_out = true;
                    if (!canceled) {
                        rt.beginShield();
                        cancelIo(rt, completion);
                    }
                }
                continue;
            },
            error.Canceled => {
                if (!canceled) {
                    canceled = true;
                    if (!timed_out) {
                        rt.beginShield();
                        cancelIo(rt, completion);
                    }
                }
                continue;
            },
        };
        std.debug.assert(completion.state() == .dead);
        break;
    }

    if (timed_out) {
        return error.Timeout;
    }

    if (canceled) {
        return error.Canceled;
    }
}

pub fn runIo(rt: *Runtime, completion: *xev.Completion, comptime op: []const u8) !meta.Payload(@FieldType(xev.Result, op)) {
    return try IoOperation(op).run(rt, completion);
}

pub fn IoOperation(comptime op: []const u8) type {
    return struct {
        const Self = @This();
        const ResultType = @FieldType(xev.Result, op);

        task: *AnyTask,
        result: @FieldType(xev.Result, op) = undefined,

        pub fn callback(userdata: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, result: xev.Result) xev.CallbackAction {
            const self: *Self = @ptrCast(@alignCast(userdata));
            self.result = @field(result, op);
            resumeTask(self.task, .local);
            return .disarm;
        }

        pub fn run(rt: *Runtime, completion: *xev.Completion) !meta.Payload(ResultType) {
            const task = rt.getCurrentTask() orelse @panic("no active task");
            const executor = task.getExecutor();

            var self = Self{ .task = task };

            completion.userdata = &self;
            completion.callback = callback;

            executor.loop.add(completion);
            try waitForIo(rt, completion);

            return self.result;
        }
    };
}

pub fn sleep(rt: *Runtime, duration_ms: u64) !void {
    const executor = rt.getCurrentExecutor().?;

    var completion: xev.Completion = .{ .op = .{ .timer = .{
        .next = executor.loop.timer_next(duration_ms),
    } } };

    _ = try runIo(rt, &completion, "timer");
}

// ============================================================================
// Tests
// ============================================================================

const Timeout = @import("../core/timeout.zig").Timeout;

test "Timeout: basic timeout on sleep" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn testTask(rt: *Runtime) !void {
            var timeout = Timeout.init(rt);
            defer timeout.deinit(rt);

            timeout.set(rt, 100); // 100ms timeout

            // Try to sleep for 1 second - should timeout
            const result = sleep(rt, 1000);
            try testing.expectError(error.Timeout, result);
        }
    };

    try runtime.runUntilComplete(TestContext.testTask, .{runtime}, .{});
}

test "Timeout: nested timeouts - inner more restrictive" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn testTask(rt: *Runtime) !void {
            var outer_timeout = Timeout.init(rt);
            defer outer_timeout.deinit(rt);
            outer_timeout.set(rt, 1000); // 1 second

            {
                var inner_timeout = Timeout.init(rt);
                defer inner_timeout.deinit(rt);
                inner_timeout.set(rt, 50); // 50ms (more restrictive)

                // Should timeout after 50ms due to inner timeout
                const result = sleep(rt, 500);
                try testing.expectError(error.Timeout, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.testTask, .{runtime}, .{});
}

test "Timeout: nested timeouts - outer applies after inner deinit" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn testTask(rt: *Runtime) !void {
            var outer_timeout = Timeout.init(rt);
            defer outer_timeout.deinit(rt);
            outer_timeout.set(rt, 200); // 200ms

            // Inner timeout that gets removed
            {
                var inner_timeout = Timeout.init(rt);
                defer inner_timeout.deinit(rt);
                inner_timeout.set(rt, 50); // 50ms

                // Sleep for less than inner timeout - should succeed
                try sleep(rt, 30);
            }

            // Now only outer timeout applies
            // Sleep for 100ms should succeed (under 200ms outer timeout)
            try sleep(rt, 100);

            // But sleeping another 150ms should fail (total >200ms)
            const result = sleep(rt, 150);
            try testing.expectError(error.Timeout, result);
        }
    };

    try runtime.runUntilComplete(TestContext.testTask, .{runtime}, .{});
}

test "Timeout: no timeout allows infinite wait" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn testTask(rt: *Runtime) !void {
            // Sleep without any timeout should succeed
            try sleep(rt, 50);
        }
    };

    try runtime.runUntilComplete(TestContext.testTask, .{runtime}, .{});
}

test "Timeout: multiple set() calls update deadline" {
    const testing = std.testing;

    const runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn testTask(rt: *Runtime) !void {
            var timeout = Timeout.init(rt);
            defer timeout.deinit(rt);

            timeout.set(rt, 50); // Initial: 50ms

            // Sleep for 30ms
            try sleep(rt, 30);

            // Update to 100ms from now
            timeout.set(rt, 100);

            // Should succeed (new deadline is 100ms from the set() call)
            try sleep(rt, 80);
        }
    };

    try runtime.runUntilComplete(TestContext.testTask, .{runtime}, .{});
}
