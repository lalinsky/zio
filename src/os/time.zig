const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w = @import("windows.zig");
const time = @import("../time.zig");
const Duration = time.Duration;
const Clock = time.Clock;
const Timestamp = time.Timestamp;

pub fn now(clock: Clock) Timestamp {
    switch (builtin.os.tag) {
        .windows => {
            switch (clock) {
                .monotonic => {
                    // QPC on Windows doesn't fail on >= XP/2000 and includes time suspended.
                    const qpc = w.QueryPerformanceCounter();
                    const qpf = w.QueryPerformanceFrequency();

                    // Convert QPC ticks to nanoseconds
                    // Using fixed-point arithmetic to avoid overflow: (qpc * 1e9) / qpf
                    const common_qpf = 10_000_000; // 10MHz is common
                    if (qpf == common_qpf) {
                        return .{ .ns = qpc * std.time.ns_per_s / common_qpf };
                    }

                    // General case: convert to ns using fixed point
                    const scale = (@as(u64, std.time.ns_per_s) << 32) / qpf;
                    const result = (@as(u96, qpc) * scale) >> 32;
                    return .{ .ns = @truncate(result) };
                },
                .realtime => {
                    // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
                    // and uses the NTFS/Windows epoch, which is 1601-01-01.
                    // Convert to Unix epoch (1970-01-01) by subtracting the difference.
                    const ticks = w.RtlGetSystemTimePrecise();
                    const ns_since_windows_epoch = ticks * 100;
                    // Nanoseconds between Windows epoch (1601) and Unix epoch (1970)
                    const epoch_diff_ns: i64 = 11644473600 * std.time.ns_per_s;
                    return .{ .ns = @intCast(ns_since_windows_epoch - epoch_diff_ns) };
                },
            }
        },
        else => {
            const clock_id = switch (clock) {
                .monotonic => posix.system.CLOCK.MONOTONIC,
                .realtime => posix.system.CLOCK.REALTIME,
            };
            var tp: posix.system.timespec = undefined;
            const rc = posix.system.clock_gettime(clock_id, &tp);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    return .fromTimespec(tp);
                },
                else => |err| {
                    std.debug.panic("now: call to clock_gettime failed: {}", .{err});
                },
            }
        },
    }
    unreachable;
}

pub fn sleep(duration: Duration) void {
    if (duration.ns == 0) return;
    switch (builtin.os.tag) {
        .windows => {
            _ = w.SleepEx(@intCast(duration.toMilliseconds()), w.FALSE);
        },
        else => {
            var req = duration.toTimespec();
            var rem: posix.system.timespec = undefined;
            while (true) {
                const rc = posix.system.nanosleep(&req, &rem);
                switch (posix.errno(rc)) {
                    .SUCCESS => return,
                    .INTR => {
                        req = rem;
                        continue;
                    },
                    else => return,
                }
            }
        },
    }
}
