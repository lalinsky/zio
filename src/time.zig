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

pub const Clock = enum {
    monotonic,
    realtime,
};

/// A duration of time stored as nanoseconds.
pub const Duration = struct {
    ns: u64,

    pub const zero: Duration = .{ .ns = 0 };
    pub const max: Duration = .{ .ns = std.math.maxInt(u64) };

    pub fn fromNanoseconds(ns: u64) Duration {
        return .{ .ns = ns };
    }

    pub fn fromMicroseconds(us: u64) Duration {
        return .{ .ns = us *| std.time.ns_per_us };
    }

    pub fn fromMilliseconds(ms: u64) Duration {
        return .{ .ns = ms *| std.time.ns_per_ms };
    }

    pub fn fromSeconds(s: u64) Duration {
        return .{ .ns = s *| std.time.ns_per_s };
    }

    pub fn fromMinutes(m: u64) Duration {
        return .{ .ns = m *| std.time.ns_per_min };
    }

    pub fn toNanoseconds(self: Duration) u64 {
        return self.ns;
    }

    pub fn toMicroseconds(self: Duration) u64 {
        return @divTrunc(self.ns, std.time.ns_per_us);
    }

    pub fn toMilliseconds(self: Duration) u64 {
        return @divTrunc(self.ns, std.time.ns_per_ms);
    }

    pub fn toSeconds(self: Duration) u64 {
        return @divTrunc(self.ns, std.time.ns_per_s);
    }

    pub fn toMinutes(self: Duration) u64 {
        return @divTrunc(self.ns, std.time.ns_per_min);
    }

    pub fn toTimespec(self: Duration) os.timespec {
        return .{
            .sec = @intCast(self.ns / std.time.ns_per_s),
            .nsec = @intCast(self.ns % std.time.ns_per_s),
        };
    }

    /// Formats the duration in Go-style format (e.g., "1h30m45s", "500ms", "1.5us").
    pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const start = formatBuf(self.ns, &buf);
        try w.writeAll(buf[start..]);
    }

    /// Formats duration into buffer from the end, returns start index.
    fn formatBuf(ns: u64, buf: *[32]u8) usize {
        var u = ns;
        var i: usize = buf.len;

        if (u < std.time.ns_per_s) {
            // Sub-second: use smaller units like "1.2ms"
            var prec: usize = undefined;
            i -= 1;
            buf[i] = 's';
            if (u == 0) {
                i -= 1;
                buf[i] = '0';
                return i;
            } else if (u < std.time.ns_per_us) {
                // nanoseconds
                prec = 0;
                i -= 1;
                buf[i] = 'n';
            } else if (u < std.time.ns_per_ms) {
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
                std.time.ns_per_us
            else if (std.mem.eql(u8, unit, "ms"))
                std.time.ns_per_ms
            else if (std.mem.eql(u8, unit, "s"))
                std.time.ns_per_s
            else if (std.mem.eql(u8, unit, "m"))
                std.time.ns_per_min
            else if (std.mem.eql(u8, unit, "h"))
                std.time.ns_per_hour
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

        return .{ .ns = ns };
    }
};

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
        const d = Duration{ .ns = case.ns };
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
        const d = try Duration.parse(case.input);
        try std.testing.expectEqual(case.expected, d.ns);
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

    // Valid edge case: max u64 in nanoseconds
    try std.testing.expectEqual(std.math.maxInt(u64), (try Duration.parse("18446744073709551615ns")).ns);
}

test "Duration: overflow saturation" {
    // Values that would overflow if multiplied normally should saturate to Duration.max
    const max_u64 = std.math.maxInt(u64);

    // fromMicroseconds: max_u64 * 1000 would overflow
    try std.testing.expectEqual(Duration.max, Duration.fromMicroseconds(max_u64));

    // fromMilliseconds: max_u64 * 1_000_000 would overflow
    try std.testing.expectEqual(Duration.max, Duration.fromMilliseconds(max_u64));

    // fromSeconds: max_u64 * 1_000_000_000 would overflow
    try std.testing.expectEqual(Duration.max, Duration.fromSeconds(max_u64));

    // fromMinutes: max_u64 * 60_000_000_000 would overflow
    try std.testing.expectEqual(Duration.max, Duration.fromMinutes(max_u64));

    // Verify non-overflowing values still work correctly
    try std.testing.expectEqual(1_000_000_000, Duration.fromSeconds(1).ns);
    try std.testing.expectEqual(60_000_000_000, Duration.fromMinutes(1).ns);
}
