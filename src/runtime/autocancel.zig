// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const ev = @import("../ev/root.zig");
const Runtime = @import("../runtime.zig").Runtime;
const getCurrentTask = @import("../runtime.zig").getCurrentTask;
const Duration = @import("../time.zig").Duration;
const Timeout = @import("../time.zig").Timeout;
const AnyTask = @import("task.zig").AnyTask;

/// Automatically cancels I/O operations on the current task after a timeout.
/// Multiple AutoCancel instances can be nested - each has its own independent timer.
/// AutoCancels are stack-allocated and managed via defer pattern.
///
/// When the timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const AutoCancel = struct {
    timer: ev.Timer = .init(.{ .duration = .zero }),
    triggered: bool = false,
    task: ?*AnyTask = null,

    pub const init: AutoCancel = .{};

    pub fn clear(self: *AutoCancel) void {
        const loop = self.timer.c.loop orelse return;
        if (self.timer.c.state != .running) return;

        loop.clearTimer(&self.timer);
        self.task = null;
    }

    pub fn set(self: *AutoCancel, timeout: Timeout) void {
        // Disable timer if waiting forever
        if (timeout == .none) {
            self.clear();
            return;
        }

        const task = getCurrentTask();
        const executor = task.getExecutor();

        // Set task reference and reset triggered flag
        self.task = task;
        self.triggered = false;

        // Initialize ev.Timer
        self.timer.c.userdata = self;
        self.timer.c.callback = autoCancelCallback;

        // Activate the timer
        executor.loop.setTimer(&self.timer, timeout);
    }

    /// Check if this auto-cancel triggered the cancellation and consume it.
    /// Returns true if this auto-cancel caused the cancellation, false otherwise.
    /// User cancellation has priority - if the task was user-canceled, returns false.
    pub fn check(self: *AutoCancel, err: Cancelable) bool {
        std.debug.assert(err == error.Canceled);
        if (!self.triggered) return false;
        return getCurrentTask().checkAutoCancel();
    }
};

/// Callback when auto-cancel timer fires
fn autoCancelCallback(
    _: *ev.Loop,
    completion: *ev.Completion,
) void {
    const autocancel: *AutoCancel = @ptrCast(@alignCast(completion.userdata.?));
    const task = autocancel.task orelse return;

    // Clear the associated task
    autocancel.task = null;

    // If there's an error, the timer was cancelled - don't wake the task
    if (completion.err != null) return;

    // Try to cancel and wake only if we triggered (not shadowed by user cancel)
    if (task.setCanceled(.auto)) {
        autocancel.triggered = true;
        task.wake();
    }
}

const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;

test "AutoCancel: smoke test" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = AutoCancel.init;
    defer timeout.clear();

    timeout.set(.fromMilliseconds(100));
}

test "AutoCancel: fires and returns error.Timeout" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = AutoCancel.init;
    defer timeout.clear();

    timeout.set(.fromMilliseconds(10));

    // Sleep longer than timeout
    rt.sleep(.fromMilliseconds(50)) catch |err| {
        // Should return true (auto-cancel triggered)
        try std.testing.expect(timeout.check(err));
        return; // Expected - timeout fired
    };

    return error.TestUnexpectedResult; // Should have timed out
}

test "AutoCancel: nested timeouts - earliest fires first" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout1 = AutoCancel.init;
    defer timeout1.clear();
    var timeout2 = AutoCancel.init;
    defer timeout2.clear();

    // Set longer timeout first
    timeout1.set(.fromMilliseconds(50));
    // Then shorter timeout
    timeout2.set(.fromMilliseconds(10));

    // Sleep - should be interrupted by timeout2 (earliest)
    rt.sleep(.fromMilliseconds(100)) catch |err| {
        // Should return true for timeout2 (it triggered)
        try std.testing.expect(timeout2.check(err));
        return; // Expected - timeout2 fired
    };

    return error.TestUnexpectedResult; // Should have timed out
}

