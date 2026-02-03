// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// Parts of the file are based on https://github.com/golang/go/blob/master/src/time/format.go
//
// Copyright 2010 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

const std = @import("std");
const os = @import("os/root.zig");
const ev = @import("ev/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const getCurrentExecutor = @import("runtime.zig").getCurrentExecutor;
const WaitNode = @import("runtime/WaitNode.zig");

// Time configuration - adjust these for different platforms
const TimePrecision = enum { nanoseconds, microseconds, milliseconds };
const time_unit: TimePrecision = .nanoseconds;
pub const TimeInt = u64;

pub const ns_per_us = 1000;
pub const ns_per_ms = 1000 * 1000;
pub const ns_per_s = 1000 * 1000 * 1000;
pub const ns_per_min = 60 * ns_per_s;
pub const ns_per_hour = 60 * ns_per_min;
pub const s_per_min = 60;
pub const s_per_hour = 60 * s_per_min;
pub const s_per_day = 24 * s_per_hour;

// How many nanoseconds per unit (the reciprocal would be fractional for some precisions)
const ns_per_unit: TimeInt = switch (time_unit) {
    .nanoseconds => 1,
    .microseconds => ns_per_us,
    .milliseconds => ns_per_ms,
};

pub const Clock = enum {
    monotonic,
    realtime,
};

/// A duration of time.
pub const Duration = struct {
    value: TimeInt,

    pub const zero: Duration = .{ .value = 0 };
    pub const max: Duration = .{ .value = std.math.maxInt(TimeInt) };

    pub fn fromNanoseconds(ns: TimeInt) Duration {
        return .{ .value = ns / ns_per_unit };
    }

    pub fn fromMicroseconds(us: TimeInt) Duration {
        if (ns_per_us >= ns_per_unit) {
            return .{ .value = us *| (ns_per_us / ns_per_unit) };
        } else {
            return .{ .value = us / (ns_per_unit / ns_per_us) };
        }
    }

    pub fn fromMilliseconds(ms: TimeInt) Duration {
        if (ns_per_ms >= ns_per_unit) {
            return .{ .value = ms *| (ns_per_ms / ns_per_unit) };
        } else {
            return .{ .value = ms / (ns_per_unit / ns_per_ms) };
        }
    }

    pub fn fromSeconds(s: TimeInt) Duration {
        return .{ .value = s *| (ns_per_s / ns_per_unit) };
    }

    pub fn fromMinutes(m: TimeInt) Duration {
        return .{ .value = m *| (ns_per_min / ns_per_unit) };
    }

    pub fn toNanoseconds(self: Duration) TimeInt {
        return self.value *| ns_per_unit;
    }

    pub fn toMicroseconds(self: Duration) TimeInt {
        if (ns_per_us >= ns_per_unit) {
            return self.value / (ns_per_us / ns_per_unit);
        } else {
            return self.value *| (ns_per_unit / ns_per_us);
        }
    }

    pub fn toMilliseconds(self: Duration) TimeInt {
        if (ns_per_ms >= ns_per_unit) {
            return self.value / (ns_per_ms / ns_per_unit);
        } else {
            return self.value *| (ns_per_unit / ns_per_ms);
        }
    }

    pub fn toSeconds(self: Duration) TimeInt {
        if (ns_per_s >= ns_per_unit) {
            return self.value / (ns_per_s / ns_per_unit);
        } else {
            return self.value *| (ns_per_unit / ns_per_s);
        }
    }

    pub fn toMinutes(self: Duration) TimeInt {
        if (ns_per_min >= ns_per_unit) {
            return self.value / (ns_per_min / ns_per_unit);
        } else {
            return self.value *| (ns_per_unit / ns_per_min);
        }
    }

    pub fn toTimespec(self: Duration) os.timespec {
        const ns = self.toNanoseconds();
        return .{
            .sec = @intCast(ns / ns_per_s),
            .nsec = @intCast(ns % ns_per_s),
        };
    }

    /// Formats the duration in Go-style format (e.g., "1h30m45s", "500ms", "1.5us").
    pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const start = formatBuf(self.toNanoseconds(), &buf);
        try w.writeAll(buf[start..]);
    }

    /// Formats duration into buffer from the end, returns start index.
    fn formatBuf(ns: u64, buf: *[32]u8) usize {
        var u = ns;
        var i: usize = buf.len;

        if (u < ns_per_s) {
            // Sub-second: use smaller units like "1.2ms"
            var prec: usize = undefined;
            i -= 1;
            buf[i] = 's';
            if (u == 0) {
                i -= 1;
                buf[i] = '0';
                return i;
            } else if (u < ns_per_us) {
                // nanoseconds
                prec = 0;
                i -= 1;
                buf[i] = 'n';
            } else if (u < ns_per_ms) {
                // microseconds
                prec = 3;
                i -= 1;
                buf[i] = 'u';
            } else {
                // milliseconds
                prec = 6;
                i -= 1;
                buf[i] = 'm';
            }
            i, u = fmtFrac(buf[0..i], u, prec);
            i = fmtInt(buf[0..i], u);
        } else {
            i -= 1;
            buf[i] = 's';

            i, u = fmtFrac(buf[0..i], u, 9);

            // u is now integer seconds
            i = fmtInt(buf[0..i], u % 60);
            u /= 60;

            // u is now integer minutes
            if (u > 0) {
                i -= 1;
                buf[i] = 'm';
                i = fmtInt(buf[0..i], u % 60);
                u /= 60;

                // u is now integer hours
                if (u > 0) {
                    i -= 1;
                    buf[i] = 'h';
                    i = fmtInt(buf[0..i], u);
                }
            }
        }

        return i;
    }

    /// Formats v/10^prec as decimal fraction into end of buf, omitting trailing zeros.
    /// Returns (new_index, v/10^prec).
    fn fmtFrac(buf: []u8, v: u64, prec: usize) struct { usize, u64 } {
        var w = buf.len;
        var u = v;
        var print = false;
        for (0..prec) |_| {
            const digit: u8 = @intCast(u % 10);
            print = print or digit != 0;
            if (print) {
                w -= 1;
                buf[w] = digit + '0';
            }
            u /= 10;
        }
        if (print) {
            w -= 1;
            buf[w] = '.';
        }
        return .{ w, u };
    }

    /// Formats integer v into end of buf. Returns new start index.
    fn fmtInt(buf: []u8, v: u64) usize {
        var w = buf.len;
        var u = v;
        if (u == 0) {
            w -= 1;
            buf[w] = '0';
        } else {
            while (u > 0) {
                w -= 1;
                buf[w] = @as(u8, @intCast(u % 10)) + '0';
                u /= 10;
            }
        }
        return w;
    }

    pub const ParseError = error{InvalidDuration};

    /// Parses a duration string in Go-style format (e.g., "1h30m45s", "500ms", "1.5us").
    pub fn parse(s: []const u8) ParseError!Duration {
        if (s.len == 0) return error.InvalidDuration;

        const max_val = std.math.maxInt(u64);
        var ns: u64 = 0;
        var i: usize = 0;

        while (i < s.len) {
            // Parse integer part
            const int_start = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
            if (i == int_start) return error.InvalidDuration;

            var int_part: u64 = 0;
            for (s[int_start..i]) |c| {
                if (int_part > max_val / 10) return error.InvalidDuration;
                int_part *= 10;
                const digit: u64 = c - '0';
                if (int_part > max_val - digit) return error.InvalidDuration;
                int_part += digit;
            }

            // Parse optional fractional part using float64 (like Go does for precision)
            var frac: f64 = 0;
            var frac_scale: f64 = 1;
            if (i < s.len and s[i] == '.') {
                i += 1;
                const frac_start = i;
                while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
                if (i == frac_start) return error.InvalidDuration;

                // Parse fraction digits, stopping accumulation on overflow (like Go's leadingFraction)
                for (s[frac_start..i]) |c| {
                    if (frac < @as(f64, @floatFromInt(max_val / 10))) {
                        frac = frac * 10 + @as(f64, @floatFromInt(c - '0'));
                        frac_scale *= 10;
                    }
                }
            }

            // Parse unit
            if (i >= s.len) return error.InvalidDuration;
            const unit_start = i;
            while (i < s.len and s[i] >= 'a' and s[i] <= 'z') : (i += 1) {}
            const unit = s[unit_start..i];

            const multiplier: u64 = if (std.mem.eql(u8, unit, "ns"))
                1
            else if (std.mem.eql(u8, unit, "us"))
                ns_per_us
            else if (std.mem.eql(u8, unit, "ms"))
                ns_per_ms
            else if (std.mem.eql(u8, unit, "s"))
                ns_per_s
            else if (std.mem.eql(u8, unit, "m"))
                ns_per_min
            else if (std.mem.eql(u8, unit, "h"))
                ns_per_hour
            else
                return error.InvalidDuration;

            // Check for overflow before multiplying
            if (int_part > max_val / multiplier) return error.InvalidDuration;
            var v = int_part * multiplier;

            // Add fractional part (float64 handles the precision, like Go)
            if (frac > 0) {
                v +|= @intFromFloat(frac * (@as(f64, @floatFromInt(multiplier)) / frac_scale));
            }

            // Check for overflow before adding to total
            if (ns > max_val - v) return error.InvalidDuration;
            ns += v;
        }

        return fromNanoseconds(ns);
    }
};

