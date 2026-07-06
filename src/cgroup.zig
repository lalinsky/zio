// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Linux cgroup CPU limit detection for auto-sizing the executor pool.
//!
//! Container CPU limits (Docker `--cpus`, Kubernetes `resources.limits.cpu`) are
//! enforced by the CFS bandwidth controller as a quota/period pair. That limit is
//! invisible to `sched_getaffinity()`, so sizing the pool purely from the CPU
//! count would spawn far more executors than the quota allows and get throttled
//! by the scheduler. This mirrors Go's container-aware GOMAXPROCS default: the
//! effective CPU count is `min(affinity, ceil(quota/period))`.
//!
//! Reads happen once, at runtime init, before the event loop is up. `zio.fs`
//! transparently takes its synchronous blocking path when there is no current
//! task, so we can reuse the normal file API here.

const std = @import("std");
const builtin = @import("builtin");

const fs = @import("fs.zig");

/// CPU limit imposed by the current cgroup's CFS bandwidth controller, rounded
/// up to a whole number of CPUs, or null when there is no limit (or not Linux).
///
/// Following Go's `adjustCgroupGOMAXPROCS`, a fractional quota is rounded up and
/// a limit below 2 is raised to 2 to avoid pathological behavior under a tight
/// quota. Callers still take the min with the affinity-based CPU count, so a
/// genuinely single-CPU affinity mask still wins.
pub fn cpuLimit() ?u32 {
    if (builtin.os.tag != .linux) return null;
    return roundRatio(quotaRatio() orelse return null);
}

/// Round a quota/period ratio up to a whole CPU count, with a floor of 2 (see
/// `cpuLimit`). Split out from `cpuLimit` so it can be tested without a cgroup.
fn roundRatio(ratio: f64) u32 {
    const rounded: u32 = @intFromFloat(@ceil(ratio));
    return @max(rounded, 2);
}

/// The raw quota/period ratio from the cgroup, or null if unlimited/unavailable.
fn quotaRatio() ?f64 {
    // cgroup v2 (unified hierarchy). Resolve the process's own cgroup path from
    // /proc/self/cgroup so we read the right cpu.max whether the limit lives at
    // the mount root (namespaced container) or in a leaf slice (systemd
    // CPUQuota=, or a container without a cgroup namespace).
    var path_buf: [512]u8 = undefined;
    if (v2CpuMaxPath(&path_buf)) |cpu_max_path| {
        var buf: [128]u8 = undefined;
        if (readFile(cpu_max_path, &buf)) |content| {
            // cpu.max holds "<quota> <period>", with <quota> being the literal
            // "max" when there is no limit.
            return parseV2(content);
        }
    }

    // cgroup v1: separate quota and period files under the cpu controller. We use
    // the fixed well-known path, which covers namespaced v1 containers.
    // cpu.cfs_quota_us is -1 when there is no limit.
    var quota_buf: [32]u8 = undefined;
    const quota_str = readFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", &quota_buf) orelse return null;
    const quota = std.fmt.parseInt(i64, std.mem.trim(u8, quota_str, " \n"), 10) catch return null;
    if (quota < 0) return null;

    var period_buf: [32]u8 = undefined;
    const period_str = readFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us", &period_buf) orelse return null;
    const period = std.fmt.parseInt(i64, std.mem.trim(u8, period_str, " \n"), 10) catch return null;
    if (period <= 0) return null;

    return @as(f64, @floatFromInt(quota)) / @as(f64, @floatFromInt(period));
}

/// Build the path to the current process's cgroup v2 cpu.max file into `out`, or
/// null if the process is not on a unified (v2) hierarchy. The v2 line in
/// /proc/self/cgroup has the form "0::<path>"; the file lives at
/// /sys/fs/cgroup<path>/cpu.max.
fn v2CpuMaxPath(out: []u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    const content = readFile("/proc/self/cgroup", &buf) orelse return null;
    return buildV2Path(content, out);
}

/// Parse /proc/self/cgroup `content` and build the v2 cpu.max path into `out`.
fn buildV2Path(content: []const u8, out: []u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const rel = line["0::".len..];
        return std.fmt.bufPrint(out, "/sys/fs/cgroup{s}/cpu.max", .{rel}) catch return null;
    }
    return null;
}

fn parseV2(content: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    const quota_str = it.next() orelse return null;
    if (std.mem.eql(u8, quota_str, "max")) return null;
    const period_str = it.next() orelse return null;

    const quota = std.fmt.parseInt(i64, quota_str, 10) catch return null;
    const period = std.fmt.parseInt(i64, period_str, 10) catch return null;
    if (quota < 0 or period <= 0) return null;

    return @as(f64, @floatFromInt(quota)) / @as(f64, @floatFromInt(period));
}

/// Read a small pseudo-file into `buf`, returning the bytes read, or null on any
/// error (missing controller, permission, etc.) so detection degrades to the
/// affinity-only path. Uses `zio.fs`, which runs synchronously here because
/// there is no current task during runtime init.
fn readFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = fs.openFile(path) catch return null;
    defer file.close();
    const n = file.read(buf, 0) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

test "parseV2: explicit limit" {
    try std.testing.expectEqual(@as(?f64, 2.0), parseV2("200000 100000\n"));
    try std.testing.expectEqual(@as(?f64, 1.5), parseV2("150000 100000"));
}

test "parseV2: unlimited" {
    try std.testing.expectEqual(@as(?f64, null), parseV2("max 100000\n"));
}

test "parseV2: malformed" {
    try std.testing.expectEqual(@as(?f64, null), parseV2(""));
    try std.testing.expectEqual(@as(?f64, null), parseV2("200000"));
    try std.testing.expectEqual(@as(?f64, null), parseV2("abc 100000"));
    try std.testing.expectEqual(@as(?f64, null), parseV2("200000 0"));
}

test "buildV2Path: root and leaf" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/sys/fs/cgroup//cpu.max", buildV2Path("0::/\n", &out).?);
    try std.testing.expectEqualStrings(
        "/sys/fs/cgroup/app.slice/my.service/cpu.max",
        buildV2Path("0::/app.slice/my.service\n", &out).?,
    );
    // Hybrid layout: v1 controller lines precede the unified "0::" line.
    try std.testing.expectEqualStrings(
        "/sys/fs/cgroup/foo/cpu.max",
        buildV2Path("3:cpu,cpuacct:/foo\n0::/foo\n", &out).?,
    );
}

test "buildV2Path: no unified hierarchy" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildV2Path("3:cpu,cpuacct:/foo\n", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), buildV2Path("", &out));
}

test "roundRatio: ceil with floor of 2" {
    try std.testing.expectEqual(2, roundRatio(0.5));
    try std.testing.expectEqual(2, roundRatio(1.0));
    try std.testing.expectEqual(2, roundRatio(1.5));
    try std.testing.expectEqual(2, roundRatio(2.0));
    try std.testing.expectEqual(3, roundRatio(2.1));
    try std.testing.expectEqual(4, roundRatio(4.0));
}
