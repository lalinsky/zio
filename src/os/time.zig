const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const w = @import("windows.zig");
const time = @import("../time.zig");
const Duration = time.Duration;
const Clock = time.Clock;
const Timestamp = time.Timestamp;

pub const TimeInt = time.TimeInt;
pub const ns_per_s = time.ns_per_s;

const is_darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit => true,
    else => false,
};

/// Whether `now(.boot)` and `now(.awake)` resolve to different underlying
/// clocks. Derived from the same mapping `now()` uses, so it can't drift from
/// it: on Windows both clocks read QPC; elsewhere both go through `clock_gettime`
/// and differ only when `posixClockId` maps them to different ids — Linux
/// (BOOTTIME vs MONOTONIC) and Darwin (MONOTONIC_RAW vs UPTIME_RAW). When false
/// (the BSDs, etc.) the values are identical, so the loop keeps boot timers in
/// the awake heap: there is no suspend difference to observe, and they need
/// neither a separate heap nor the poll-timeout cap.
pub const boot_distinct_from_awake = switch (builtin.os.tag) {
    .windows => false,
    else => posixClockId(.boot) != posixClockId(.awake),
};

/// Map our logical clock to the OS clock id, or null if this platform's
/// `clockid_t` does not expose it (only the CPU-time clocks can be missing,
/// e.g. on SerenityOS).
///
/// `awake` excludes time the system is suspended, `boot` includes it. Only
/// Linux and Darwin expose distinct clocks for this; elsewhere both fall back
/// to `MONOTONIC` (suspend behavior is then platform-defined), which
/// `std.Io.Clock` explicitly permits.
fn posixClockId(clock: Clock) ?posix.system.clockid_t {
    const CLOCK = posix.system.CLOCK;
    return switch (clock) {
        .real => CLOCK.REALTIME,
        .awake => if (is_darwin) CLOCK.UPTIME_RAW else CLOCK.MONOTONIC,
        .boot => switch (builtin.os.tag) {
            .linux => CLOCK.BOOTTIME,
            else => if (is_darwin) CLOCK.MONOTONIC_RAW else CLOCK.MONOTONIC,
        },
        .cpu_process => if (@hasField(posix.system.clockid_t, "PROCESS_CPUTIME_ID")) .PROCESS_CPUTIME_ID else null,
        .cpu_thread => if (@hasField(posix.system.clockid_t, "THREAD_CPUTIME_ID")) .THREAD_CPUTIME_ID else null,
    };
}

pub fn now(clock: Clock) Timestamp {
    switch (builtin.os.tag) {
        .windows => {
            switch (clock) {
                .awake, .boot => {
                    // QPC on Windows doesn't fail on >= XP/2000 and includes time suspended.
                    const qpc = w.QueryPerformanceCounter();
                    const qpf = w.QueryPerformanceFrequency();

                    // Convert QPC ticks to nanoseconds
                    // Using fixed-point arithmetic to avoid overflow: (qpc * 1e9) / qpf
                    const common_qpf = 10_000_000; // 10MHz is common
                    if (qpf == common_qpf) {
                        // ns_per_s / 10_000_000 = 100
                        return Timestamp.fromNanoseconds(qpc * 100);
                    }

                    // General case: convert to ns using fixed point
                    const scale = (@as(u64, time.ns_per_s) << 32) / qpf;
                    const result = (@as(u96, qpc) * scale) >> 32;
                    return Timestamp.fromNanoseconds(@truncate(result));
                },
                .real => {
                    // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
                    // and uses the NTFS/Windows epoch, which is 1601-01-01.
                    // Convert to Unix epoch (1970-01-01) by subtracting the difference.
                    const ticks = w.RtlGetSystemTimePrecise();
                    // 100-nanosecond ticks between Windows epoch (1601) and Unix epoch (1970)
                    const epoch_diff_ticks = 11644473600 * (time.ns_per_s / 100);
                    return Timestamp.fromNanoseconds(@intCast((ticks - epoch_diff_ticks) * 100));
                },
                .cpu_process, .cpu_thread => return Timestamp.fromNanoseconds(windowsCpuTimeNs(clock) orelse 0),
            }
        },
        else => {
            // An unsupported CPU-time clock reports zero, matching the
            // `std.Io.Clock` contract.
            const clock_id = posixClockId(clock) orelse return .zero;
            // TODO: use our posix layer, not std.posix
            // https://codeberg.org/ziglang/zig/pulls/35506
            var tp: std.posix.system.timespec = undefined;
            const rc = std.posix.system.clock_gettime(clock_id, &tp);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    return .fromTimespec(tp);
                },
                .INVAL => {
                    // Some platforms advertise PROCESS_CPUTIME_ID / THREAD_CPUTIME_ID
                    // in clockid_t but don't support them at runtime.
                    if (clock == .cpu_process or clock == .cpu_thread) return .zero;
                    std.debug.panic("now: call to clock_gettime failed: INVAL", .{});
                },
                else => |err| {
                    std.debug.panic("now: call to clock_gettime failed: {}", .{err});
                },
            }
        },
    }
    unreachable;
}

