// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const aio = @import("aio");

/// Generic reader for any stream type that implements readVec(rt, [][]u8) !usize
pub fn StreamReader(comptime T: type) type {
    const Runtime = @import("runtime.zig").Runtime;
    return struct {
        const Self = @This();

        stream: T,
        runtime: *Runtime,
        interface: std.Io.Reader,

        pub fn init(stream: T, runtime: *Runtime, buffer: []u8) Self {
            return .{
                .stream = stream,
                .runtime = runtime,
                .interface = .{
                    .vtable = &.{
                        .stream = streamFn,
                        .discard = discard,
                        .readVec = readVec,
                    },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn streamFn(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));
            const dest = limit.slice(try w.writableSliceGreedy(1));

            var slices = [1][]u8{dest};
            const n = r.stream.readVec(r.runtime, &slices) catch |err| {
                // Convert Canceled to ReadFailed since std.Io.Reader doesn't support cancellation
                return if (err == error.Canceled) error.ReadFailed else @errorCast(err);
            };

            w.advance(n);
            return n;
        }

        fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));
            // Use the buffer as temporary storage for discarded data
            var total_discarded: usize = 0;
            const remaining = @intFromEnum(limit);

            while (total_discarded < remaining) {
                const to_read = @min(remaining - total_discarded, io_reader.buffer.len);
                var slices = [1][]u8{io_reader.buffer[0..to_read]};
                const n = r.stream.readVec(r.runtime, &slices) catch |err| {
                    if (err == error.EndOfStream) break;
                    return error.ReadFailed;
                };
                total_discarded += n;
            }
            return total_discarded;
        }

        fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));

            // Get writable vectors from io_reader
            // buffer needs space for data.len + 1 (for internal buffer)
            const max_vecs = 17; // 16 data slices + 1 internal buffer
            var buffer_storage: [max_vecs][]u8 = undefined;
            const buffer_slice = if (data.len + 1 <= max_vecs)
                buffer_storage[0 .. data.len + 1]
            else
                buffer_storage[0..];

            const dest_n, const data_size = try io_reader.writableVector(buffer_slice, data);
            if (dest_n == 0) return 0;

            // writableVector fills buffer_slice with the actual slices to read into
            const n = r.stream.readVec(r.runtime, buffer_slice[0..dest_n]) catch |err| {
                // Convert Canceled to ReadFailed since std.Io.Reader doesn't support cancellation
                return if (err == error.Canceled) error.ReadFailed else @errorCast(err);
            };

            // Update buffer end pointer if we read into internal buffer
            if (n > data_size) {
                io_reader.end += n - data_size;
                return data_size;
            }
            return n;
        }
    };
}

