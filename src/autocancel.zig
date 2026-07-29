// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const ev = @import("ev/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTask = @import("runtime.zig").getCurrentTask;
const yield = @import("runtime.zig").yield;
const JoinHandle = @import("runtime.zig").JoinHandle;
const Duration = @import("time.zig").Duration;
const Timeout = @import("time.zig").Timeout;
const AnyTask = @import("task.zig").AnyTask;
const meta = @import("meta.zig");
const Timeoutable = @import("common.zig").Timeoutable;

/// Automatically cancels I/O operations on the current task after a timeout.
/// Multiple AutoCancel instances can be nested - each has its own independent timer.
/// AutoCancels are stack-allocated and managed via defer pattern.
///
/// When the timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const AutoCancel = struct {
    timer: ev.Timer = .init(.{ .duration = .zero }),
    /// Whether this instance is the one that canceled the task. Written by the
    /// callback before it hands the cancellation to the task, and read by
    /// `check` on the task itself, so the two are ordered by the release/acquire
    /// pair on the task's cancel state rather than by touching this field.
    triggered: std.atomic.Value(bool) = .init(false),
    task: ?*AnyTask = null,
    /// Set by the callback, before it wakes the owner task, as its last touch
    /// of this struct. A `clear` that lost the disarm race parks on it, which
    /// keeps this struct (and the timer inside it) alive for exactly as long
    /// as the callback needs them.
    fired: std.atomic.Value(u32) = .init(0),

    pub const init: AutoCancel = .{};

    pub fn clear(self: *AutoCancel) void {
        const loop = self.timer.c.getLoop() orelse return;

        if (loop.clearTimer(&self.timer)) {
            self.task = null;
            return;
        }

        // The timer already fired or is completing, so its callback runs (or
        // has run) against this struct. Park until it is done with it; it
        // wakes this task after setting the flag.
        const task = getCurrentTask();
        while (self.fired.load(.acquire) == 0) {
            task.yield(.park, .no_cancel);
        }
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

        // Set task reference and reset the per-arm flags
        self.task = task;
        self.triggered.store(false, .monotonic);
        self.fired.store(0, .monotonic);

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
        // A user cancel that shadowed this one leaves the flag set (see the
        // callback), so `checkAutoCancel` is what decides; the flag only says
        // which instance to attribute an auto-cancel to.
        if (!self.triggered.load(.acquire)) return false;
        return getCurrentTask().checkAutoCancel();
    }
};

/// The return type of `withTimeout(timeout, func, args)`: whatever `func`
/// returns, with `error.Timeout` added to its error set.
pub fn WithTimeoutResult(func: anytype) type {
    const Ret = meta.ReturnType(func);
    return switch (@typeInfo(Ret)) {
        .error_union => |eu| (eu.error_set || Timeoutable)!eu.payload,
        else => Timeoutable!Ret,
    };
}

/// Run `func(args...)` on the current task, canceling it after `timeout`.
///
/// The scoped form of `AutoCancel`: arms a timer, runs `func`, and turns the
/// `error.Canceled` the timeout produced back into `error.Timeout`. The result
/// type is `func`'s own with `error.Timeout` added to its error set. A `.none`
/// timeout just calls `func`.
///
/// ```zig
/// const body = try zio.withTimeout(.fromSeconds(5), fetch, .{url});
/// ```
///
/// An explicit cancel of the task wins over the timeout and is reported as
/// `error.Canceled`, exactly as `AutoCancel.check` decides.
pub fn withTimeout(
    timeout: Timeout,
    func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) WithTimeoutResult(func) {
    var auto: AutoCancel = .init;
    auto.set(timeout);

    const ret = @call(.auto, func, args);

    auto.clear();

    const Ret = meta.ReturnType(func);
    if (@typeInfo(Ret) != .error_union) return ret;

    return ret catch |err| {
        if (comptime canBeCanceled(meta.ErrorSet(Ret))) {
            if (err == error.Canceled and auto.check(error.Canceled)) return error.Timeout;
        }
        return err;
    };
}

