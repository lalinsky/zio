// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const ev = @import("ev/root.zig");
const Duration = @import("time.zig").Duration;
const Timeout = @import("time.zig").Timeout;
const Runtime = @import("runtime.zig").Runtime;
const AnyTask = @import("runtime/task.zig").AnyTask;

/// Error set for operations that can be cancelled
pub const Cancelable = error{
    Canceled,
};

/// Error set for operations that can timeout
pub const Timeoutable = error{
    Timeout,
};

/// Runs an I/O operation to completion.
/// Sets up the callback, submits to the event loop, and waits for completion.
pub fn waitForIo(rt: *Runtime, c: *ev.Completion) Cancelable!void {
    const task = rt.getCurrentTask();

    const Context = struct {
        task: *AnyTask,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn callback(_: *ev.Loop, completion: *ev.Completion) void {
            const ctx: *@This() = @ptrCast(@alignCast(completion.userdata.?));
            ctx.completed.store(true, .release);
            ctx.task.wake();
        }
    };

    var ctx = Context{ .task = task };
    c.userdata = &ctx;
    c.callback = Context.callback;

    defer if (std.debug.runtime_safety) {
        c.callback = null;
        c.userdata = null;
    };

    var canceling = false;
    while (true) {
        task.state.store(.preparing_to_wait, .release);
        var executor = task.getExecutor();

        if (canceling) {
            executor.loop.cancel(c);
        } else {
            executor.loop.add(c);
        }

        executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch {
            if (ctx.completed.load(.acquire)) {
                // IO completed before we could cancel - restore the pending cancel
                task.recancel();
                return;
            }
            std.debug.assert(!canceling);
            rt.beginShield();
            canceling = true;
            continue;
        };
        std.debug.assert(ctx.completed.load(.acquire));
        break;
    }

    if (canceling) {
        rt.endShield();
        if (c.err) |err| {
            if (err == error.Canceled) {
                return error.Canceled;
            }
        }
        // IO completed successfully despite cancel request - restore the pending cancel
        task.recancel();
    }
}

/// Runs an I/O operation to completion with a timeout.
/// If the timeout expires before the I/O completes, returns `error.Timeout`.
/// If the timeout is `.none`, waits indefinitely (just calls `waitForIo`).
pub fn timedWaitForIo(rt: *Runtime, c: *ev.Completion, timeout: Timeout) (Timeoutable || Cancelable)!void {
    if (timeout == .none) {
        return waitForIo(rt, c);
    }

    var group = ev.Group.init(.race);
    var timer = ev.Timer.init(timeout);

    group.add(c);
    group.add(&timer.c);

    try waitForIo(rt, &group.c);

    // Check if the IO was cancelled by the timeout
    // (both could complete in a race, so check if IO was actually cancelled)
    if (c.err) |err| {
        if (err == error.Canceled) {
            return error.Timeout;
        }
    }
}

test "waitForIo: basic timer completion" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try waitForIo(rt, &timer.c);
}

test "timedWaitForIo: timeout interrupts long operation" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Long timer (1 second) with short timeout (10ms)
    var timer = ev.Timer.init(.{ .duration = .fromSeconds(1) });
    try std.testing.expectError(error.Timeout, timedWaitForIo(rt, &timer.c, .{ .duration = .fromMilliseconds(10) }));
}

test "timedWaitForIo: completes before timeout" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    // Short timer (10ms) with long timeout (1 second)
    var timer = ev.Timer.init(.{ .duration = .fromMilliseconds(10) });
    try timedWaitForIo(rt, &timer.c, .{ .duration = .fromSeconds(1) });
}
