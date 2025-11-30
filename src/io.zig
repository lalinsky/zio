// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const aio = @import("aio");
const Runtime = @import("runtime.zig").Runtime;
const Executor = @import("runtime.zig").Executor;
const resumeTask = @import("core/task.zig").resumeTask;
const AnyTask = @import("core/task.zig").AnyTask;
const meta = @import("meta.zig");
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const Timeout = @import("core/timeout.zig").Timeout;

/// Generic callback that resumes the task stored in userdata
pub fn genericCallback(loop: *aio.Loop, completion: *aio.Completion) void {
    _ = loop;
    const task: *AnyTask = @ptrCast(@alignCast(completion.userdata.?));
    resumeTask(task, .local);
}

/// Cancels the I/O operation and waits for full completion.
pub fn cancelIo(rt: *Runtime, completion: *aio.Completion) void {
    // We can't handle user cancelations during this
    rt.beginShield();
    defer rt.endShield();

    // Cancel the operation and wait for the cancelation to complete
    var cancel = aio.Cancel{
        .c = aio.Completion.init(.cancel),
        .target = completion,
    };
    cancel.c.userdata = rt.getCurrentTask() orelse @panic("no active task");
    cancel.c.callback = genericCallback;

    const executor = rt.getCurrentTask().?.getExecutor();
    executor.loop.add(&cancel.c);
    waitForIo(rt, &cancel.c) catch {};

    // Now wait for the main operation to complete
    // This can't return error.Canceled because of the shield
    waitForIo(rt, completion) catch unreachable;
}

pub fn waitForIo(rt: *Runtime, completion: *aio.Completion) Cancelable!void {
    const task = rt.getCurrentTask() orelse @panic("no active task");
    var executor = task.getExecutor();

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed and callback was already called, restore ready state and exit
    // We must check for .dead (not .completed) because .completed means the callback
    // hasn't been called yet, and the completion is still referenced by the loop
    if (completion.state == .dead) {
        task.state.store(.ready, .release);
        return;
    }

    // Yield with atomic state transition (.preparing_to_wait -> .waiting)
    // If IO completes before the yield, the CAS inside yield() will fail and we won't suspend
    executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
        cancelIo(rt, completion);
        return err;
    };

    std.debug.assert(completion.state == .dead);
}

pub fn timedWaitForIo(rt: *Runtime, completion: *aio.Completion, timeout_ns: u64) (Timeoutable || Cancelable)!void {
    const task = rt.getCurrentTask() orelse @panic("no active task");
    var executor = task.getExecutor();

    // Set up timeout
    var timeout = Timeout.init;
    defer timeout.clear(rt);
    timeout.set(rt, timeout_ns);

    // Transition to preparing_to_wait state before yielding
    task.state.store(.preparing_to_wait, .release);

    // Re-check completion state after setting preparing_to_wait
    // If IO completed and callback was already called, restore ready state and exit
    // We must check for .dead (not .completed) because .completed means the callback
    // hasn't been called yet, and the completion is still referenced by the loop
    if (completion.state == .dead) {
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

    std.debug.assert(completion.state == .dead);
}

// Note: runIo and IoOperation have been removed in favor of working directly
// with aio's typed completions (FileRead, FileWrite, etc.)