/// Whether `error.Canceled` can travel out of an error set, and so whether a
/// timeout on a `func` returning it could ever be observed.
fn canBeCanceled(comptime ErrorSet: type) bool {
    const errors = @typeInfo(ErrorSet).error_set orelse return true; // anyerror
    for (errors) |e| {
        if (std.mem.eql(u8, e.name, "Canceled")) return true;
    }
    return false;
}

/// Callback when auto-cancel timer fires
fn autoCancelCallback(
    _: *ev.Loop,
    completion: *ev.Completion,
) void {
    const autocancel: *AutoCancel = @ptrCast(@alignCast(completion.userdata.?));
    const task = autocancel.task;

    // Clear the associated task
    autocancel.task = null;

    // An error means the timer was cancelled, so don't cancel the task.
    if (completion.err == null) {
        if (task) |t| {
            // Claim the cancellation before handing it over: `setCanceled`
            // publishes this write, and the task can reach `check` as soon as
            // it can see the cancellation. Setting it afterwards let a task
            // that was running (rather than parked on this timer) observe the
            // cancel first and report it as a plain cancel.
            //
            // A shadowing user cancel makes the claim wrong, so take it back.
            // The window is harmless: `check` only trusts the flag to pick an
            // instance, and `checkAutoCancel` refuses once the task is
            // user-canceled.
            autocancel.triggered.store(true, .release);
            if (!t.setCanceled(.auto)) autocancel.triggered.store(false, .monotonic);
        }
    }

    // Last touch of `autocancel`: publishes the writes above to a `clear` that
    // lost the disarm race and is parked on this flag. Nothing below may touch
    // the struct or the completion again, since observing the flag lets the
    // owner drop the frame both live in.
    autocancel.fired.store(1, .release);

    // Wake unconditionally: the owner may be parked in `clear` waiting for the
    // flag even when the cancel did not take. A wake with nothing parked just
    // leaves an awaken token, which the park loops consume harmlessly.
    if (task) |t| t.wake();
}