/// A point in time since Unix epoch.
pub const Timestamp = struct {
    value: TimeInt,

    pub const zero: Timestamp = .{ .value = 0 };

    pub fn now(comptime clock: Clock) Timestamp {
        return os.time.now(clock);
    }

    pub fn fromNanoseconds(ns: TimeInt) Timestamp {
        return .{ .value = ns / ns_per_unit };
    }

    pub fn fromMilliseconds(ms: TimeInt) Timestamp {
        return .{ .value = ms *| (ns_per_ms / ns_per_unit) };
    }

    pub fn toNanoseconds(self: Timestamp) TimeInt {
        return self.value *| ns_per_unit;
    }

    pub fn fromTimespec(ts: os.timespec) Timestamp {
        const ns = @as(i64, @intCast(ts.sec)) * ns_per_s + @as(i64, @intCast(ts.nsec));
        return fromNanoseconds(@intCast(@max(ns, 0)));
    }

    pub fn toTimespec(self: Timestamp) os.timespec {
        const ns = self.toNanoseconds();
        return .{
            .sec = @intCast(ns / ns_per_s),
            .nsec = @intCast(ns % ns_per_s),
        };
    }

    pub fn durationTo(from: Timestamp, to: Timestamp) Duration {
        return .{ .value = to.value -| from.value };
    }

    pub fn addDuration(self: Timestamp, duration: Duration) Timestamp {
        return .{ .value = self.value +| duration.value };
    }

    pub fn subDuration(self: Timestamp, duration: Duration) Timestamp {
        return .{ .value = self.value -| duration.value };
    }

    /// Formats the timestamp as "YYYY-MM-DD HH:MM:SS".
    pub fn format(self: Timestamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const secs = self.toNanoseconds() / ns_per_s;

        // Days since Unix epoch
        var days = secs / s_per_day;
        const day_secs = secs % s_per_day;

        // Time of day
        const hour = day_secs / s_per_hour;
        const minute = (day_secs % s_per_hour) / s_per_min;
        const second = day_secs % s_per_min;

        // Convert days to year/month/day
        // Algorithm from http://howardhinnant.github.io/date_algorithms.html
        days += 719468; // days from 0000-03-01 to 1970-01-01
        const era = days / 146097;
        const doe = days - era * 146097; // day of era [0, 146096]
        const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
        const mp = (5 * doy + 2) / 153; // month index [0, 11]
        const d = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
        const m = if (mp < 10) mp + 3 else mp - 9; // month [1, 12]
        const year = if (m <= 2) y + 1 else y;

        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year, m, d, hour, minute, second,
        });
    }
};

