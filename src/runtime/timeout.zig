// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const ev = @import("../ev/root.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Duration = @import("../time.zig").Duration;
const AnyTask = @import("task.zig").AnyTask;
const resumeTask = @import("task.zig").resumeTask;
const waitForIo = @import("../io.zig").waitForIo;
const genericCallback = @import("../io.zig").genericCallback;

/// A timeout that applies to all I/O operations on the current task.
/// Multiple Timeout instances can be nested - each has its own independent timer.
/// Timeouts are stack-allocated and managed via defer pattern.
///
/// When a timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const Timeout = struct {
    timer: ev.Timer = .init(0),
    triggered: bool = false,
    task: ?*AnyTask = null,
    loop: ?*ev.Loop = null,

    pub const init: Timeout = .{};

    pub fn clear(self: *Timeout, rt: *Runtime) void {
        _ = rt;
        const loop = self.loop orelse return;
        if (self.timer.c.state != .running) return;

        loop.clearTimer(&self.timer);
        self.task = null;
        self.loop = null;
    }

    pub fn set(self: *Timeout, rt: *Runtime, timeout: Duration) void {
        // Skip setting timer if waiting forever
        if (timeout.ns == Duration.max.ns) return;

        const task = rt.getCurrentTask();
        const executor = task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        // Set task reference and reset triggered flag
        self.task = task;
        self.triggered = false;
        self.loop = &executor.loop;

        // Convert to milliseconds (saturating to avoid overflow)
        const timeout_ms: u64 = (timeout.ns +| std.time.ns_per_ms / 2) / std.time.ns_per_ms;

        // Initialize ev.Timer
        self.timer.c.userdata = self;
        self.timer.c.callback = timeoutCallback;

        // Activate the timer
        executor.loop.setTimer(&self.timer, timeout_ms);
    }
};

/// Callback when timeout timer fires
fn timeoutCallback(
    _: *ev.Loop,
    completion: *ev.Completion,
) void {
    const timeout: *Timeout = @ptrCast(@alignCast(completion.userdata.?));
    const task = timeout.task orelse return;

    // If there's no error, mark timeout as triggered
    if (completion.err == null) {
        if (task.setTimeout()) {
            timeout.triggered = true;
        }
    }

    // Resume the task
    resumeTask(task, .local);

    // Clear the associated task and loop
    timeout.task = null;
    timeout.loop = null;
}

const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;

test "Timeout: smoke test" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = Timeout.init;
    defer timeout.clear(rt);

    timeout.set(rt, .fromMilliseconds(100));
}

test "Timeout: fires and returns error.Timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = Timeout.init;
    defer timeout.clear(rt);

    timeout.set(rt, .fromMilliseconds(10));

    // Sleep longer than timeout
    rt.sleep(.fromMilliseconds(50)) catch |err| {
        // Should return error.Timeout, not error.Canceled
        rt.checkTimeout(&timeout, err) catch |check_err| {
            try std.testing.expectEqual(error.Timeout, check_err);
            return; // Expected - timeout fired
        };
        return error.TestUnexpectedResult; // checkTimeout should have returned error
    };

    return error.TestUnexpectedResult; // Should have timed out
}

test "Timeout: nested timeouts - earliest fires first" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout1 = Timeout.init;
    defer timeout1.clear(rt);
    var timeout2 = Timeout.init;
    defer timeout2.clear(rt);

    // Set longer timeout first
    timeout1.set(rt, .fromMilliseconds(50));
    // Then shorter timeout
    timeout2.set(rt, .fromMilliseconds(10));

    // Sleep - should be interrupted by timeout2 (earliest)
    rt.sleep(.fromMilliseconds(100)) catch |err| {
        // Should return error.Timeout for timeout2
        rt.checkTimeout(&timeout2, err) catch |check_err| {
            try std.testing.expectEqual(error.Timeout, check_err);
            return; // Expected - timeout2 fired
        };
        return error.TestUnexpectedResult; // checkTimeout should have returned error
    };

    return error.TestUnexpectedResult; // Should have timed out
}

