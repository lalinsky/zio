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
                    var tp: std.os.windows.FILETIME = undefined;
                    const rc = std.os.windows.GetSystemTimePreciseAsFileTime(&tp);
                    if (rc != 0) {
                        std.debug.panic("now: call to GetSystemTimePreciseAsFileTime failed");
                    }
                    const ticks = tp.dwLowDateTime + (tp.dwHighDateTime << 32);
                    return ticks / 100;
                },
                .realtime => {
                    var tp: std.os.windows.FILETIME = undefined;
                    const rc = std.os.windows.GetSystemTimeAsFileTime(&tp);
                    if (rc != 0) {
                        std.debug.panic("now: call to GetSystemTimeAsFileTime failed");
                    }
                    const ticks = tp.dwLowDateTime + (tp.dwHighDateTime << 32);
                    return ticks / 100;
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
