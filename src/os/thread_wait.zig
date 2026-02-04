// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level thread wait primitives for blocking contexts.
//!
//! This module provides futex-like wait/wake operations for synchronizing
//! threads in blocking (non-async) contexts. It uses the best available
//! OS primitive on each platform:
//!
//! - Linux: futex() syscall
//! - Windows: WaitOnAddress/WakeByAddressSingle (40x faster than Event objects)
//! - macOS/Darwin: __ulock_wait/__ulock_wake
//! - FreeBSD: _umtx_op with UMTX_OP_WAIT_UINT/WAKE
//! - OpenBSD: futex() syscall (64 buckets)
//! - NetBSD: futex() syscall (Linux compat layer)
//! - DragonFly BSD: umtx_sleep/umtx_wakeup
//!
//! Example usage:
//! ```zig
//! var signaled: std.atomic.Value(u32) = .init(0);
//!
//! // Waiter thread
//! while (signaled.load(.acquire) < expected) {
//!     thread_wait.wait(&signaled, signaled.load(.monotonic));
//! }
//!
//! // Signaler thread
//! _ = signaled.fetchAdd(1, .release);
//! thread_wait.wake(&signaled, 1);
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// Number of waiters to wake
pub const WakeCount = enum {
    /// Wake one waiter
    one,
    /// Wake all waiters
    all,
};

const Futex = switch (builtin.os.tag) {
    .linux => FutexLinux,
    .windows => FutexWindows,
    .macos, .ios, .tvos, .watchos, .visionos => FutexDarwin,
    .freebsd => FutexFreeBSD,
    .openbsd => FutexOpenBSD,
    .netbsd => @compileError("NetBSD uses Event, not raw wait/wake"),
    .dragonfly => FutexDragonFly,
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
};

/// Thread synchronization event.
///
/// A higher-level abstraction over platform wait primitives that owns its state.
/// Use this instead of raw wait/wake functions when you need to own the state.
///
/// On futex-style platforms (Linux, Windows, macOS, *BSD except NetBSD), this uses
/// the generic futex implementation. On NetBSD, it uses the native _lwp_park/_lwp_unpark
/// which requires storing the LWP ID.
///
/// Example usage:
/// ```zig
/// var event: Event = .init();
///
/// // Waiter thread
/// event.wait(1, null); // Wait indefinitely
/// // or
/// event.wait(1, 1000 * std.time.ns_per_ms); // Wait with 1s timeout
///
/// // Signaler thread
/// event.signal();
/// ```
pub const Event = switch (builtin.os.tag) {
    .netbsd => EventNetBSD,
    else => EventFutex,
};

const FutexLinux = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const linux = std.os.linux;

        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = linux.futex_4arg(
            &ptr.raw,
            .{ .cmd = .WAIT, .private = true },
            current,
            if (timeout_ts) |*ts| ts else null,
        );
        // Ignore errors - spurious wakeups and timeouts are both fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const linux = std.os.linux;
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(u32),
        };
        _ = linux.futex_3arg(
            &ptr.raw,
            .{ .cmd = .WAKE, .private = true },
            n,
        );
    }
};

// ============================================================================
// Windows implementation
// ============================================================================

const FutexWindows = struct {
    const windows = @import("windows.zig");

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        // RtlWaitOnAddress takes timeout in 100ns units (negative = relative)
        const timeout_li: ?windows.LARGE_INTEGER = if (timeout_ns) |ns| blk: {
            const units_100ns = ns / 100;
            const i64_val = std.math.cast(i64, units_100ns) orelse std.math.maxInt(i64);
            break :blk -i64_val; // Negative means relative timeout
        } else null;

        // RtlWaitOnAddress atomically checks if *ptr == current before sleeping
        _ = windows.RtlWaitOnAddress(
            &ptr.raw,
            &current,
            @sizeOf(u32),
            if (timeout_li) |*t| t else null,
        );
        // Return value doesn't matter - we handle spurious wakeups in the caller's loop
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        switch (count) {
            .one => windows.RtlWakeAddressSingle(&ptr.raw),
            .all => windows.RtlWakeAddressAll(&ptr.raw),
        }
    }
};

// ============================================================================
// macOS/Darwin implementation
// ============================================================================

const FutexDarwin = struct {
    const darwin = @import("darwin.zig");

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const timeout_us: u32 = if (timeout_ns) |ns| blk: {
            const us = ns / std.time.ns_per_us;
            break :blk std.math.cast(u32, us) orelse std.math.maxInt(u32);
        } else 0;

        _ = darwin.__ulock_wait(
            darwin.UL_COMPARE_AND_WAIT,
            @constCast(&ptr.raw),
            current,
            timeout_us,
        );
        // Ignore errors - spurious wakeups and timeouts are fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const flags: u32 = switch (count) {
            .one => darwin.UL_COMPARE_AND_WAIT | darwin.ULF_WAKE_THREAD,
            .all => darwin.UL_COMPARE_AND_WAIT | darwin.ULF_WAKE_ALL,
        };

        _ = darwin.__ulock_wake(flags, @constCast(&ptr.raw), 0);
    }
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FutexFreeBSD = struct {
    const freebsd = @import("freebsd.zig");

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = freebsd._umtx_op(
            @constCast(&ptr.raw),
            freebsd.UMTX_OP_WAIT_UINT,
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
        _ = freebsd._umtx_op(
            @constCast(&ptr.raw),
            freebsd.UMTX_OP_WAKE,
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
    const openbsd = @import("openbsd.zig");

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = openbsd.futex(
            @constCast(&ptr.raw),
            openbsd.FUTEX_WAIT | openbsd.FUTEX_PRIVATE_FLAG,
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
        _ = openbsd.futex(
            @constCast(&ptr.raw),
            openbsd.FUTEX_WAKE | openbsd.FUTEX_PRIVATE_FLAG,
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
    const dragonfly = @import("dragonfly.zig");

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        _ = dragonfly.umtx_sleep(
            &ptr.raw,
            @intCast(current),
            @intCast(timeout_ns orelse 0),
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = dragonfly.umtx_wakeup(&ptr.raw, n);
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

    pub fn wait(self: *EventFutex, current: u32, timeout_ns: ?u64) void {
        Futex.wait(&self.state, current, timeout_ns);
    }

    pub fn signal(self: *EventFutex) void {
        _ = self.state.fetchAdd(1, .release);
        Futex.wake(&self.state, .one);
    }
};

/// NetBSD event using native _lwp_park/_lwp_unpark
const EventNetBSD = struct {
    const netbsd = @import("netbsd.zig");

    state: std.atomic.Value(u32) = .init(0),
    lwp_id: c_int,

    pub fn init() EventNetBSD {
        return .{
            .lwp_id = netbsd._lwp_self(),
        };
    }

    pub fn wait(self: *EventNetBSD, current: u32, timeout_ns: ?u64) void {
        _ = self;
        _ = current; // Caller checks state, we just park

        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = netbsd.___lwp_park60(
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
        _ = netbsd._lwp_unpark(self.lwp_id, null);
    }
};
