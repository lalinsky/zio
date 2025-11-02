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

/// Cancels the I/O operation and waits for full completion.
pub fn cancelIo(rt: *Runtime, completion: *xev.Completion) void {
    // We can't handle user cancelations during this
    rt.beginShield();
    defer rt.endShield();

    // Cancel the operation and wait for the cancelation to complete
    var cancel_completion: xev.Completion = .{ .op = .{ .cancel = .{ .c = completion } } };
    runIo(rt, &cancel_completion, "cancel") catch {};

    // Now wait for the main operation to complete
    // This can't return error.Canceled because of the shield
    waitForIo(rt, completion) catch unreachable;
}

pub fn waitForIo(rt: *Runtime, completion: *xev.Completion) Cancelable!void {
    const task = rt.getCurrentTask() orelse @panic("no active task");
    var executor = task.getExecutor();

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed, restore ready state and exit
    if (completion.state() != .active) {
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        cancelIo(rt, completion);
        return err;
    };

    std.debug.assert(completion.state() == .dead);
}

pub fn timedWaitForIo(rt: *Runtime, completion: *xev.Completion, timeout_ns: u64) (Timeoutable || Cancelable)!void {
    const task = rt.getCurrentTask() orelse @panic("no active task");
    var executor = task.getExecutor();

    // Set up timeout
    var timeout = Timeout.init;
    defer timeout.clear(rt);
    timeout.set(rt, timeout_ns);

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed, restore ready state and exit
    if (completion.state() != .active) {
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        // Classify the error before clearing timeout state
        const classified_err = rt.checkTimeout(&timeout, err);
        timeout.clear(rt);
        cancelIo(rt, completion);
        return classified_err;
    };

    std.debug.assert(completion.state() == .dead);
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
