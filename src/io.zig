const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

/// Generic reader for any stream type that implements readBuf(xev.ReadBuffer) !usize
pub fn StreamReader(comptime T: type) type {
    return struct {
        const Self = @This();

        stream: *const T,
        interface: std.io.Reader,

        pub fn init(stream: *const T, buffer: []u8) Self {
            return .{
                .stream = stream,
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

        fn streamFn(io_reader: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));
            const dest = limit.slice(try w.writableSliceGreedy(1));

            const n = try r.stream.readBuf(.{ .slice = dest });

            w.advance(n);
            return n;
        }

        fn discard(io_reader: *std.io.Reader, limit: std.io.Limit) std.io.Reader.Error!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));
            // Use the buffer as temporary storage for discarded data
            var total_discarded: usize = 0;
            const remaining = @intFromEnum(limit);

            while (total_discarded < remaining) {
                const to_read = @min(remaining - total_discarded, io_reader.buffer.len);
                const n = r.stream.readBuf(.{ .slice = io_reader.buffer[0..to_read] }) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return error.ReadFailed,
                };
                total_discarded += n;
            }
            return total_discarded;
        }

        fn readVec(io_reader: *std.io.Reader, data: [][]u8) std.io.Reader.Error!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_reader));

            var buf: xev.ReadBuffer = .{ .vectors = .{ .data = undefined, .len = 0 } };
            const dest_n, const data_size = if (builtin.os.tag == .windows)
                try io_reader.writableVectorWsa(&buf.vectors.data, data)
            else
                try io_reader.writableVectorPosix(&buf.vectors.data, data);

            buf.vectors.len = dest_n;
            if (dest_n == 0) return 0;

            const n = try r.stream.readBuf(buf);

            // Update buffer end pointer if we read into internal buffer
            if (n > data_size) {
                io_reader.end += n - data_size;
                return data_size;
            }
            return n;
        }
    };
}

/// Generic writer for any stream type that implements writeBuf(xev.WriteBuffer) !usize
pub fn StreamWriter(comptime T: type) type {
    return struct {
        const Self = @This();

        stream: *const T,
        interface: std.io.Writer,

        pub fn init(stream: *const T, buffer: []u8) Self {
            return .{
                .stream = stream,
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

        fn drain(io_writer: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
            const w: *Self = @alignCast(@fieldParentPtr("interface", io_writer));
            const buffered = io_writer.buffered();

            const max_vecs = @typeInfo(std.meta.fieldInfo(
                std.meta.fieldInfo(xev.WriteBuffer, .vectors).type,
                .data,
            ).type).array.len;
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

            const write_buf = xev.WriteBuffer.fromSlices(vecs[0..len]);
            const n = try w.stream.writeBuf(write_buf);
            return io_writer.consume(n);
        }

        fn flush(io_writer: *std.io.Writer) std.io.Writer.Error!void {
            const w: *Self = @alignCast(@fieldParentPtr("interface", io_writer));

            while (io_writer.end > 0) {
                const buffered = io_writer.buffered();
                const n = try w.stream.writeBuf(.{ .slice = buffered });

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
