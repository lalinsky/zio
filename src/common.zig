// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const ev = @import("ev/root.zig");
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
