// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const StreamReader = @import("../stream.zig").StreamReader;
const StreamWriter = @import("../stream.zig").StreamWriter;
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const runIo = @import("base.zig").runIo;

const Handle = std.fs.File.Handle;

/// Core file I/O primitives that operate on raw file handles.
/// These functions are used by both the File struct and std.Io vtable implementations.
/// Read from file at specified offset using vectored I/O (up to 2 buffers).
/// Does not update any position tracking - purely positional read.
pub fn fileReadPositional(rt: *Runtime, fd: Handle, buffers: [][]u8, offset: u64) !usize {
    var completion: xev.Completion = .{ .op = .{
        .pread = .{
            .fd = fd,
            .buffer = xev.ReadBuffer.fromSlices(buffers),
            .offset = offset,
        },
    } };
    return runIo(rt, &completion, "pread");
}

/// Write to file at specified offset using vectored I/O (up to 2 buffers).
/// Does not update any position tracking - purely positional write.
pub fn fileWritePositional(rt: *Runtime, fd: Handle, buffers: []const []const u8, offset: u64) !usize {
    var completion: xev.Completion = .{ .op = .{
        .pwrite = .{
            .fd = fd,
            .buffer = xev.WriteBuffer.fromSlices(buffers),
            .offset = offset,
        },
    } };
    return runIo(rt, &completion, "pwrite");
}

/// Read from file at tracked position using vectored I/O (up to 2 buffers).
/// Updates the position pointer after successful read.
pub fn fileReadStreaming(rt: *Runtime, fd: Handle, buffers: [][]u8, position: *u64) !usize {
    var completion: xev.Completion = .{ .op = .{
        .pread = .{
            .fd = fd,
            .buffer = xev.ReadBuffer.fromSlices(buffers),
            .offset = position.*,
        },
    } };
    const bytes_read = try runIo(rt, &completion, "pread");
    position.* += bytes_read;
    return bytes_read;
}

/// Write to file at tracked position using vectored I/O (up to 2 buffers).
/// Updates the position pointer after successful write.
pub fn fileWriteStreaming(rt: *Runtime, fd: Handle, buffers: []const []const u8, position: *u64) !usize {
    var completion: xev.Completion = .{ .op = .{
        .pwrite = .{
            .fd = fd,
            .buffer = xev.WriteBuffer.fromSlices(buffers),
            .offset = position.*,
        },
    } };
    const bytes_written = try runIo(rt, &completion, "pwrite");
    position.* += bytes_written;
    return bytes_written;
}

/// Seek to absolute position (updates position pointer).
pub fn fileSeekTo(position: *u64, offset: u64) void {
    position.* = offset;
}

/// Seek relative to current position (updates position pointer).
pub fn fileSeekBy(position: *u64, delta: i64) !void {
    const new_pos: i64 = @as(i64, @intCast(position.*)) + delta;
    if (new_pos < 0) return error.InvalidOffset;
    position.* = @intCast(new_pos);
}