/// Returns the granularity of the given clock, i.e. the smallest interval the
/// clock can distinguish. Null if the platform does not support the clock
/// (only the CPU-time clocks can be unsupported).
pub fn resolution(clock: Clock) ?Duration {
    switch (builtin.os.tag) {
        .windows => {
            switch (clock) {
                .awake, .boot => {
                    // QPC ticks at QueryPerformanceFrequency() Hz; one tick is
                    // the granularity. Clamp to at least 1ns for the unlikely
                    // case of a sub-nanosecond frequency.
                    const qpf = w.QueryPerformanceFrequency();
                    const ns = @max(time.ns_per_s / qpf, 1);
                    return Duration.fromNanoseconds(ns);
                },
                // RtlGetSystemTimePrecise(), and GetProcess/ThreadTimes, all
                // report in 100ns ticks; there is no API for the true (coarser)
                // scheduler granularity of the CPU-time clocks.
                .real, .cpu_process, .cpu_thread => return Duration.fromNanoseconds(100),
            }
        },
        else => {
            const clock_id = posixClockId(clock) orelse return null;
            // TODO: use our posix layer, not std.posix
            // https://codeberg.org/ziglang/zig/pulls/35506
            var tp: std.posix.system.timespec = undefined;
            const rc = std.posix.system.clock_getres(clock_id, &tp);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    return Duration.fromNanoseconds(timespecToNanos(tp));
                },
                .INVAL => {
                    // Some platforms advertise PROCESS_CPUTIME_ID / THREAD_CPUTIME_ID
                    // in clockid_t but don't support them at runtime.
                    if (clock == .cpu_process or clock == .cpu_thread) return null;
                    std.debug.panic("resolution: call to clock_getres failed: INVAL", .{});
                },
                else => |err| {
                    std.debug.panic("resolution: call to clock_getres failed: {}", .{err});
                },
            }
        },
    }
    unreachable;
}

fn timespecToNanos(tp: std.posix.system.timespec) u64 {
    return @as(u64, @intCast(@max(tp.sec, 0))) * time.ns_per_s +
        @as(u64, @intCast(@max(tp.nsec, 0)));
}

/// CPU time (user + kernel) consumed so far on the given CPU-time clock, in
/// nanoseconds. Null if the GetProcess/ThreadTimes call fails. Windows only.
fn windowsCpuTimeNs(clock: Clock) ?u64 {
    var creation: w.FILETIME = undefined;
    var exit: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    const ok = switch (clock) {
        .cpu_process => w.GetProcessTimes(w.GetCurrentProcess(), &creation, &exit, &kernel, &user),
        .cpu_thread => w.GetThreadTimes(w.GetCurrentThread(), &creation, &exit, &kernel, &user),
        else => unreachable,
    };
    if (ok == .FALSE) return null;
    // FILETIME counts 100-nanosecond ticks.
    const kernel_ticks = @as(u64, kernel.dwHighDateTime) << 32 | kernel.dwLowDateTime;
    const user_ticks = @as(u64, user.dwHighDateTime) << 32 | user.dwLowDateTime;
    return (kernel_ticks + user_ticks) * 100;
}

pub fn sleep(duration: Duration) void {
    if (duration.value == 0) return;
    switch (builtin.os.tag) {
        .windows => {
            _ = w.SleepEx(@intCast(duration.toMilliseconds()), w.FALSE);
        },
        else => {
            var req = duration.toTimespec();
            var rem: posix.system.timespec = undefined;

            // riscv32 doesn't have nanosleep, use clock_nanosleep instead
            if (builtin.cpu.arch == .riscv32) {
                while (true) {
                    const rc = posix.system.clock_nanosleep(
                        posix.system.CLOCK.MONOTONIC,
                        .{ .ABSTIME = false },
                        &req,
                        &rem,
                    );
                    switch (posix.errno(rc)) {
                        .SUCCESS => return,
                        .INTR => {
                            req = rem;
                            continue;
                        },
                        else => return,
                    }
                }
            } else {
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
