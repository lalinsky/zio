const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const AnyTask = @import("task.zig").AnyTask;
const resumeTask = @import("task.zig").resumeTask;
const waitForIo = @import("../io/base.zig").waitForIo;

/// A timeout that applies to all I/O operations on the current task.
/// Multiple Timeout instances can be nested - each has its own independent timer.
/// Timeouts are stack-allocated and managed via defer pattern.
///
/// When a timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const Timeout = struct {
    timer: xev.Timer = .{},
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    triggered: bool = false,
    task: ?*AnyTask = null,

    pub const init: Timeout = .{};

    pub fn clear(self: *Timeout, rt: *Runtime) void {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        // Check if timer is even active
        if (self.timer_c.state() != .active) {
            return;
        }

        // Use shield to prevent cancellation during cleanup
        rt.beginShield();
        defer rt.endShield();

        // Cancel the timer using a local completion
        var cancel_c: xev.Completion = .{};
        self.timer.cancel(
            &executor.loop,
            &self.timer_c,
            &cancel_c,
            Timeout,
            self,
            cancelCallback,
        );

        // Wait for the cancellation to complete properly
        waitForIo(rt, &cancel_c) catch unreachable; // Shield prevents cancel

        // Wait for the actual timer to finish
        waitForIo(rt, &self.timer_c) catch unreachable; // Shield prevents cancel

        // Clear task reference
        self.task = null;
    }

    pub fn set(self: *Timeout, rt: *Runtime, timeout_ns: u64) void {
        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        // Set task reference and reset triggered flag
        self.task = task;
        self.triggered = false;

        // Convert nanoseconds to milliseconds
        const timeout_ms: u64 = (timeout_ns + std.time.ns_per_ms / 2) / std.time.ns_per_ms;

        self.timer.reset(
            &executor.loop,
            &self.timer_c,
            &self.timer_cancel_c,
            timeout_ms,
            Timeout,
            self,
            timeoutCallback,
        );
    }
};

/// Callback when timeout timer fires
fn timeoutCallback(
    userdata: ?*Timeout,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const timeout = userdata orelse return .disarm;
    const task = timeout.task orelse return .disarm;

    result catch |err| switch (err) {
        error.Canceled => {
            resumeTask(task, .local);
            return .disarm;
        },
        else => {
            std.log.err("Timeout {*} failed: {}", .{ timeout, err });
            return .disarm;
        },
    };

    // Mark timeout as triggered and update cancellation status
    if (task.setTimeout()) {
        timeout.triggered = true;
    }

    // Resume the task
    resumeTask(task, .local);

    // Clear the associated task
    timeout.task = null;

    return .disarm;
}

/// Callback when timer cancellation completes
fn cancelCallback(
    userdata: ?*Timeout,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.CancelError!void,
) xev.CallbackAction {
    const timeout = userdata orelse return .disarm;
    const task = timeout.task orelse return .disarm;

    resumeTask(task, .local);

    return .disarm;
}

/// Timeout heap comparator - orders by earliest deadline first
fn timeoutLess(_: void, a: *Timeout, b: *Timeout) bool {
    return a.deadline_ms < b.deadline_ms;
}

/// Heap type for storing timeouts, ordered by earliest deadline
pub const TimeoutHeap = xev.heap.Intrusive(Timeout, void, timeoutLess);

const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;

test "Timeout: smoke test" {
    // TODO: test real timeouts
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            timeout.set(rt, 100 * std.time.ns_per_ms);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: fires and returns error.Timeout" {
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            timeout.set(rt, 10 * std.time.ns_per_ms);

            // Sleep longer than timeout
            rt.sleep(50) catch |err| {
                // Should return error.Timeout, not error.Canceled
                rt.checkTimeout(&timeout, err) catch |check_err| {
                    try std.testing.expectEqual(error.Timeout, check_err);
                    return; // Expected - timeout fired
                };
                return error.TestUnexpectedResult; // checkTimeout should have returned error
            };

            return error.TestUnexpectedResult; // Should have timed out
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: nested timeouts - earliest fires first" {
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout1 = Timeout.init;
            defer timeout1.clear(rt);
            var timeout2 = Timeout.init;
            defer timeout2.clear(rt);

            // Set longer timeout first
            timeout1.set(rt, 50 * std.time.ns_per_ms);
            // Then shorter timeout
            timeout2.set(rt, 10 * std.time.ns_per_ms);

            // Sleep - should be interrupted by timeout2 (earliest)
            rt.sleep(100) catch |err| {
                // Should return error.Timeout for timeout2
                rt.checkTimeout(&timeout2, err) catch |check_err| {
                    try std.testing.expectEqual(error.Timeout, check_err);
                    return; // Expected - timeout2 fired
                };
                return error.TestUnexpectedResult; // checkTimeout should have returned error
            };

            return error.TestUnexpectedResult; // Should have timed out
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: cleared before firing" {
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init;
            timeout.set(rt, 50 * std.time.ns_per_ms);

            // Clear timeout before it fires
            timeout.clear(rt);

            // Sleep should complete without timeout
            try rt.sleep(10);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: user cancel has priority over timeout" {
    const Test = struct {
        fn worker(rt: *Runtime) !void {
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            timeout.set(rt, 50 * std.time.ns_per_ms);

            // Sleep - will be canceled by user
            rt.sleep(100) catch |err| {
                // Should return error.Canceled (user has priority)
                try rt.checkTimeout(&timeout, err);
                return; // Expected
            };

            return error.TestUnexpectedResult;
        }

        fn main(rt: *Runtime) !void {
            var handle = try rt.spawn(worker, .{rt}, .{});

            // Let worker start and set timeout
            try rt.sleep(5);

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

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: multiple timeouts with different deadlines" {
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout1 = Timeout.init;
            defer timeout1.clear(rt);
            var timeout2 = Timeout.init;
            defer timeout2.clear(rt);
            var timeout3 = Timeout.init;
            defer timeout3.clear(rt);

            // Set timeouts: 30ms, 10ms (earliest), 20ms
            timeout1.set(rt, 30 * std.time.ns_per_ms);
            timeout2.set(rt, 10 * std.time.ns_per_ms); // This should fire
            timeout3.set(rt, 20 * std.time.ns_per_ms);

            // Sleep - should be interrupted by timeout2 (earliest at 10ms)
            rt.sleep(100) catch |err| {
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
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}

test "Timeout: set, clear, and re-set" {
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            // Set timeout
            timeout.set(rt, 20 * std.time.ns_per_ms);

            // Clear it
            timeout.clear(rt);

            // Re-set with shorter duration
            timeout.set(rt, 10 * std.time.ns_per_ms);

            // Sleep - should be interrupted by new timeout
            rt.sleep(50) catch |err| {
                rt.checkTimeout(&timeout, err) catch |check_err| {
                    try std.testing.expectEqual(error.Timeout, check_err);
                    return; // Expected - timeout fired
                };
                return error.TestUnexpectedResult; // checkTimeout should have returned error
            };

            return error.TestUnexpectedResult;
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}