/// Generic writer for any stream type that implements writeVec(rt, []const []const u8) !usize
pub fn StreamWriter(comptime T: type) type {
    const Runtime = @import("runtime.zig").Runtime;
    return struct {
        const Self = @This();

        stream: T,
        runtime: *Runtime,
        interface: std.Io.Writer,

        pub fn init(stream: T, runtime: *Runtime, buffer: []u8) Self {
            return .{
                .stream = stream,
                .runtime = runtime,
                .interface = .{
                    .vtable = &.{
                        .drain = drain,
                        .flush = flush,
                    },
                    .buffer = buffer,
                    .end = 0,
                },
            };
        }

        fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const w: *Self = @alignCast(@fieldParentPtr("interface", io_writer));
            const buffered = io_writer.buffered();

            const max_vecs = 16; // Reasonable limit for iovecs
            var vecs: [max_vecs][]const u8 = undefined;
            var len: usize = 0;

            // Add buffered data first
            if (buffered.len > 0) {
                vecs[len] = buffered;
                len += 1;
            }

            // Add data slices
            for (data[0 .. data.len - 1]) |d| {
                if (d.len == 0) continue;
                vecs[len] = d;
                len += 1;
                if (len == vecs.len) break;
            }

            // Add splat pattern
            const pattern = data[data.len - 1];
            if (len < vecs.len) switch (splat) {
                0 => {},
                1 => if (pattern.len != 0) {
                    vecs[len] = pattern;
                    len += 1;
                },
                else => switch (pattern.len) {
                    0 => {},
                    1 => {
                        // Optimize single-character splat by using a temporary buffer
                        const splat_buffer_candidate = io_writer.buffer[io_writer.end..];
                        var backup_buffer: [64]u8 = undefined;
                        const splat_buffer = if (splat_buffer_candidate.len >= backup_buffer.len)
                            splat_buffer_candidate
                        else
                            &backup_buffer;
                        const memset_len = @min(splat_buffer.len, splat);
                        const buf = splat_buffer[0..memset_len];
                        @memset(buf, pattern[0]);
                        vecs[len] = buf;
                        len += 1;
                    },
                    else => {
                        // Multi-character pattern, just write it once
                        vecs[len] = pattern;
                        len += 1;
                    },
                },
            };

            if (len == 0) return 0;

            const n = w.stream.writeVec(w.runtime, vecs[0..len]) catch |err| {
                if (err == error.Canceled) return error.WriteFailed;
                return error.WriteFailed;
            };
            return io_writer.consume(n);
        }

        fn flush(io_writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const w: *Self = @alignCast(@fieldParentPtr("interface", io_writer));

            while (io_writer.end > 0) {
                const buffered = io_writer.buffered();
                var slices = [1][]const u8{buffered};
                const n = w.stream.writeVec(w.runtime, &slices) catch |err| {
                    if (err == error.Canceled) return error.WriteFailed;
                    return error.WriteFailed;
                };

                if (n == 0) return error.WriteFailed; // No progress

                if (n < buffered.len) {
                    // Partial write - shift remaining
                    std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                    io_writer.end -= n;
                } else {
                    io_writer.end = 0;
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

/// Mock stream type for testing StreamReader/StreamWriter.
/// Uses an in-memory buffer to simulate readVec/writeVec operations.
const BufferStream = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    read_pos: usize = 0,

    fn init(allocator: std.mem.Allocator) BufferStream {
        return .{ .allocator = allocator, .buffer = .empty };
    }

    fn deinit(self: *BufferStream) void {
        self.buffer.deinit(self.allocator);
    }

    fn reset(self: *BufferStream) void {
        self.buffer.clearRetainingCapacity();
        self.read_pos = 0;
    }

    /// Implements readVec for StreamReader compatibility.
    /// Returns error.EndOfStream when no more data available (NOT 0).
    fn readVec(self: *BufferStream, rt: anytype, slices: [][]u8) std.Io.Reader.Error!usize {
        _ = rt; // Unused in mock
        const available = self.buffer.items[self.read_pos..];
        if (available.len == 0) return error.EndOfStream;

        var copied: usize = 0;
        for (slices) |slice| {
            if (copied >= available.len) break;
            const to_copy = @min(slice.len, available.len - copied);
            @memcpy(slice[0..to_copy], available[copied..][0..to_copy]);
            copied += to_copy;
        }

        self.read_pos += copied;
        return copied;
    }

    /// Implements writeVec for StreamWriter compatibility.
    fn writeVec(self: *BufferStream, rt: anytype, slices: []const []const u8) std.Io.Writer.Error!usize {
        _ = rt; // Unused in mock
        var written: usize = 0;
        for (slices) |slice| {
            self.buffer.appendSlice(self.allocator, slice) catch return error.WriteFailed;
            written += slice.len;
        }
        return written;
    }
};

test "StreamWriter/Reader: basic write and read" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    // Write data
    {
        var write_buffer: [256]u8 = undefined;
        var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

        try writer.interface.writeAll("Hello, ");
        try writer.interface.writeAll("World!");
        try writer.interface.flush();
    }

    // Read data back
    {
        var read_buffer: [256]u8 = undefined;
        var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);

        var result: [20]u8 = undefined;
        const n = try reader.interface.readSliceShort(&result);

        try testing.expectEqual(13, n);
        try testing.expectEqualStrings("Hello, World!", result[0..n]);
    }
}

test "StreamWriter: writeSplat pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [256]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    // Test splat: "ba" + "na" repeated 3 times = "bananana"
    var data = [_][]const u8{ "ba", "na" };
    try writer.interface.writeSplatAll(&data, 3);
    try writer.interface.flush();

    try testing.expectEqualStrings("bananana", stream.buffer.items);
}

test "StreamWriter: writeSplat single element" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [256]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    // Test single element splat: "hello" repeated 3 times
    var data = [_][]const u8{"hello"};
    try writer.interface.writeSplatAll(&data, 3);
    try writer.interface.flush();

    try testing.expectEqualStrings("hellohellohello", stream.buffer.items);
}

test "StreamWriter: writeSplat single character optimization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [256]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    // Test single-character splat: "x" repeated 50 times
    // This should use the @memset optimization
    var data = [_][]const u8{"x"};
    try writer.interface.writeSplatAll(&data, 50);
    try writer.interface.flush();

    try testing.expectEqual(50, stream.buffer.items.len);
    for (stream.buffer.items) |c| {
        try testing.expectEqual('x', c);
    }
}