test "AutoCancel: cleared before firing" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = AutoCancel.init;
    timeout.set(.fromMilliseconds(50));

    // Clear timeout before it fires
    timeout.clear();

    // Sleep should complete without timeout
    try rt.sleep(.fromMilliseconds(10));
}

test "AutoCancel: user cancel has priority over timeout" {
    const Test = struct {
        fn worker(rt: *Runtime) !void {
            var timeout = AutoCancel.init;
            defer timeout.clear();

            timeout.set(.fromMilliseconds(50));

            // Sleep - will be canceled by user
            rt.sleep(.fromMilliseconds(100)) catch |err| {
                // Should return false (user cancel has priority)
                try std.testing.expect(!timeout.check(err));
                return; // Expected - handled the cancellation
            };

            return error.TestUnexpectedResult;
        }

        fn main(rt: *Runtime) !void {
            var handle = try rt.spawn(worker, .{rt});

            // Let worker start and set timeout
            try rt.sleep(.fromMilliseconds(5));

            // User cancel before timeout fires
            handle.cancel(rt);

            // Worker handles the cancellation gracefully, so join succeeds
            try handle.join(rt);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(Test.main, .{rt});
    try handle.join(rt);
}

test "AutoCancel: multiple timeouts with different deadlines" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout1 = AutoCancel.init;
    defer timeout1.clear();
    var timeout2 = AutoCancel.init;
    defer timeout2.clear();
    var timeout3 = AutoCancel.init;
    defer timeout3.clear();

    timeout1.set(.{ .duration = .fromMilliseconds(200) });
    timeout2.set(.fromMilliseconds(10)); // This should fire
    timeout3.set(.{ .duration = .fromMilliseconds(100) });

    // Sleep - should be interrupted by timeout2 (earliest at 10ms)
    rt.sleep(.fromMilliseconds(1000)) catch |err| {
        // timeout2 should have triggered
        try std.testing.expect(timeout2.triggered);
        try std.testing.expect(!timeout1.triggered);
        try std.testing.expect(!timeout3.triggered);

        // Should return true for timeout2
        try std.testing.expect(timeout2.check(err));
        return; // Expected
    };

    return error.TestUnexpectedResult;
}

test "AutoCancel: set, clear, and re-set" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout = AutoCancel.init;
    defer timeout.clear();

    // Set timeout
    timeout.set(.fromMilliseconds(20));

    // Clear it
    timeout.clear();

    // Re-set with shorter duration
    timeout.set(.fromMilliseconds(10));

    // Sleep - should be interrupted by new timeout
    rt.sleep(.fromMilliseconds(50)) catch |err| {
        try std.testing.expect(timeout.check(err));
        return; // Expected - timeout fired
    };

    return error.TestUnexpectedResult;
}

test "AutoCancel: set with Duration.max clears prior timer" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    // Set a short timeout
    timeout.set(.fromMilliseconds(10));

    // Disable it with .max
    timeout.set(.none);

    // Sleep longer than the original timeout - should NOT be canceled
    try rt.sleep(.fromMilliseconds(50));

    // If we reach here, the timer was properly cleared
}

test "AutoCancel: cancels spawned task via join" {
    const Test = struct {
        fn blocker(rt: *Runtime) !void {
            // Block forever
            try rt.sleep(.fromMilliseconds(1000000));
        }

        fn main(rt: *Runtime) !void {
            var handle = try rt.spawn(blocker, .{rt});
            defer handle.cancel(rt);

            var timeout = AutoCancel.init;
            defer timeout.clear();
            timeout.set(.fromMilliseconds(10));

            // Join should be canceled by timeout
            handle.join(rt) catch |err| {
                try std.testing.expect(timeout.check(err));
                return; // Expected
            };

            return error.TestUnexpectedResult;
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(Test.main, .{rt});
    try handle.join(rt);
}
