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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        // __ulock_wait is undocumented but stable (Darwin 16+, macOS 10.12+)
        // Used by LLVM libc++ internally
        const UL_COMPARE_AND_WAIT = 1;

        const timeout_us: u32 = if (timeout_ns) |ns| blk: {
            const us = ns / std.time.ns_per_us;
            break :blk std.math.cast(u32, us) orelse std.math.maxInt(u32);
        } else 0;

        _ = __ulock_wait(
            UL_COMPARE_AND_WAIT,
            @constCast(&ptr.raw),
            current,
            timeout_us,
        );
        // Ignore errors - spurious wakeups and timeouts are fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const UL_COMPARE_AND_WAIT = 1;
        const ULF_WAKE_THREAD = 0x100;
        const ULF_WAKE_ALL = 0x200;

        const flags: u32 = switch (count) {
            .one => UL_COMPARE_AND_WAIT | ULF_WAKE_THREAD,
            .all => UL_COMPARE_AND_WAIT | ULF_WAKE_ALL,
        };

        _ = __ulock_wake(flags, @constCast(&ptr.raw), 0);
    }

    extern "c" fn __ulock_wait(operation: u32, addr: *u32, value: u64, timeout_us: u32) c_int;
    extern "c" fn __ulock_wake(operation: u32, addr: *u32, wake_value: u64) c_int;
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FutexFreeBSD = struct {
    const UMTX_OP_WAIT_UINT = 11;
    const UMTX_OP_WAKE = 3;

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = _umtx_op(
            @constCast(&ptr.raw),
            UMTX_OP_WAIT_UINT,
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
        _ = _umtx_op(
            @constCast(&ptr.raw),
            UMTX_OP_WAKE,
            n,
            null,
            null,
        );
    }

    extern "c" fn _umtx_op(obj: *u32, op: c_int, val: c_ulong, uaddr: ?*anyopaque, uaddr2: ?*anyopaque) c_int;
};

// ============================================================================
// OpenBSD implementation
// ============================================================================

const FutexOpenBSD = struct {
    const FUTEX_WAIT = 1;
    const FUTEX_WAKE = 2;
    const FUTEX_PRIVATE_FLAG = 128;

    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAIT | FUTEX_PRIVATE_FLAG,
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
        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAKE | FUTEX_PRIVATE_FLAG,
            n,
            null,
            null,
        );
    }

    extern "c" fn futex(uaddr: *u32, op: c_int, val: c_int, timeout: ?*const std.posix.timespec, uaddr2: ?*u32) c_int;
};

// ============================================================================
// DragonFly BSD implementation
// ============================================================================

const FutexDragonFly = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout_ns: ?u64) void {
        // Note: umtx_sleep's comparison is NOT atomic with sleep, but is
        // "properly interlocked" with umtx_wakeup. This works correctly
        // with our counter + loop pattern in Waiter.
        _ = umtx_sleep(
            @constCast(&ptr.raw),
            @intCast(current),
            @intCast(timeout_ns orelse 0),
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = umtx_wakeup(@constCast(&ptr.raw), n);
    }

    extern "c" fn umtx_sleep(addr: *const u32, value: c_int, timeout: c_int) c_int;
    extern "c" fn umtx_wakeup(addr: *const u32, count: c_int) c_int;
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
    state: std.atomic.Value(u32) = .init(0),
    lwp_id: c_int,

    pub fn init() EventNetBSD {
        return .{
            .lwp_id = _lwp_self(),
        };
    }

    pub fn wait(self: *EventNetBSD, current: u32, timeout_ns: ?u64) void {
        _ = self;
        _ = current; // Caller checks state, we just park

        const timeout_ts: ?std.posix.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = ___lwp_park60(
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
        _ = _lwp_unpark(self.lwp_id, null);
    }

    extern "c" fn _lwp_self() c_int;
    extern "c" fn ___lwp_park60(
        clock_id: c_int,
        flags: c_int,
        ts: ?*const std.posix.timespec,
        unpark: c_int,
        hint: ?*const anyopaque,
        unparkhint: ?*const anyopaque,
    ) c_int;
    extern "c" fn _lwp_unpark(target: c_int, hint: ?*const anyopaque) c_int;
};
