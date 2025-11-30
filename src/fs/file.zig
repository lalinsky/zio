// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const aio = @import("aio");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const waitForIo = @import("../io.zig").waitForIo;
const genericCallback = @import("../io.zig").genericCallback;

const Handle = std.fs.File.Handle;

pub const File = struct {
    fd: Handle,

    pub fn fromFd(fd: Handle) File {
        return .{ .fd = fd };
    }

    pub fn read(self: *File, rt: *Runtime, buffer: []u8, offset: usize) !usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [1]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, .fromSlice(buffer, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    pub fn write(self: *File, rt: *Runtime, data: []const u8, offset: usize) !usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [1]aio.system.iovec_const = undefined;
        var op = aio.FileWrite.init(self.fd, .fromSlice(data, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    /// Read from file into multiple slices (vectored read).
    /// Returns std.Io.Reader compatible errors.
    pub fn readVec(self: *File, rt: *Runtime, slices: [][]u8, offset: usize) (Cancelable || std.Io.Reader.Error)!usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, aio.ReadBuf.fromSlices(slices, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const bytes_read = op.getResult() catch return error.ReadFailed;

        // EOF is indicated by 0 bytes read
        if (bytes_read == 0) return error.EndOfStream;

        return bytes_read;
    }

    /// Write to file from multiple slices (vectored write).
    /// Returns std.Io.Writer compatible errors.
    pub fn writeVec(self: *File, rt: *Runtime, slices: []const []const u8, offset: usize) (Cancelable || std.Io.Writer.Error)!usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec_const = undefined;
        var op = aio.FileWrite.init(self.fd, aio.WriteBuf.fromSlices(slices, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return op.getResult() catch error.WriteFailed;
    }

    pub fn close(self: *File, rt: *Runtime) void {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var op = aio.FileClose.init(self.fd);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        rt.beginShield();
        defer rt.endShield();

        executor.loop.add(&op.c);
        waitForIo(rt, &op.c) catch unreachable;

        // Ignore close errors, following Zig std lib pattern
        _ = op.getResult() catch {};
    }
};

/// File reader that tracks position and implements std.Io.Reader interface
pub const FileReader = struct {
    file: *File,
    runtime: *Runtime,
    position: usize = 0,
    interface: std.Io.Reader,

    pub fn init(file: *File, runtime: *Runtime, buffer: []u8) FileReader {
        return .{
            .file = file,
            .runtime = runtime,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .discard = discard,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
        const dest = limit.slice(try w.writableSliceGreedy(1));

        var slices = [1][]u8{dest};
        const n = r.file.readVec(r.runtime, &slices, r.position) catch |err| {
            return if (err == error.Canceled) error.ReadFailed else @errorCast(err);
        };

        r.position += n;
        w.advance(n);
        return n;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
        var total_discarded: usize = 0;
        const remaining = @intFromEnum(limit);

        while (total_discarded < remaining) {
            const to_read = @min(remaining - total_discarded, io_reader.buffer.len);
            var slices = [1][]u8{io_reader.buffer[0..to_read]};
            const n = r.file.readVec(r.runtime, &slices, r.position) catch |err| {
                if (err == error.EndOfStream) break;
                return error.ReadFailed;
            };
            r.position += n;
            total_discarded += n;
        }
        return total_discarded;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));

        const max_vecs = 17;
        var buffer_storage: [max_vecs][]u8 = undefined;
        const buffer_slice = if (data.len + 1 <= max_vecs)
            buffer_storage[0 .. data.len + 1]
        else
            buffer_storage[0..];

        const dest_n, const data_size = try io_reader.writableVector(buffer_slice, data);
        if (dest_n == 0) return 0;

        const n = r.file.readVec(r.runtime, buffer_slice[0..dest_n], r.position) catch |err| {
            return if (err == error.Canceled) error.ReadFailed else @errorCast(err);
        };

        r.position += n;

        if (n > data_size) {
            io_reader.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// File writer that tracks position and implements std.Io.Writer interface
pub const FileWriter = struct {
    file: *File,
    runtime: *Runtime,
    position: usize = 0,
    interface: std.Io.Writer,

    pub fn init(file: *File, runtime: *Runtime, buffer: []u8) FileWriter {
        return .{
            .file = file,
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
        const w: *FileWriter = @alignCast(@fieldParentPtr("interface", io_writer));
        const buffered = io_writer.buffered();

        const max_vecs = 16;
        var vecs: [max_vecs][]const u8 = undefined;
        var len: usize = 0;

        if (buffered.len > 0) {
            vecs[len] = buffered;
            len += 1;
        }

        for (data[0 .. data.len - 1]) |d| {
            if (d.len == 0) continue;
            vecs[len] = d;
            len += 1;
            if (len == vecs.len) break;
        }

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
                    vecs[len] = pattern;
                    len += 1;
                },
            },
        };

        if (len == 0) return 0;

        const n = w.file.writeVec(w.runtime, vecs[0..len], w.position) catch |err| {
            if (err == error.Canceled) return error.WriteFailed;
            return error.WriteFailed;
        };

        w.position += n;
        return io_writer.consume(n);
    }

    fn flush(io_writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const w: *FileWriter = @alignCast(@fieldParentPtr("interface", io_writer));

        while (io_writer.end > 0) {
            const buffered = io_writer.buffered();
            var slices = [1][]const u8{buffered};
            const n = w.file.writeVec(w.runtime, &slices, w.position) catch |err| {
                if (err == error.Canceled) return error.WriteFailed;
                return error.WriteFailed;
            };

            if (n == 0) return error.WriteFailed;

            w.position += n;

            if (n < buffered.len) {
                std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                io_writer.end -= n;
            } else {
                io_writer.end = 0;
            }
        }
    }
};

test "File: basic read and write" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            std.log.info("TestTask: Starting file test", .{});

            const dir = fs.cwd();
            const file_path = "test_file_basic.txt";
            var zio_file = try dir.createFile(rt, file_path, .{});
            std.log.info("TestTask: Created file using fs module", .{});

            // Write test
            const write_data = "Hello, zio!";
            std.log.info("TestTask: About to write data", .{});
            const bytes_written = try zio_file.write(rt, write_data, 0);
            std.log.info("TestTask: Wrote {} bytes", .{bytes_written});
            try std.testing.expectEqual(write_data.len, bytes_written);

            // Close file before reopening for read
            zio_file.close(rt);
            std.log.info("TestTask: Closed file after write", .{});

            // Read test - reopen the file for reading
            var read_file = try dir.openFile(rt, file_path, .{ .mode = .read_only });
            std.log.info("TestTask: Reopened file for reading", .{});

            var buffer: [100]u8 = undefined;
            const bytes_read = try read_file.read(rt, &buffer, 0);
            std.log.info("TestTask: Read {} bytes", .{bytes_read});
            try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            read_file.close(rt);
            std.log.info("TestTask: File test completed successfully", .{});

            try dir.deleteFile(rt, file_path);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File: positional read and write" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const dir = fs.cwd();
            const file_path = "test_file_positional.txt";
            var zio_file = try dir.createFile(rt, file_path, .{ .read = true });

            // Write at different positions
            try std.testing.expectEqual(5, try zio_file.write(rt, "HELLO", 0));
            try std.testing.expectEqual(5, try zio_file.write(rt, "WORLD", 10));

            // Read from positions
            var buf: [5]u8 = undefined;
            try std.testing.expectEqual(5, try zio_file.read(rt, &buf, 0));
            try std.testing.expectEqualStrings("HELLO", &buf);

            try std.testing.expectEqual(5, try zio_file.read(rt, &buf, 10));
            try std.testing.expectEqualStrings("WORLD", &buf);

            // Test reading from gap (should be zeros or random data)
            var gap_buf: [3]u8 = undefined;
            try std.testing.expectEqual(3, try zio_file.read(rt, &gap_buf, 5));

            zio_file.close(rt);
            try dir.deleteFile(rt, file_path);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File: close operation" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const dir = fs.cwd();
            const file_path = "test_file_close.txt";
            var zio_file = try dir.createFile(rt, file_path, .{});

            // Write some data
            const bytes_written = try zio_file.write(rt, "test data", 0);
            try std.testing.expectEqual(9, bytes_written);

            // Close the file using zio
            zio_file.close(rt);

            try dir.deleteFile(rt, file_path);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File: reader and writer interface" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const dir = fs.cwd();
            const file_path = "test_file_rw_interface.txt";

            // Write using writer interface
            {
                var file = try dir.createFile(rt, file_path, .{});

                var write_buffer: [256]u8 = undefined;
                var writer = FileWriter.init(&file, rt, &write_buffer);

                // Test writeSplatAll with single-character pattern
                var data = [_][]const u8{"x"};
                try writer.interface.writeSplatAll(&data, 10);
                try writer.interface.flush();

                file.close(rt);
            }

            // Read using reader interface
            {
                var file = try dir.openFile(rt, file_path, .{});

                var read_buffer: [256]u8 = undefined;
                var reader = FileReader.init(&file, rt, &read_buffer);

                var result: [20]u8 = undefined;
                const bytes_read = try reader.interface.readSliceShort(&result);

                try std.testing.expectEqual(10, bytes_read);
                try std.testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);

                file.close(rt);
            }

            try dir.deleteFile(rt, file_path);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}
