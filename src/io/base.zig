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
            timeout.triggered = true;
            return error.Canceled;
        }

        // Use timed wait with remaining time
        timedWaitForIo(rt, completion, timeout.deadline_ns - now_ns) catch |err| switch (err) {
            error.Timeout => {
                // Mark the timeout that expired
                timeout.triggered = true;
                return error.Canceled;
            },
            error.Canceled => return error.Canceled,
        };
        return;
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

/// Sleep for the specified duration in milliseconds.
/// Note: sleep() uses the task's timer mechanism and is NOT interruptible by Timeout.
/// For timeout-aware waiting, use other I/O operations or condition variables.
pub fn sleep(rt: *Runtime, duration_ms: u64) !void {
    const executor = rt.getCurrentExecutor().?;
    return executor.sleep(duration_ms);
}

// NOTE: Timeout tests are in the signal and networking tests since sleep() is not timeout-aware.
// Timeouts work with I/O operations like socket reads/writes, file I/O, and signal waits.
