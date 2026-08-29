// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const zio_options = @import("options.zig").options;
const ev = @import("ev/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const getCurrentTask = @import("runtime.zig").getCurrentTask;
const recancel = @import("runtime.zig").recancel;
const checkCancel = @import("runtime.zig").checkCancel;
const yield = @import("runtime.zig").yield;
const loopClearTimer = @import("runtime.zig").loopClearTimer;
const JoinHandle = @import("runtime.zig").JoinHandle;
const Duration = @import("time.zig").Duration;
const Timeout = @import("time.zig").Timeout;
const Clock = @import("time.zig").Clock;
const Timestamp = @import("time.zig").Timestamp;
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

        if (loopClearTimer(loop, &self.timer)) {
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

    /// Arms against the monotonic clock. See `setClock` to pick another.
    pub fn set(self: *AutoCancel, timeout: Timeout) void {
        self.setClock(timeout, .awake);
    }

    /// Same as `set`, but measures `timeout` against `clock`.
    ///
    /// A `.deadline` is an absolute timestamp in that clock's epoch, so one on
    /// `.real` follows wall-clock adjustments where a monotonic deadline
    /// cannot. Only the wall clocks are valid for a timer; the CPU-time clocks
    /// are rejected when the timer is armed.
    pub fn setClock(self: *AutoCancel, timeout: Timeout, clock: Clock) void {
        // Retire the previous arm before touching this struct again. Two
        // things make that necessary: a timer still live on another
        // executor's loop cannot be re-armed from this one, and a callback
        // in flight is still writing `triggered` and `fired`, which the
        // resets below would race. `setTimer` asserts both.
        //
        // TODO: a re-arm could take the new deadline and the in-flight race
        // together, under the owning loop's timer lock where `phase` and
        // `has_result` can be read without racing, instead of disarming and
        // arming again. `Loop.clearTimer` has the states that would need
        // telling apart.
        self.clear();

        // Waiting forever means no timer at all.
        if (timeout == .none) return;

        const task = getCurrentTask();
        const executor = task.getExecutor();

        // Set task reference and reset the per-arm flags
        self.task = task;
        self.triggered.store(false, .monotonic);
        self.fired.store(0, .monotonic);

        // Initialize ev.Timer
        self.timer.c.userdata = self;
        self.timer.c.callback = autoCancelCallback;
        // Only ever written while disarmed. The clock picks which heap the
        // timer lives in, so moving it under an armed timer would disarm it
        // from the wrong one; the `clear` above is what makes this safe.
        self.timer.clock = clock;

        // Activate the timer
        executor.loopSetTimer(&self.timer, timeout);
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
    if (comptime !zio_options.scheduling.multiExecutor()) return error.SkipZigTest;
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

test "withTimeout: recancel re-arms a cancellation the timeout delivered" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const Work = struct {
        fn run(runtime: *Runtime) !void {
            runtime.sleep(.fromMilliseconds(60_000)) catch |err| {
                std.debug.assert(err == error.Canceled);
                // An auto-cancel is a cancellation like any other here: it can
                // be put back and delivered again, and withTimeout still gets
                // to attribute it and report error.Timeout.
                recancel();
                try checkCancel();
                return error.TestUnexpectedResult;
            };
            return error.TestUnexpectedResult;
        }
    };

    try std.testing.expectError(error.Timeout, withTimeout(.fromMilliseconds(10), Work.run, .{rt}));
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

test "AutoCancel: re-armed while the previous arm is still live on another executor" {
    if (comptime !zio_options.scheduling.multiExecutor()) return error.SkipZigTest;
    // The deadline is far past the end of the test, so every `set` below
    // re-arms a timer that is still sitting in some loop's heap. After a
    // migration that loop is not the one the task is running on, which is
    // what `setTimer` refuses to do.
    const worker = struct {
        fn call(rounds: usize) void {
            var timeout: AutoCancel = .init;
            defer timeout.clear();

            var round: usize = 0;
            while (round < rounds) : (round += 1) {
                timeout.set(.fromSeconds(60));
                var spin: usize = 0;
                while (spin < 16) : (spin += 1) yield() catch {};
            }
        }
    }.call;

    // More workers than executors, so they keep getting stolen and end up
    // running on an executor other than the one that armed their timer.
    const rt = try Runtime.init(std.testing.allocator, .{ .executors = .exact(4) });
    defer rt.deinit();

    var handles: [8]JoinHandle(void) = undefined;
    for (&handles) |*handle| {
        handle.* = try rt.spawn(worker, .{@as(usize, 200)});
    }
    for (&handles) |*handle| handle.join();
}

test "AutoCancel: set arms against the monotonic clock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    timeout.set(.fromMilliseconds(50));
    try std.testing.expectEqual(Clock.awake, timeout.timer.clock);
}

test "AutoCancel: setClock fires a duration measured on the real clock" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    timeout.setClock(.fromMilliseconds(10), .real);
    try std.testing.expectEqual(Clock.real, timeout.timer.clock);

    rt.sleep(.fromMilliseconds(500)) catch |err| {
        try std.testing.expect(timeout.check(err));
        return;
    };

    return error.TestUnexpectedResult;
}

test "AutoCancel: setClock takes an absolute deadline in the clock's own epoch" {
    // The deadline is a wall-clock timestamp, not an offset from now. Passing
    // it to a monotonic timer would read it as a point in the monotonic epoch,
    // which is time since boot and so already long past.
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    const deadline = Timestamp.now(.real).addDuration(.fromMilliseconds(10));
    timeout.setClock(.{ .deadline = deadline }, .real);

    rt.sleep(.fromMilliseconds(500)) catch |err| {
        try std.testing.expect(timeout.check(err));
        return;
    };

    return error.TestUnexpectedResult;
}

test "AutoCancel: re-arming on another clock leaves the first heap" {
    // Each clock has its own timer heap, and a disarm removes from the heap
    // named by `timer.clock`. Re-arming has to disarm under the old clock
    // before adopting the new one, or it corrupts the wrong heap.
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    // Far enough out that it is still armed, in the real clock's heap, when
    // the second arm moves it.
    timeout.setClock(.fromSeconds(60), .real);
    timeout.setClock(.fromMilliseconds(10), .awake);
    try std.testing.expectEqual(Clock.awake, timeout.timer.clock);

    rt.sleep(.fromMilliseconds(500)) catch |err| {
        try std.testing.expect(timeout.check(err));
        return;
    };

    return error.TestUnexpectedResult;
}

test "AutoCancel: a cleared real-clock timer does not fire" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    timeout.setClock(.fromMilliseconds(10), .real);
    timeout.clear();

    try rt.sleep(.fromMilliseconds(50));
}

test "AutoCancel: setClock with .none arms nothing" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var timeout: AutoCancel = .init;
    defer timeout.clear();

    timeout.setClock(.fromMilliseconds(10), .real);
    timeout.setClock(.none, .real);

    try rt.sleep(.fromMilliseconds(50));
}