pub const File = struct {
    fd: Handle,
    /// File position for sequential read/write operations.
    /// On Windows with overlapped I/O, we track this ourselves since the OS doesn't.
    /// Starts at 0, matching POSIX behavior for newly opened files.
    position: u64 = 0,

    pub fn init(std_file: std.fs.File) File {
        return File{
            .fd = std_file.handle,
        };
    }

    pub fn initFd(fd: Handle) File {
        return File{
            .fd = fd,
        };
    }

    pub fn read(self: *File, rt: *Runtime, buffer: []u8) !usize {
        var bufs = [_][]u8{buffer};
        return fileReadStreaming(rt, self.fd, &bufs, &self.position);
    }

    pub fn write(self: *File, rt: *Runtime, data: []const u8) !usize {
        var bufs = [_][]const u8{data};
        return fileWriteStreaming(rt, self.fd, &bufs, &self.position);
    }

    /// Seek to a position in the file.
    /// Updates the internal position used by read() and write().
    /// Does not affect pread() or pwrite() operations.
    pub fn seek(self: *File, offset: i64, whence: std.fs.File.SeekableStream.SeekFrom) !u64 {
        switch (whence) {
            .start => {
                if (offset < 0) return error.InvalidOffset;
                fileSeekTo(&self.position, @intCast(offset));
                return self.position;
            },
            .current => {
                try fileSeekBy(&self.position, offset);
                return self.position;
            },
            .end => {
                // Seeking from end requires getting file size, which we don't support yet
                return error.Unsupported;
            },
        }
    }

    pub fn pread(self: *File, rt: *Runtime, buffer: []u8, offset: u64) !usize {
        var bufs = [_][]u8{buffer};
        return fileReadPositional(rt, self.fd, &bufs, offset);
    }

    pub fn pwrite(self: *File, rt: *Runtime, data: []const u8, offset: u64) !usize {
        var bufs = [_][]const u8{data};
        return fileWritePositional(rt, self.fd, &bufs, offset);
    }

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.Io.Reader compatible errors.
    pub fn readBuf(self: *File, rt: *Runtime, buffer: *xev.ReadBuffer) (Cancelable || std.Io.Reader.Error)!usize {
        var completion: xev.Completion = .{ .op = .{
            .pread = .{
                .fd = self.fd,
                .buffer = buffer.*,
                .offset = self.position,
            },
        } };

        const bytes_read = runIo(rt, &completion, "pread") catch |err| switch (err) {
            error.EOF => return error.EndOfStream,
            else => return error.ReadFailed,
        };

        // Copy array data back to caller's buffer if needed
        if (buffer.* == .array) {
            buffer.array = completion.op.pread.buffer.array;
        }

        self.position += bytes_read;
        return bytes_read;
    }

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.Io.Writer compatible errors.
    pub fn writeBuf(self: *File, rt: *Runtime, buffer: xev.WriteBuffer) (Cancelable || std.Io.Writer.Error)!usize {
        var completion: xev.Completion = .{ .op = .{
            .pwrite = .{
                .fd = self.fd,
                .buffer = buffer,
                .offset = self.position,
            },
        } };

        const bytes_written = runIo(rt, &completion, "pwrite") catch return error.WriteFailed;
        self.position += bytes_written;
        return bytes_written;
    }

    pub fn close(self: *File, rt: *Runtime) void {
        var completion: xev.Completion = .{ .op = .{
            .close = .{
                .fd = self.fd,
            },
        } };

        rt.beginShield();
        defer rt.endShield();

        // Ignore close errors, following Zig std lib pattern
        runIo(rt, &completion, "close") catch {};
    }

    // Zig 0.15+ streaming interface
    pub const Reader = StreamReader(*File);
    pub const Writer = StreamWriter(*File);

    pub fn reader(self: *File, rt: *Runtime, buffer: []u8) Reader {
        return Reader.init(self, rt, buffer);
    }

    pub fn writer(self: *File, rt: *Runtime, buffer: []u8) Writer {
        return Writer.init(self, rt, buffer);
    }
};