pub const Timeout = union(enum) {
    none,
    duration: Duration,
    deadline: Timestamp,

    /// Creates a timeout from a duration in nanoseconds.
    pub fn fromNanoseconds(ns: u64) Timeout {
        return .{ .duration = .fromNanoseconds(ns) };
    }

    /// Creates a timeout from a duration in microseconds.
    pub fn fromMicroseconds(us: u64) Timeout {
        return .{ .duration = .fromMicroseconds(us) };
    }

    /// Creates a timeout from a duration in milliseconds.
    pub fn fromMilliseconds(ms: u64) Timeout {
        return .{ .duration = .fromMilliseconds(ms) };
    }

    /// Creates a timeout from a duration in seconds.
    pub fn fromSeconds(s: u64) Timeout {
        return .{ .duration = .fromSeconds(s) };
    }

    /// Creates a timeout from a duration in minutes.
    pub fn fromMinutes(m: u64) Timeout {
        return .{ .duration = .fromMinutes(m) };
    }

    /// Converts this timeout to a deadline-based timeout.
    /// If already a deadline or none, returns self unchanged.
    /// If a duration, converts to deadline using the current monotonic time.
    pub fn toDeadline(self: Timeout) Timeout {
        return switch (self) {
            .none, .deadline => self,
            .duration => |d| .{ .deadline = os.time.now(.monotonic).addDuration(d) },
        };
    }

    pub fn durationFromNow(self: Timeout) Duration {
        return switch (self) {
            .none => .max,
            .duration => |d| d,
            .deadline => |ts| Timestamp.now(.monotonic).durationTo(ts),
        };
    }

    /// Formats the timeout for display.
    pub fn format(self: Timeout, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .none => try w.writeAll("none"),
            .duration => |d| try d.format(w),
            .deadline => |ts| {
                try w.writeAll("deadline:");
                try ts.format(w);
            },
        }
    }

    // Future protocol implementation for use with select()

    pub const Result = void;

    pub const WaitContext = struct {
        timer: ev.Timer = ev.Timer.init(.{ .duration = .zero }),
        wait_node: ?*WaitNode = null,
    };

    pub fn asyncWait(self: *const Timeout, wait_node: *WaitNode, ctx: *WaitContext) bool {
        // Timeout.none means wait forever - never completes
        if (self.* == .none) {
            return true;
        }

        ctx.timer = ev.Timer.init(self.*);
        ctx.wait_node = wait_node;
        ctx.timer.c.userdata = ctx;
        ctx.timer.c.callback = timerCallback;

        const executor = getCurrentExecutor();
        executor.loop.add(&ctx.timer.c);
        return true;
    }

    fn timerCallback(_: *ev.Loop, c: *ev.Completion) void {
        const ctx: *WaitContext = @ptrCast(@alignCast(c.userdata.?));
        if (ctx.wait_node) |node| {
            node.wake();
        }
    }

    pub fn asyncCancelWait(self: *const Timeout, wait_node: *WaitNode, ctx: *WaitContext) bool {
        _ = self;
        _ = wait_node;
        const loop = ctx.timer.c.loop orelse return true;
        ctx.wait_node = null; // Prevent callback from waking a stale/reused wait node
        loop.clearTimer(&ctx.timer);
        return true; // Timer operations don't have values to re-add if we lost the race
    }

    pub fn getResult(self: *const Timeout, ctx: *WaitContext) void {
        _ = self;
        _ = ctx;
    }
};

