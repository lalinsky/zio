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

const Sys = switch (builtin.os.tag) {
    .linux => Linux,
    .windows => Windows,
    .macos, .ios, .tvos, .watchos, .visionos => Darwin,
    .freebsd => FreeBSD,
    .openbsd => OpenBSD,
    .netbsd => NetBSD,
    .dragonfly => DragonFly,
    else => @compileError("Unsupported OS: " ++ @tagName(builtin.os.tag)),
};

/// Wait until *ptr != expected, or until woken by wake().
/// The kernel atomically checks if *ptr == expected before sleeping,
/// preventing the lost wakeup race condition.
///
/// Spurious wakeups may occur - caller should loop checking their condition.
pub fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
    Sys.wait(ptr, expected, null);
}

/// Wake up to max_waiters threads waiting on ptr.
pub fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
    Sys.wake(ptr, max_waiters);
}

/// Wait with timeout (in nanoseconds).
/// Returns normally on wakeup or timeout - caller must check their condition
/// to determine which occurred.
pub fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: u64) void {
    Sys.wait(ptr, expected, timeout_ns);
}

// ============================================================================
// Linux implementation
// ============================================================================

const Linux = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        const linux = std.os.linux;

        const timeout_ts: ?std.os.linux.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = linux.futex_4arg(
            &ptr.raw,
            .{ .cmd = .WAIT, .private = true },
            expected,
            if (timeout_ts) |*ts| ts else null,
        );
        // Ignore errors - spurious wakeups and timeouts are both fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;

        const linux = std.os.linux;
        _ = linux.futex_3arg(
            &ptr.raw,
            .{ .cmd = .WAKE, .private = true },
            max_waiters,
        );
    }
};

// ============================================================================
// Windows implementation
// ============================================================================

const Windows = struct {
    const windows = @import("windows.zig");

    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        // RtlWaitOnAddress takes timeout in 100ns units (negative = relative)
        const timeout_li: ?windows.LARGE_INTEGER = if (timeout_ns) |ns| blk: {
            const units_100ns = ns / 100;
            const i64_val = std.math.cast(i64, units_100ns) orelse std.math.maxInt(i64);
            break :blk -i64_val; // Negative means relative timeout
        } else null;

        // RtlWaitOnAddress atomically checks if *ptr == expected before sleeping
        const compare_value = expected;
        _ = windows.RtlWaitOnAddress(
            &ptr.raw,
            &compare_value,
            @sizeOf(u32),
            if (timeout_li) |*t| t else null,
        );
        // Return value doesn't matter - we handle spurious wakeups in the caller's loop
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        _ = max_waiters; // Windows doesn't support waking specific count with this API
        windows.RtlWakeAddressSingle(&ptr.raw);
    }
};

// ============================================================================
// macOS/Darwin implementation
// ============================================================================

const Darwin = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
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
            expected,
            timeout_us,
        );
        // Ignore errors - spurious wakeups and timeouts are fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        _ = max_waiters; // Darwin doesn't support waking specific count with this API

        const UL_COMPARE_AND_WAIT = 1;
        const ULF_WAKE_THREAD = 0x100;

        _ = __ulock_wake(
            UL_COMPARE_AND_WAIT | ULF_WAKE_THREAD,
            @constCast(&ptr.raw),
            0,
        );
    }

    extern "c" fn __ulock_wait(operation: u32, addr: *u32, value: u64, timeout_us: u32) c_int;
    extern "c" fn __ulock_wake(operation: u32, addr: *u32, wake_value: u64) c_int;
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FreeBSD = struct {
    const UMTX_OP_WAIT_UINT = 11;
    const UMTX_OP_WAKE = 3;

    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.os.linux.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = _umtx_op(
            @constCast(&ptr.raw),
            UMTX_OP_WAIT_UINT,
            expected,
            null,
            if (timeout_ts) |*ts| @ptrCast(@constCast(ts)) else null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;

        _ = _umtx_op(
            @constCast(&ptr.raw),
            UMTX_OP_WAKE,
            max_waiters,
            null,
            null,
        );
    }

    extern "c" fn _umtx_op(obj: *u32, op: c_int, val: c_ulong, uaddr: ?*anyopaque, uaddr2: ?*anyopaque) c_int;
};

// ============================================================================
// OpenBSD implementation
// ============================================================================

const OpenBSD = struct {
    const FUTEX_WAIT = 1;
    const FUTEX_WAKE = 2;
    const FUTEX_PRIVATE_FLAG = 128;

    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.os.linux.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAIT | FUTEX_PRIVATE_FLAG,
            @intCast(expected),
            if (timeout_ts) |*ts| ts else null,
            null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;

        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAKE | FUTEX_PRIVATE_FLAG,
            @intCast(max_waiters),
            null,
            null,
        );
    }

    extern "c" fn futex(uaddr: *u32, op: c_int, val: c_int, timeout: ?*const std.os.linux.timespec, uaddr2: ?*u32) c_int;
};

// ============================================================================
// NetBSD implementation
// ============================================================================

const NetBSD = struct {
    const FUTEX_WAIT = 1;
    const FUTEX_WAKE = 2;
    const FUTEX_PRIVATE_FLAG = 128;

    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        const timeout_ts: ?std.os.linux.timespec = if (timeout_ns) |ns| .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        } else null;

        // NetBSD provides futex() for Linux compatibility
        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAIT | FUTEX_PRIVATE_FLAG,
            @intCast(expected),
            if (timeout_ts) |*ts| ts else null,
            null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;

        _ = futex(
            @constCast(&ptr.raw),
            FUTEX_WAKE | FUTEX_PRIVATE_FLAG,
            @intCast(max_waiters),
            null,
            null,
        );
    }

    extern "c" fn futex(uaddr: *u32, op: c_int, val: c_int, timeout: ?*const std.os.linux.timespec, uaddr2: ?*u32) c_int;
};

// ============================================================================
// DragonFly BSD implementation
// ============================================================================

const DragonFly = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
        // Note: umtx_sleep's comparison is NOT atomic with sleep, but is
        // "properly interlocked" with umtx_wakeup. This works correctly
        // with our counter + loop pattern in Waiter.
        _ = umtx_sleep(
            @constCast(&ptr.raw),
            @intCast(expected),
            @intCast(timeout_ns orelse 0),
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;

        _ = umtx_wakeup(
            @constCast(&ptr.raw),
            @intCast(max_waiters),
        );
    }

    extern "c" fn umtx_sleep(addr: *const u32, value: c_int, timeout: c_int) c_int;
    extern "c" fn umtx_wakeup(addr: *const u32, count: c_int) c_int;
};
