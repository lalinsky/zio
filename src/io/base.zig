// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const resumeTask = @import("../core/task.zig").resumeTask;
const AnyTask = @import("../core/task.zig").AnyTask;
const meta = @import("../meta.zig");
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Timeout = @import("../core/timeout.zig").Timeout;

pub fn cancelIo(rt: *Runtime, completion: *xev.Completion) void {
    var cancel_completion: xev.Completion = .{ .op = .{ .cancel = .{ .c = completion } } };

    rt.beginShield();
    defer rt.endShield();

    runIo(rt, &cancel_completion, "cancel") catch {};
}

pub fn waitForIo(rt: *Runtime, completion: *xev.Completion) !void {
    var canceled = false;
    defer if (canceled) rt.endShield();

    while (completion.state() == .active) {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        var executor = rt.getCurrentExecutor() orelse @panic("no active executor");

        // Transition to preparing_to_wait state before yielding
        task.state.store(.preparing_to_wait, .release);

        // Re-check completion state after setting preparing_to_wait
        // If IO completed, restore ready state and exit
        if (completion.state() != .active) {
            task.state.store(.ready, .release);
            break;
        }

        // Yield with atomic state transition (.preparing_to_wait -> .waiting)
        // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
        executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| switch (err) {
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
    const executor = task.getExecutor();

    var canceled = false;
    var timed_out = false;
    defer if (canceled or timed_out) rt.endShield();

    // Set up timeout
    var timeout = Timeout.init;
    defer timeout.clear(rt);
    timeout.set(rt, timeout_ns);

    while (completion.state() == .active) {
        // Transition to preparing_to_wait state before yielding
        task.state.store(.preparing_to_wait, .release);

        // Yield with atomic state transition (.preparing_to_wait -> .waiting)
        executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
            if (err == error.Canceled and timeout.triggered) {
                // Timeout triggered - cancel I/O if it's still active and we haven't already
                if (completion.state() == .active and !timed_out and !canceled) {
                    timed_out = true;
                    timeout.clear(rt); // Clear timeout so subsequent iterations don't timeout
                    rt.beginShield();
                    cancelIo(rt, completion);
                }
                continue;
            }
            // Explicit cancellation - cancel I/O if it's still active and we haven't already
            if (completion.state() == .active and !canceled and !timed_out) {
                canceled = true;
                timeout.clear(rt); // Clear timeout so we don't get a spurious timeout
                rt.beginShield();
                cancelIo(rt, completion);
            }
            continue;
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
