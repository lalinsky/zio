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
pub fn runIo(rt: *Runtime, c: *ev.Completion) Cancelable!void {
    const task = rt.getCurrentTask();

    c.userdata = task;
    c.callback = struct {
        fn callback(_: *ev.Loop, completion: *ev.Completion) void {
            const t: *AnyTask = @ptrCast(@alignCast(completion.userdata.?));
            t.wake();
        }
    }.callback;

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
            if (c.isCompleted()) {
                // IO completed before we could cancel - restore the pending cancel
                task.recancel();
                return;
            }
            std.debug.assert(!canceling);
            rt.beginShield();
            canceling = true;
            continue;
        };
        std.debug.assert(c.isCompleted());
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
