// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level thread wait primitives for blocking contexts.
//!
//! This module provides futex-like wait/wake operations for synchronizing
//! threads in blocking (non-async) contexts.

const std = @import("std");
const builtin = @import("builtin");

const Duration = @import("../time.zig").Duration;

const sys = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .freebsd => @import("freebsd.zig"),
    .openbsd => @import("openbsd.zig"),
    .netbsd => @import("netbsd.zig"),
    .dragonfly => @import("dragonfly.zig"),
    else => |t| if (t.isDarwin()) @import("darwin.zig") else @compileError("Unsupported OS: " ++ @tagName(t)),
};

/// Number of waiters to wake
pub const WakeCount = enum {
    /// Wake one waiter
    one,
    /// Wake all waiters
    all,
};

/// Low-level futex operations for thread synchronization.
///
/// Provides platform-specific wait/wake primitives that operate on atomic values.
/// This is an internal implementation detail - use the public `wait()` and `wake()`
/// functions or the `Event` type instead.
///
/// Methods:
/// - `wait(ptr, current, timeout)`: Block if *ptr == current, with optional timeout
/// - `wake(ptr, count)`: Wake waiting threads (one or all)
///
/// The implementation is selected at compile time based on the target OS.
const Futex = switch (builtin.os.tag) {
    .linux => FutexLinux,
    .windows => FutexWindows,
    .freebsd => FutexFreeBSD,
    .openbsd => FutexOpenBSD,
    .dragonfly => FutexDragonFly,
    else => |t| if (t.isDarwin()) FutexDarwin else void,
};

/// Thread synchronization event.
///
/// A higher-level abstraction over platform wait primitives that owns its state.
/// Use this instead of raw wait/wake functions when you need to own the state.
///
/// **Important**: Only one thread should wait on this event at a time.
/// For multi-waiter scenarios, use the raw wait/wake functions instead.
///
/// Example usage:
/// ```zig
/// var event: Event = .init();
///
/// // Waiter thread
/// event.wait(1, null); // Wait indefinitely
/// // or
/// event.wait(1, .fromSeconds(1)); // Wait with 1s timeout
///
/// // Signaler thread
/// event.signal();
/// ```
pub const Event = switch (builtin.os.tag) {
    .netbsd => EventNetBSD,
    else => EventFutex,
};

const FutexLinux = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
            current,
            if (timeout_ts) |*ts| ts else null,
            null,
            0,
        );
        // Ignore errors - spurious wakeups and timeouts are both fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(u32),
        };
        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAKE | sys.FUTEX_PRIVATE_FLAG,
            n,
            null,
            null,
            0,
        );
    }
};

// ============================================================================
// Windows implementation
// ============================================================================

const FutexWindows = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        // RtlWaitOnAddress takes timeout in 100ns units (negative = relative)
        const timeout_li: ?sys.LARGE_INTEGER = if (timeout) |t| blk: {
            const ns = t.toNanoseconds();
            const units_100ns = ns / 100;
            const i64_val = std.math.cast(i64, units_100ns) orelse std.math.maxInt(i64);
            break :blk -i64_val; // Negative means relative timeout
        } else null;

        // RtlWaitOnAddress atomically checks if *ptr == current before sleeping
        _ = sys.RtlWaitOnAddress(
            &ptr.raw,
            &current,
            @sizeOf(u32),
            if (timeout_li) |*t| t else null,
        );
        // Return value doesn't matter - we handle spurious wakeups in the caller's loop
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        switch (count) {
            .one => sys.RtlWakeAddressSingle(&ptr.raw),
            .all => sys.RtlWakeAddressAll(&ptr.raw),
        }
    }
};

// ============================================================================
// macOS/Darwin implementation
// ============================================================================