test "Timeout: cleared before firing" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = Timeout.init;
    timeout.set(rt, .fromMilliseconds(50));

    // Clear timeout before it fires
    timeout.clear(rt);

    // Sleep should complete without timeout
    try rt.sleep(.fromMilliseconds(10));
}

test "Timeout: user cancel has priority over timeout" {
    const Test = struct {
        fn worker(rt: *Runtime) !void {
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            timeout.set(rt, .fromMilliseconds(50));

            // Sleep - will be canceled by user
            rt.sleep(.fromMilliseconds(100)) catch |err| {
                // Should return error.Canceled (user has priority)
                try rt.checkTimeout(&timeout, err);
                return; // Expected
            };

            return error.TestUnexpectedResult;
        }

        fn main(rt: *Runtime) !void {
            var handle = try rt.spawn(worker, .{rt}, .{});

            // Let worker start and set timeout
            try rt.sleep(.fromMilliseconds(5));

            // User cancel before timeout fires
            handle.cancel(rt);

            // Should get error.Canceled (user priority)
            handle.join(rt) catch |err| {
                try std.testing.expectEqual(error.Canceled, err);
                return;
            };

            return error.TestUnexpectedResult;
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(Test.main, .{rt}, .{});
    try handle.join(rt);
}

test "Timeout: multiple timeouts with different deadlines" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout1 = Timeout.init;
    defer timeout1.clear(rt);
    var timeout2 = Timeout.init;
    defer timeout2.clear(rt);
    var timeout3 = Timeout.init;
    defer timeout3.clear(rt);

    timeout1.set(rt, .fromMilliseconds(200));
    timeout2.set(rt, .fromMilliseconds(10)); // This should fire
    timeout3.set(rt, .fromMilliseconds(100));

    // Sleep - should be interrupted by timeout2 (earliest at 10ms)
    rt.sleep(.fromMilliseconds(1000)) catch |err| {
        // timeout2 should have triggered
        try std.testing.expect(timeout2.triggered);
        try std.testing.expect(!timeout1.triggered);
        try std.testing.expect(!timeout3.triggered);

        // Should return error.Timeout for timeout2
        rt.checkTimeout(&timeout2, err) catch |check_err| {
            try std.testing.expectEqual(error.Timeout, check_err);
            return; // Expected
        };
        return error.TestUnexpectedResult; // checkTimeout should have returned error
    };

    return error.TestUnexpectedResult;
}

test "Timeout: set, clear, and re-set" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = Timeout.init;
    defer timeout.clear(rt);

    // Set timeout
    timeout.set(rt, .fromMilliseconds(20));

    // Clear it
    timeout.clear(rt);

    // Re-set with shorter duration
    timeout.set(rt, .fromMilliseconds(10));

    // Sleep - should be interrupted by new timeout
    rt.sleep(.fromMilliseconds(50)) catch |err| {
        rt.checkTimeout(&timeout, err) catch |check_err| {
            try std.testing.expectEqual(error.Timeout, check_err);
            return; // Expected - timeout fired
        };
        return error.TestUnexpectedResult; // checkTimeout should have returned error
    };

    return error.TestUnexpectedResult;
}

test "Timeout: cancels spawned task via join" {
    const Test = struct {
        fn blocker(rt: *Runtime) !void {
            // Block forever
            try rt.sleep(.fromMilliseconds(1000000));
        }

        fn main(rt: *Runtime) !void {
            var handle = try rt.spawn(blocker, .{rt}, .{});
            defer handle.cancel(rt);

            var timeout = Timeout.init;
            defer timeout.clear(rt);
            timeout.set(rt, .fromMilliseconds(10));

            // Join should be canceled by timeout
            handle.join(rt) catch |err| {
                rt.checkTimeout(&timeout, err) catch |check_err| {
                    try std.testing.expectEqual(error.Timeout, check_err);
                    return; // Expected
                };
                return error.TestUnexpectedResult;
            };

            return error.TestUnexpectedResult;
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(Test.main, .{rt}, .{});
    try handle.join(rt);
}
