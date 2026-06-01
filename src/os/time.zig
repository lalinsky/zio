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
                        // ns_per_s / 10_000_000 = 100
                        return Timestamp.fromNanoseconds(qpc * 100);
                    }

                    // General case: convert to ns using fixed point
                    const scale = (@as(u64, time.ns_per_s) << 32) / qpf;
                    const result = (@as(u96, qpc) * scale) >> 32;
                    return Timestamp.fromNanoseconds(@truncate(result));
                },
                .realtime => {
                    // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
                    // and uses the NTFS/Windows epoch, which is 1601-01-01.
                    // Convert to Unix epoch (1970-01-01) by subtracting the difference.
                    const ticks = w.RtlGetSystemTimePrecise();
                    // 100-nanosecond ticks between Windows epoch (1601) and Unix epoch (1970)
                    const epoch_diff_ticks = 11644473600 * (time.ns_per_s / 100);
                    return Timestamp.fromNanoseconds(@intCast((ticks - epoch_diff_ticks) * 100));
                },
            }
        },
        else => {
            const clock_id = switch (clock) {
                .monotonic => posix.system.CLOCK.MONOTONIC,
                .realtime => posix.system.CLOCK.REALTIME,
            };
            // std.posix.system.clock_gettime serves the read from the
            // kernel vDSO (userspace, no syscall) — but only once
            // std.os.linux.elf_aux_maybe points at the ELF aux vector.
            // Zig sets that from its own _start; when the program links
            // libc (zio does), glibc owns _start and leaves it null, so
            // every read falls back to a real clock_gettime syscall.
            // now() is the event loop's hottest call, so recover the aux
            // vector ourselves (pure syscalls, no libc) on first use.
            if (builtin.os.tag == .linux) ensureVdsoAux();
            // TODO: use our posix layer, not std.posix
            // https://codeberg.org/ziglang/zig/pulls/35506
            var tp: std.posix.system.timespec = undefined;
            const rc = std.posix.system.clock_gettime(clock_id, &tp);
            switch (std.posix.errno(rc)) {
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

// Recovering the ELF aux vector lets std.posix.system.clock_gettime
// (= std.os.linux.clock_gettime) resolve the kernel vDSO. Zig sets
// std.os.linux.elf_aux_maybe from its own _start; when the program
// links libc (zio does, see build.zig), glibc owns _start and leaves it
// null, so the vDSO lookup fails and clock_gettime falls back to a real
// syscall on every read. now() recovers it from /proc/self/auxv (pure
// syscalls, no libc, no reliance on Zig owning _start) on first use.
const aux_unstarted: u8 = 0;
const aux_filling: u8 = 1;
const aux_done: u8 = 2;
var aux_state = std.atomic.Value(u8).init(aux_unstarted);
// Backing store for the aux vector handed to elf_aux_maybe; must outlive
// the call, so module-static. 1 KiB holds far more Auxv entries than any
// kernel emits (~20 × 16 B).
var aux_buf: [1024]u8 align(@alignOf(std.elf.Auxv)) = undefined;

/// Idempotent and thread-safe. The winner fills aux_buf and publishes
/// `aux_done` with release; every other caller acquires `aux_done`
/// before returning, so the buffer and elf_aux_maybe are visible before
/// clock_gettime can run its one-time vDSO lookup (which reads
/// elf_aux_maybe with a plain load). Best effort: if /proc is
/// unavailable the pointer stays null and clock_gettime keeps using the
/// syscall (correct, just slower).
fn ensureVdsoAux() void {
    if (aux_state.load(.acquire) == aux_done) return;
    if (aux_state.cmpxchgStrong(aux_unstarted, aux_filling, .acq_rel, .monotonic) != null) {
        while (aux_state.load(.acquire) != aux_done) std.atomic.spinLoopHint();
        return;
    }
    fillAuxFromProc();
    aux_state.store(aux_done, .release);
}

fn fillAuxFromProc() void {
    const fd_us = std.os.linux.open("/proc/self/auxv", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_us)) < 0) return;
    const fd: i32 = @intCast(fd_us);
    defer _ = std.os.linux.close(fd);
    var off: usize = 0;
    while (off < aux_buf.len) {
        const r = std.os.linux.read(fd, aux_buf[off..].ptr, aux_buf.len - off);
        const sr: isize = @bitCast(r);
        if (sr <= 0) break;
        off += @intCast(r);
    }
    if (off < @sizeOf(std.elf.Auxv)) return;
    std.os.linux.elf_aux_maybe = @ptrCast(@alignCast(&aux_buf));
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
