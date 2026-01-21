// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Helper function to fill an iovec buffer for writing with support for splatting patterns.
/// Used by both FileWriter and Stream.Writer to handle the splat parameter correctly.
///
/// Parameters:
/// - out: Output buffer of slices to fill
/// - header: Optional header data to write first
/// - data: Array of data slices, with the last slice being the pattern for splatting
/// - splat: Number of times to repeat the pattern (0 = don't include, 1 = include once, >1 = repeat)
/// - splat_buffer: Temporary buffer for expanding single-byte patterns
///
/// Returns: Number of slices filled in `out`
pub fn fillBuf(
    out: [][]const u8,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    splat_buffer: []u8,
) usize {
    var len: usize = 0;
    const max_len = out.len;

    // Add header
    if (header.len > 0 and len < max_len) {
        out[len] = header;
        len += 1;
    }

    if (data.len == 0) return len;

    // Add data slices (except last which might be pattern)
    const last_index = data.len - 1;
    for (data[0..last_index]) |bytes| {
        if (bytes.len > 0 and len < max_len) {
            out[len] = bytes;
            len += 1;
        }
    }

    // Handle pattern/splat
    const pattern = data[last_index];
    switch (splat) {
        0 => {},
        1 => if (pattern.len > 0 and len < max_len) {
            out[len] = pattern;
            len += 1;
        },
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                if (len < max_len) {
                    out[len] = buf;
                    len += 1;
                }
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and len < max_len) {
                    out[len] = splat_buffer;
                    len += 1;
                    remaining_splat -= splat_buffer.len;
                }
                if (remaining_splat > 0 and len < max_len) {
                    out[len] = splat_buffer[0..remaining_splat];
                    len += 1;
                }
            },
            else => {
                var i: usize = 0;
                while (i < splat and len < max_len) : (i += 1) {
                    out[len] = pattern;
                    len += 1;
                }
            },
        },
    }

    return len;
}

test "fillBuf: single-byte pattern with small splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"x"};

    const len = fillBuf(&out, "", &data, 5, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("xxxxx", out[0]);
}

test "fillBuf: single-byte pattern with large splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"y"};

    const len = fillBuf(&out, "", &data, 200, &splat_buf);
    try std.testing.expect(len > 1); // Should use multiple iovecs

    var total: usize = 0;
    for (out[0..len]) |slice| {
        total += slice.len;
        // Verify all bytes are 'y'
        for (slice) |byte| {
            try std.testing.expectEqual('y', byte);
        }
    }
    try std.testing.expectEqual(200, total);
}

test "fillBuf: multi-byte pattern with splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{"ab"};

    const len = fillBuf(&out, "", &data, 3, &splat_buf);
    try std.testing.expectEqual(3, len);
    try std.testing.expectEqualStrings("ab", out[0]);
    try std.testing.expectEqualStrings("ab", out[1]);
    try std.testing.expectEqualStrings("ab", out[2]);
}

test "fillBuf: with header and data" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "world", "!" };

    const len = fillBuf(&out, "header:", &data, 1, &splat_buf);
    try std.testing.expectEqual(4, len);
    try std.testing.expectEqualStrings("header:", out[0]);
    try std.testing.expectEqualStrings("hello", out[1]);
    try std.testing.expectEqualStrings("world", out[2]);
    try std.testing.expectEqualStrings("!", out[3]);
}

test "fillBuf: splat=0 excludes pattern" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "pattern" };

    const len = fillBuf(&out, "", &data, 0, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("hello", out[0]);
}

test "fillBuf: empty pattern with splat" {
    var out: [16][]const u8 = undefined;
    var splat_buf: [64]u8 = undefined;
    var data = [_][]const u8{ "hello", "" };

    const len = fillBuf(&out, "", &data, 5, &splat_buf);
    try std.testing.expectEqual(1, len);
    try std.testing.expectEqualStrings("hello", out[0]);
}