const FutexDarwin = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_us: u32 = if (timeout) |t| blk: {
            const us = t.toMicroseconds();
            break :blk std.math.cast(u32, us) orelse std.math.maxInt(u32);
        } else 0;

        _ = sys.__ulock_wait(
            sys.UL_COMPARE_AND_WAIT,
            @constCast(&ptr.raw),
            current,
            timeout_us,
        );
        // Ignore errors - spurious wakeups and timeouts are fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const flags: u32 = switch (count) {
            .one => sys.UL_COMPARE_AND_WAIT | sys.ULF_WAKE_THREAD,
            .all => sys.UL_COMPARE_AND_WAIT | sys.ULF_WAKE_ALL,
        };

        _ = sys.__ulock_wake(flags, @constCast(&ptr.raw), 0);
    }
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FutexFreeBSD = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys._umtx_op(
            @constCast(&ptr.raw),
            sys.UMTX_OP_WAIT_UINT,
            current,
            null,
            if (timeout_ts) |*ts| @ptrCast(@constCast(ts)) else null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(u32),
        };
        _ = sys._umtx_op(
            @constCast(&ptr.raw),
            sys.UMTX_OP_WAKE,
            n,
            null,
            null,
        );
    }
};

// ============================================================================
// OpenBSD implementation
// ============================================================================

const FutexOpenBSD = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys.futex(
            @constCast(&ptr.raw),
            sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
            @intCast(current),
            if (timeout_ts) |*ts| ts else null,
            null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = sys.futex(
            @constCast(&ptr.raw),
            sys.FUTEX_WAKE | sys.FUTEX_PRIVATE_FLAG,
            n,
            null,
            null,
        );
    }
};

// ============================================================================
// DragonFly BSD implementation
// ============================================================================

const FutexDragonFly = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ns = if (timeout) |t| t.toNanoseconds() else 0;
        _ = sys.umtx_sleep(
            &ptr.raw,
            @intCast(current),
            @intCast(timeout_ns),
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = sys.umtx_wakeup(&ptr.raw, n);
    }
};

// ============================================================================
// Event implementations
// ============================================================================

/// Futex-based event for platforms with futex-like primitives
const EventFutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn init() EventFutex {
        return .{};
    }

    pub fn wait(self: *EventFutex, current: u32, timeout: ?Duration) void {
        Futex.wait(&self.state, current, timeout);
    }

    pub fn signal(self: *EventFutex) void {
        _ = self.state.fetchAdd(1, .release);
        Futex.wake(&self.state, .one);
    }
};

/// NetBSD event using native _lwp_park/_lwp_unpark
const EventNetBSD = struct {
    state: std.atomic.Value(u32) = .init(0),
    lwp_id: c_int,

    pub fn init() EventNetBSD {
        return .{
            .lwp_id = sys._lwp_self(),
        };
    }

    pub fn wait(self: *EventNetBSD, current: u32, timeout: ?Duration) void {
        _ = self;
        _ = current; // Caller checks state, we just park

        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys.___lwp_park60(
            @intFromEnum(std.posix.CLOCK.MONOTONIC),
            0,
            if (timeout_ts) |*ts| ts else null,
            0, // unpark: don't unpark anyone
            null, // hint
            null, // unparkhint
        );
    }

    pub fn signal(self: *EventNetBSD) void {
        _ = self.state.fetchAdd(1, .release);
        _ = sys._lwp_unpark(self.lwp_id, null);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Event - basic signal and wait" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    var ready = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        event: *Event,
        ready: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            // Signal that we're ready to wait
            ctx.ready.store(true, .release);

            // Wait for signal
            var state = ctx.event.state.load(.monotonic);
            while (!ctx.done.load(.acquire)) {
                ctx.event.wait(state, .fromMilliseconds(100));
                state = ctx.event.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .event = &event, .ready = &ready, .done = &done };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Signal the event
    done.store(true, .release);
    event.signal();
}

test "Event - multiple signals" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    var counter = std.atomic.Value(u32).init(0);
    var ready = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        event: *Event,
        counter: *std.atomic.Value(u32),
        ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            ctx.ready.store(true, .release);
            var state = ctx.event.state.load(.monotonic);
            while (ctx.counter.load(.acquire) < 3) {
                ctx.event.wait(state, .fromMilliseconds(100));
                state = ctx.event.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .event = &event, .counter = &counter, .ready = &ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Send multiple signals
    for (0..3) |_| {
        _ = counter.fetchAdd(1, .release);
        event.signal();
        std.Thread.yield() catch {};
    }
}

test "Event - timeout" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    const start = std.time.nanoTimestamp();

    // Wait with timeout, should return after approximately 50ms
    event.wait(0, .fromMilliseconds(50));

    const elapsed = std.time.nanoTimestamp() - start;
    // Allow some slack for scheduling
    try std.testing.expect(elapsed >= 40 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 200 * std.time.ns_per_ms);
}