test "StreamWriter: writeVec multiple slices" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [256]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    // Write multiple slices at once
    const slices = &[_][]const u8{ "Hello", ", ", "World", "!" };
    _ = try writer.interface.writeVec(slices);
    try writer.interface.flush();

    try testing.expectEqualStrings("Hello, World!", stream.buffer.items);
}

test "StreamWriter: flush drains buffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [16]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    // Write less than buffer size
    try writer.interface.writeAll("Hello");
    try testing.expectEqual(5, writer.interface.end);
    try testing.expectEqual(0, stream.buffer.items.len);

    // Flush should drain to stream
    try writer.interface.flush();
    try testing.expectEqual(0, writer.interface.end);
    try testing.expectEqualStrings("Hello", stream.buffer.items);
}

test "StreamReader: EndOfStream error on empty buffer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var read_buffer: [256]u8 = undefined;
    var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);

    var result: [10]u8 = undefined;

    // readSliceShort catches EndOfStream and returns 0 bytes read
    const n = try reader.interface.readSliceShort(&result);
    try testing.expectEqual(0, n);
}

test "StreamReader: partial read then EOF" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    try stream.buffer.appendSlice(allocator, "Hello");

    var read_buffer: [256]u8 = undefined;
    var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);

    // First read succeeds
    var result: [10]u8 = undefined;
    const n = try reader.interface.readSliceShort(&result);
    try testing.expectEqual(5, n);
    try testing.expectEqualStrings("Hello", result[0..n]);

    // Second read hits EOF - readSliceShort returns 0 bytes
    const n2 = try reader.interface.readSliceShort(&result);
    try testing.expectEqual(0, n2);
}

test "StreamReader: discard bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    try stream.buffer.appendSlice(allocator, "Hello, World!");

    var read_buffer: [256]u8 = undefined;
    var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);

    // Discard first 7 bytes
    const discarded = try reader.interface.discard(.limited(7));
    try testing.expectEqual(7, discarded);

    // Read remaining
    var result: [10]u8 = undefined;
    const n = try reader.interface.readSliceShort(&result);
    try testing.expectEqual(6, n);
    try testing.expectEqualStrings("World!", result[0..n]);
}

test "StreamReader: takeByte reads first byte correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    // Add test data that resembles RESP protocol
    try stream.buffer.appendSlice(allocator, "*1\r\n$4\r\nPING\r\n");

    var read_buffer: [256]u8 = undefined;
    var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);

    // Read first byte - should be '*'
    const first_byte = try reader.interface.takeByte();
    try testing.expectEqual(@as(u8, '*'), first_byte);

    // Read rest of first line
    const line1 = try reader.interface.takeDelimiterExclusive('\r');
    try testing.expectEqualStrings("1", line1);
    _ = try reader.interface.takeByte(); // consume '\r'
    _ = try reader.interface.takeByte(); // consume '\n'

    // Read second line
    const line2 = try reader.interface.takeDelimiterExclusive('\r');
    try testing.expectEqualStrings("$4", line2);
}

test "StreamWriter/Reader: interleaved operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    // Write some data
    {
        var write_buffer: [256]u8 = undefined;
        var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);
        try writer.interface.writeAll("First ");
        try writer.interface.flush();
    }

    // Read it
    {
        var read_buffer: [256]u8 = undefined;
        var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);
        var result: [10]u8 = undefined;
        const n = try reader.interface.readSliceShort(&result);
        try testing.expectEqualStrings("First ", result[0..n]);
    }

    // Write more
    {
        var write_buffer: [256]u8 = undefined;
        var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);
        try writer.interface.writeAll("Second");
        try writer.interface.flush();
    }

    // Read it
    {
        var read_buffer: [256]u8 = undefined;
        var reader = StreamReader(*BufferStream).init(&stream, undefined, &read_buffer);
        var result: [10]u8 = undefined;
        const n = try reader.interface.readSliceShort(&result);
        try testing.expectEqualStrings("Second", result[0..n]);
    }
}

test "StreamWriter: empty write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stream = BufferStream.init(allocator);
    defer stream.deinit();

    var write_buffer: [256]u8 = undefined;
    var writer = StreamWriter(*BufferStream).init(&stream, undefined, &write_buffer);

    try writer.interface.writeAll("");
    try writer.interface.flush();

    try testing.expectEqual(0, stream.buffer.items.len);
}
