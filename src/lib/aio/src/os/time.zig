const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");

pub const Clock = enum {
    monotonic,
    realtime,
};

pub fn now(clock: Clock) u64 {
    switch (builtin.os.tag) {
        .windows => {
            switch (clock) {
                .monotonic => {
                    // QPC on Windows doesn't fail on >= XP/2000 and includes time suspended.
                    const qpc = std.os.windows.QueryPerformanceCounter();
                    const qpf = std.os.windows.QueryPerformanceFrequency();

                    // Convert QPC ticks to milliseconds
                    // Using fixed-point arithmetic to avoid overflow: (qpc * 1000) / qpf
                    const common_qpf = 10_000_000; // 10MHz is common
                    if (qpf == common_qpf) {
                        return qpc * std.time.ms_per_s / common_qpf;
                    }

                    // General case: convert to ms using fixed point
                    const scale = (@as(u64, std.time.ms_per_s) << 32) / qpf;
                    const result = (@as(u96, qpc) * scale) >> 32;
                    return @truncate(result);
                },
                .realtime => {
                    // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
                    // and uses the NTFS/Windows epoch, which is 1601-01-01.
                    // Convert to Unix epoch (1970-01-01) by subtracting the difference.
                    const ticks = std.os.windows.ntdll.RtlGetSystemTimePrecise();
                    const ms_since_windows_epoch = @divFloor(ticks, std.time.ns_per_ms / 100);
                    // Seconds between Windows epoch (1601) and Unix epoch (1970)
                    const epoch_diff_ms: i64 = 11644473600 * std.time.ms_per_s;
                    return @intCast(ms_since_windows_epoch - epoch_diff_ms);
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
                    const ts = @as(i64, @intCast(tp.sec)) * std.time.ms_per_s + @divFloor(@as(i64, @intCast(tp.nsec)), std.time.ns_per_ms);
                    return @intCast(@max(ts, 0));
                },
                else => |err| {
                    std.debug.panic("now: call to clock_gettime failed: {}", .{err});
                },
            }
        },
    }
    unreachable;
}

pub fn sleep(timeout_ms: i32) void {
    switch (builtin.os.tag) {
        .windows => {
            if (timeout_ms > 0) {
                if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
                    std.os.windows.kernel32.Sleep(@intCast(timeout_ms));
                } else {
                    _ = std.os.windows.kernel32.SleepEx(@intCast(timeout_ms), std.os.windows.FALSE);
                }
            }
        },
        else => {
            if (timeout_ms > 0) {
                var req = posix.system.timespec{
                    .sec = @intCast(@divFloor(timeout_ms, std.time.ms_per_s)),
                    .nsec = @intCast(@mod(timeout_ms, std.time.ms_per_s) * std.time.ns_per_ms),
                };
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
            }
        },
    }
}