/// A monotonic, high performance stopwatch for measuring elapsed time.
///
/// Monotonicity is ensured by saturating on the most previous sample.
/// This means that while timings reported are monotonic,
/// they're not guaranteed to tick at a steady rate as this is up to the underlying system.
pub const Stopwatch = struct {
    started: Timestamp,
    previous: Timestamp,

    /// Initialize the stopwatch by sampling the monotonic clock.
    pub fn start() Stopwatch {
        const current = os.time.now(.monotonic);
        return .{ .started = current, .previous = current };
    }

    /// Reads the elapsed time since start or the last reset.
    pub fn read(self: *Stopwatch) Duration {
        const current = self.sample();
        return self.started.durationTo(current);
    }

    /// Resets the stopwatch to 0/now.
    pub fn reset(self: *Stopwatch) void {
        const current = self.sample();
        self.started = current;
    }

    /// Returns the elapsed time since start or the last reset, then resets the stopwatch.
    pub fn lap(self: *Stopwatch) Duration {
        const current = self.sample();
        defer self.started = current;
        return self.started.durationTo(current);
    }

    /// Samples the monotonic clock, ensuring monotonicity by saturating on the previous sample.
    fn sample(self: *Stopwatch) Timestamp {
        const current = os.time.now(.monotonic);
        if (current.value > self.previous.value) {
            self.previous = current;
        }
        return self.previous;
    }
};