const Cancelable = @import("common.zig").Cancelable;

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
    const worker = struct {
        fn call(rt: *Runtime) !void {
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
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(worker, .{rt});

    // Let worker start and set timeout
    try rt.sleep(.fromMilliseconds(5));

    // User cancel before timeout fires
    handle.cancel();

    // Worker handles the cancellation gracefully, so join succeeds
    try handle.join();
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
        try std.testing.expect(timeout2.triggered.load(.acquire));
        try std.testing.expect(!timeout1.triggered.load(.acquire));
        try std.testing.expect(!timeout3.triggered.load(.acquire));

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

test "AutoCancel: attributed when it fires on a task running elsewhere" {
    // Attribution under churn: the callback hands the cancellation over from
    // the loop that armed the timer, which after a migration is not the
    // executor the task runs on. This does not reproduce the ordering window
    // between claiming and handing over (that needs the loop thread to stall
    // between two adjacent stores), it covers the surrounding path.
    const worker = struct {
        fn call(rounds: usize, unattributed: *std.atomic.Value(u32)) void {
            var timeout: AutoCancel = .init;
            defer timeout.clear();

            var round: usize = 0;
            while (round < rounds) : (round += 1) {
                timeout.set(.fromMicroseconds(200));

                // Spin over cancellation points until the timer lands. Nothing
                // else cancels this task, so every cancellation seen here is
                // this timeout's.
                while (true) {
                    yield() catch |err| {
                        if (!timeout.check(err)) _ = unattributed.fetchAdd(1, .monotonic);
                        break;
                    };
                }
            }
        }
    }.call;

    // More workers than executors, so they keep getting stolen and end up
    // running on an executor other than the one that armed their timer.
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();

    var unattributed: std.atomic.Value(u32) = .init(0);
    var handles: [8]JoinHandle(void) = undefined;
    for (&handles) |*handle| {
        handle.* = try rt.spawn(worker, .{ @as(usize, 200), &unattributed });
    }
    for (&handles) |*handle| handle.join();

    try std.testing.expectEqual(0, unattributed.load(.monotonic));
}

test "AutoCancel: cancels spawned task via join" {
    const blocker = struct {
        fn call(rt: *Runtime) !void {
            // Block forever
            try rt.sleep(.fromMilliseconds(1000000));
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(blocker, .{rt});
    defer handle.cancel();

    var timeout = AutoCancel.init;
    defer timeout.clear();
    timeout.set(.fromMilliseconds(10));

    // Join should be canceled by timeout
    handle.join() catch |err| {
        try std.testing.expect(timeout.check(err));
        return; // Expected
    };

    return error.TestUnexpectedResult;
}

test "withTimeout: returns the value when func finishes in time" {
    const work = struct {
        fn call(rt: *Runtime) !u32 {
            try rt.sleep(.fromMilliseconds(5));
            return 42;
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectEqual(42, try withTimeout(.fromMilliseconds(500), work, .{rt}));
}

test "withTimeout: reports error.Timeout when func overruns" {
    const work = struct {
        fn call(rt: *Runtime) !void {
            try rt.sleep(.fromMilliseconds(500));
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectError(error.Timeout, withTimeout(.fromMilliseconds(10), work, .{rt}));
}

test "withTimeout: func's own error passes through unchanged" {
    const work = struct {
        fn call(_: *Runtime) error{ Boom, Canceled }!void {
            return error.Boom;
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectError(error.Boom, withTimeout(.fromMilliseconds(500), work, .{rt}));
}

test "withTimeout: result type is func's error set plus Timeout" {
    const fallible = struct {
        fn call() error{Boom}!u32 {
            return 1;
        }
    }.call;
    const infallible = struct {
        fn call() u32 {
            return 1;
        }
    }.call;

    try std.testing.expect(WithTimeoutResult(fallible) == (error{ Boom, Timeout }!u32));
    try std.testing.expect(WithTimeoutResult(infallible) == (error{Timeout}!u32));
}

test "withTimeout: a func that cannot fail still returns its value" {
    const work = struct {
        fn call(x: u32) u32 {
            return x * 2;
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectEqual(42, try withTimeout(.fromMilliseconds(500), work, .{@as(u32, 21)}));
}

test "withTimeout: .none runs func without a deadline" {
    const work = struct {
        fn call(rt: *Runtime) !u32 {
            try rt.sleep(.fromMilliseconds(5));
            return 7;
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectEqual(7, try withTimeout(.none, work, .{rt}));
}

test "withTimeout: user cancel wins over the timeout" {
    const worker = struct {
        fn call(rt: *Runtime) !void {
            const inner = struct {
                fn call(r: *Runtime) !void {
                    try r.sleep(.fromMilliseconds(500));
                }
            }.call;

            // The task is canceled from outside well before the deadline, so
            // this must surface as Canceled rather than Timeout.
            try std.testing.expectError(error.Canceled, withTimeout(.fromMilliseconds(200), inner, .{rt}));
        }
    }.call;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var handle = try rt.spawn(worker, .{rt});
    try rt.sleep(.fromMilliseconds(5));
    handle.cancel();
    try handle.join();
}

test "withTimeout: nested, inner deadline fires first" {
    const work = struct {
        fn outer(rt: *Runtime) !void {
            const inner = struct {
                fn call(r: *Runtime) !void {
                    try r.sleep(.fromMilliseconds(500));
                }
            }.call;
            try withTimeout(.fromMilliseconds(10), inner, .{rt});
        }
    }.outer;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectError(error.Timeout, withTimeout(.fromMilliseconds(1000), work, .{rt}));
}

test "withTimeout: nested, outer deadline fires while inner is running" {
    const work = struct {
        fn outer(rt: *Runtime) !void {
            const inner = struct {
                fn call(r: *Runtime) !void {
                    try r.sleep(.fromMilliseconds(500));
                }
            }.call;
            // The inner deadline never fires; the outer one interrupts it. The
            // inner wrapper must report that as Canceled and not claim it as
            // its own Timeout — asserted here, because the outer result is
            // error.Timeout either way and cannot tell the difference.
            try std.testing.expectError(error.Canceled, withTimeout(.fromMilliseconds(1000), inner, .{rt}));
            return error.Canceled;
        }
    }.outer;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expectError(error.Timeout, withTimeout(.fromMilliseconds(10), work, .{rt}));
}