test "File: basic read and write" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            std.log.info("TestTask: Starting file test", .{});

            // Create a test file using the new fs module
            const file_path = "test_file_basic.txt";
            var zio_file = try fs.createFile(rt, file_path, .{});
            defer std.fs.cwd().deleteFile(file_path) catch {};
            std.log.info("TestTask: Created file using fs module", .{});

            // Write test
            const write_data = "Hello, zio!";
            std.log.info("TestTask: About to write data", .{});
            const bytes_written = try zio_file.write(rt, write_data);
            std.log.info("TestTask: Wrote {} bytes", .{bytes_written});
            try std.testing.expectEqual(write_data.len, bytes_written);

            // Close file before reopening for read
            zio_file.close(rt);
            std.log.info("TestTask: Closed file after write", .{});

            // Read test - reopen the file for reading
            var read_file = try fs.openFile(rt, file_path, .{ .mode = .read_only });
            defer read_file.close(rt);
            std.log.info("TestTask: Reopened file for reading", .{});

            var buffer: [100]u8 = undefined;
            const bytes_read = try read_file.read(rt, &buffer);
            std.log.info("TestTask: Read {} bytes", .{bytes_read});
            try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            std.log.info("TestTask: File test completed successfully", .{});
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
            const file_path = "test_file_positional.txt";
            var zio_file = try fs.createFile(rt, file_path, .{ .read = true });
            defer zio_file.close(rt);
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write at different positions
            try std.testing.expectEqual(5, try zio_file.pwrite(rt, "HELLO", 0));
            try std.testing.expectEqual(5, try zio_file.pwrite(rt, "WORLD", 10));

            // Read from positions
            var buf: [5]u8 = undefined;
            try std.testing.expectEqual(5, try zio_file.pread(rt, &buf, 0));
            try std.testing.expectEqualStrings("HELLO", &buf);

            try std.testing.expectEqual(5, try zio_file.pread(rt, &buf, 10));
            try std.testing.expectEqualStrings("WORLD", &buf);

            // Test reading from gap (should be zeros or random data)
            var gap_buf: [3]u8 = undefined;
            try std.testing.expectEqual(3, try zio_file.pread(rt, &gap_buf, 5));
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
            const file_path = "test_file_close.txt";
            var zio_file = try fs.createFile(rt, file_path, .{});
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write some data
            const bytes_written = try zio_file.write(rt, "test data");
            try std.testing.expectEqual(9, bytes_written);

            // Close the file using zio
            zio_file.close(rt);

            // File should now be closed
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
            const file_path = "test_file_rw_interface.txt";
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write using writer interface
            {
                var file = try fs.createFile(rt, file_path, .{});

                var write_buffer: [256]u8 = undefined;
                var writer = file.writer(rt, &write_buffer);

                // Test writeSplatAll with single-character pattern
                var data = [_][]const u8{"x"};
                try writer.interface.writeSplatAll(&data, 10);
                try writer.interface.flush();

                file.close(rt);
            }

            // Read using reader interface
            {
                var file = try fs.openFile(rt, file_path, .{});

                var read_buffer: [256]u8 = undefined;
                var reader = file.reader(rt, &read_buffer);

                var result: [20]u8 = undefined;
                const bytes_read = try reader.interface.readSliceShort(&result);

                try std.testing.expectEqual(10, bytes_read);
                try std.testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);

                file.close(rt);
            }
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File primitives: vectored positional read/write" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const file_path = "test_primitives_positional.txt";
            var file = try fs.createFile(rt, file_path, .{ .read = true });
            defer file.close(rt);
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write using 2 buffers
            const buf1 = "HELLO";
            const buf2 = "WORLD";
            const write_bufs = [_][]const u8{ buf1, buf2 };
            const bytes_written = try fileWritePositional(rt, file.fd, &write_bufs, 0);
            try std.testing.expectEqual(10, bytes_written);

            // Read using 2 buffers
            var read_buf1: [5]u8 = undefined;
            var read_buf2: [5]u8 = undefined;
            var read_bufs = [_][]u8{ &read_buf1, &read_buf2 };
            const bytes_read = try fileReadPositional(rt, file.fd, &read_bufs, 0);
            try std.testing.expectEqual(10, bytes_read);
            try std.testing.expectEqualStrings("HELLO", &read_buf1);
            try std.testing.expectEqualStrings("WORLD", &read_buf2);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File primitives: vectored streaming read/write" {
    const fs = @import("../fs.zig");

    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const file_path = "test_primitives_streaming.txt";
            var file = try fs.createFile(rt, file_path, .{ .read = true });
            defer file.close(rt);
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write using streaming with position tracking
            var write_pos: u64 = 0;
            const buf1 = "FIRST";
            const buf2 = "SECOND";
            const write_bufs1 = [_][]const u8{buf1};
            const write_bufs2 = [_][]const u8{buf2};

            const bytes1 = try fileWriteStreaming(rt, file.fd, &write_bufs1, &write_pos);
            try std.testing.expectEqual(5, bytes1);
            try std.testing.expectEqual(5, write_pos);

            const bytes2 = try fileWriteStreaming(rt, file.fd, &write_bufs2, &write_pos);
            try std.testing.expectEqual(6, bytes2);
            try std.testing.expectEqual(11, write_pos);

            // Read using streaming with position tracking
            var read_pos: u64 = 0;
            var read_buf1: [5]u8 = undefined;
            var read_buf2: [6]u8 = undefined;
            var read_bufs1 = [_][]u8{&read_buf1};
            var read_bufs2 = [_][]u8{&read_buf2};

            const read1 = try fileReadStreaming(rt, file.fd, &read_bufs1, &read_pos);
            try std.testing.expectEqual(5, read1);
            try std.testing.expectEqual(5, read_pos);
            try std.testing.expectEqualStrings("FIRST", &read_buf1);

            const read2 = try fileReadStreaming(rt, file.fd, &read_bufs2, &read_pos);
            try std.testing.expectEqual(6, read2);
            try std.testing.expectEqual(11, read_pos);
            try std.testing.expectEqualStrings("SECOND", &read_buf2);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}

test "File primitives: seek operations" {
    const runtime = try Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            _ = rt;
            var position: u64 = 0;

            // Test seekTo
            fileSeekTo(&position, 100);
            try std.testing.expectEqual(100, position);

            // Test seekBy positive
            try fileSeekBy(&position, 50);
            try std.testing.expectEqual(150, position);

            // Test seekBy negative
            try fileSeekBy(&position, -50);
            try std.testing.expectEqual(100, position);

            // Test seekBy with negative result (should error)
            const result = fileSeekBy(&position, -200);
            try std.testing.expectError(error.InvalidOffset, result);
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{runtime}, .{});
}