test "Timestamp: addDuration, subDuration, durationTo" {
    const t1 = Timestamp.fromNanoseconds(1_000_000_000);
    const t2 = t1.addDuration(.fromSeconds(5));
    try std.testing.expectEqual(6_000_000_000, t2.toNanoseconds());

    const t3 = t2.subDuration(.fromSeconds(2));
    try std.testing.expectEqual(4_000_000_000, t3.toNanoseconds());

    const dur = t1.durationTo(t2);
    try std.testing.expectEqual(5_000_000_000, dur.toNanoseconds());
}

test "Timestamp: format" {
    var buf: [64]u8 = undefined;

    // Unix epoch
    const epoch = Timestamp.fromNanoseconds(0);
    var result = std.fmt.bufPrint(&buf, "{f}", .{epoch}) catch unreachable;
    try std.testing.expectEqualStrings("1970-01-01 00:00:00", result);

    // 2024-01-15 12:40:45 UTC
    const t = Timestamp.fromNanoseconds(1705322445 * ns_per_s);
    result = std.fmt.bufPrint(&buf, "{f}", .{t}) catch unreachable;
    try std.testing.expectEqualStrings("2024-01-15 12:40:45", result);
}

test "Duration: format" {
    var buf: [64]u8 = undefined;

    const cases = [_]struct { ns: u64, expected: []const u8 }{
        .{ .ns = 0, .expected = "0s" },
        .{ .ns = 1, .expected = "1ns" },
        .{ .ns = 500, .expected = "500ns" },
        .{ .ns = 1_500, .expected = "1.5us" },
        .{ .ns = 1_000, .expected = "1us" },
        .{ .ns = 1_500_000, .expected = "1.5ms" },
        .{ .ns = 1_000_000, .expected = "1ms" },
        .{ .ns = 1_000_000_000, .expected = "1s" },
        .{ .ns = 1_500_000_000, .expected = "1.5s" },
        .{ .ns = 60_000_000_000, .expected = "1m0s" },
        .{ .ns = 90_000_000_000, .expected = "1m30s" },
        .{ .ns = 3_600_000_000_000, .expected = "1h0m0s" },
        .{ .ns = 3_661_000_000_000, .expected = "1h1m1s" },
        .{ .ns = 5_025_000_000_000, .expected = "1h23m45s" },
        .{ .ns = 5_025_123_456_789, .expected = "1h23m45.123456789s" },
    };

    for (cases) |case| {
        // Skip tests where precision would be lost
        if (case.ns % ns_per_unit != 0) continue;

        const d = Duration.fromNanoseconds(case.ns);
        const result = std.fmt.bufPrint(&buf, "{f}", .{d}) catch unreachable;
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

test "Duration: parse" {
    const cases = [_]struct { input: []const u8, expected: u64 }{
        .{ .input = "0s", .expected = 0 },
        .{ .input = "1ns", .expected = 1 },
        .{ .input = "500ns", .expected = 500 },
        .{ .input = "1us", .expected = 1_000 },
        .{ .input = "1.5us", .expected = 1_500 },
        .{ .input = "1ms", .expected = 1_000_000 },
        .{ .input = "1.5ms", .expected = 1_500_000 },
        .{ .input = "1s", .expected = 1_000_000_000 },
        .{ .input = "1.5s", .expected = 1_500_000_000 },
        .{ .input = "1m0s", .expected = 60_000_000_000 },
        .{ .input = "1m30s", .expected = 90_000_000_000 },
        .{ .input = "1h0m0s", .expected = 3_600_000_000_000 },
        .{ .input = "1h1m1s", .expected = 3_661_000_000_000 },
        .{ .input = "1h23m45s", .expected = 5_025_000_000_000 },
        .{ .input = "1h23m45.123456789s", .expected = 5_025_123_456_789 },
        // Additional cases
        .{ .input = "100ms", .expected = 100_000_000 },
        .{ .input = "2h", .expected = 7_200_000_000_000 },
        .{ .input = "30m", .expected = 1_800_000_000_000 },
    };

    for (cases) |case| {
        // Skip tests where precision would be lost
        if (case.expected % ns_per_unit != 0) continue;

        const d = try Duration.parse(case.input);
        try std.testing.expectEqual(case.expected, d.toNanoseconds());
    }

    // Error cases
    try std.testing.expectError(error.InvalidDuration, Duration.parse(""));
    try std.testing.expectError(error.InvalidDuration, Duration.parse("abc"));
    try std.testing.expectError(error.InvalidDuration, Duration.parse("1"));
    try std.testing.expectError(error.InvalidDuration, Duration.parse("1."));
    try std.testing.expectError(error.InvalidDuration, Duration.parse("1x"));

    // Integer part overflow: number too large for u64
    try std.testing.expectError(error.InvalidDuration, Duration.parse("99999999999999999999999999999s"));

    // Overflow when multiplying by unit multiplier
    try std.testing.expectError(error.InvalidDuration, Duration.parse("18446744073709551616ns")); // u64_max + 1
    try std.testing.expectError(error.InvalidDuration, Duration.parse("18446744073709552us")); // overflow when * 1000
    try std.testing.expectError(error.InvalidDuration, Duration.parse("18446744073710ms")); // overflow when * 1_000_000
    try std.testing.expectError(error.InvalidDuration, Duration.parse("18446744074s")); // overflow when * 1_000_000_000
    try std.testing.expectError(error.InvalidDuration, Duration.parse("307445735m")); // overflow when * 60_000_000_000
    try std.testing.expectError(error.InvalidDuration, Duration.parse("5124096h")); // overflow when * 3_600_000_000_000

    // Accumulation overflow: multiple units that sum over u64
    try std.testing.expectError(error.InvalidDuration, Duration.parse("5124095h1h"));

    // Valid edge case: max u64 in nanoseconds (only if precision supports it)
    if (ns_per_unit == 1) {
        try std.testing.expectEqual(std.math.maxInt(u64), (try Duration.parse("18446744073709551615ns")).toNanoseconds());
    }
}

test "Duration: overflow saturation" {
    // Values that would overflow if multiplied normally should saturate to Duration.max
    const max_u64 = std.math.maxInt(u64);

    // fromMicroseconds: only overflows when converting to smaller unit (ns)
    if (ns_per_us > ns_per_unit) {
        try std.testing.expectEqual(Duration.max, Duration.fromMicroseconds(max_u64));
    }

    // fromMilliseconds: only overflows when converting to smaller unit (ns or us)
    if (ns_per_ms > ns_per_unit) {
        try std.testing.expectEqual(Duration.max, Duration.fromMilliseconds(max_u64));
    }

    // fromSeconds: always overflows since seconds > all precisions
    try std.testing.expectEqual(Duration.max, Duration.fromSeconds(max_u64));

    // fromMinutes: always overflows since minutes > all precisions
    try std.testing.expectEqual(Duration.max, Duration.fromMinutes(max_u64));

    // Verify non-overflowing values still work correctly
    try std.testing.expectEqual(1_000_000_000, Duration.fromSeconds(1).toNanoseconds());
    try std.testing.expectEqual(60_000_000_000, Duration.fromMinutes(1).toNanoseconds());
}

test "Stopwatch: start, read, lap, reset" {
    var timer = Stopwatch.start();
    _ = timer.read();
    _ = timer.lap();
    timer.reset();
    _ = timer.read();
}

test "Timeout future: timeout wins select" {
    const Channel = @import("sync/channel.zig").Channel;
    const Group = @import("runtime/group.zig").Group;
    const select = @import("select.zig").select;

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    var channel = Channel(u32).init(&.{});

    const TestFn = struct {
        fn run(rt: *Runtime, ch: *Channel(u32)) !void {
            _ = rt;
            const result = try select(.{
                .recv = ch.asyncReceive(),
                .timeout = Timeout.fromMilliseconds(10),
            });
            switch (result) {
                .recv => try std.testing.expect(false),
                .timeout => {},
            }
        }
    };

    var group: Group = .init;
    defer group.cancel();
    try group.spawn(TestFn.run, .{ runtime, &channel });
    try group.wait();
}
