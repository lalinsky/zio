// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const aio = @import("aio");
const StreamReader = @import("../stream.zig").StreamReader;
const StreamWriter = @import("../stream.zig").StreamWriter;
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const waitForIo = @import("base.zig").waitForIo;
const genericCallback = @import("base.zig").genericCallback;

const Handle = std.fs.File.Handle;

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
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [1]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, .fromSlice(buffer, &storage), self.position);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const bytes_read = try op.getResult();
        self.position += bytes_read;
        return bytes_read;
    }

    pub fn write(self: *File, rt: *Runtime, data: []const u8) !usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        std.log.debug("write: fd={}, data.len={}, position={}", .{ self.fd, data.len, self.position });
        var storage: [1]aio.system.iovec_const = undefined;
        std.log.debug("write: created storage", .{});
        const write_buf = aio.WriteBuf.fromSlice(data, &storage);
        std.log.debug("write: created WriteBuf, iovecs.len={}", .{write_buf.iovecs.len});
        var op = aio.FileWrite.init(self.fd, write_buf, self.position);
        std.log.debug("write: initialized FileWrite", .{});
        op.c.userdata = task;
        op.c.callback = genericCallback;

        std.log.debug("write: adding to loop", .{});
        executor.loop.add(&op.c);
        std.log.debug("write: waiting for IO", .{});
        try waitForIo(rt, &op.c);
        std.log.debug("write: IO completed, state={}, has_result={}", .{ op.c.state, op.c.has_result });
        std.log.debug("write: result_private_do_not_touch={}", .{op.result_private_do_not_touch});

        std.log.debug("write: calling getResult", .{});
        const bytes_written = op.getResult() catch |err| {
            std.log.err("write: getResult failed with error: {}", .{err});
            return err;
        };
        std.log.debug("write: getResult returned {} bytes", .{bytes_written});
        self.position += bytes_written;
        return bytes_written;
    }

    /// Seek to a position in the file.
    /// Updates the internal position used by read() and write().
    /// Does not affect pread() or pwrite() operations.
    pub fn seek(self: *File, offset: i64, whence: std.fs.File.SeekableStream.SeekFrom) !u64 {
        const new_pos: u64 = switch (whence) {
            .start => blk: {
                if (offset < 0) return error.InvalidOffset;
                break :blk @intCast(offset);
            },
            .current => blk: {
                const current: i64 = @intCast(self.position);
                const result = current + offset;
                if (result < 0) return error.InvalidOffset;
                break :blk @intCast(result);
            },
            .end => {
                // Seeking from end requires getting file size, which we don't support yet
                return error.Unsupported;
            },
        };
        self.position = new_pos;
        return new_pos;
    }

    pub fn pread(self: *File, rt: *Runtime, buffer: []u8, offset: u64) !usize {
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

    pub fn pwrite(self: *File, rt: *Runtime, data: []const u8, offset: u64) !usize {
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
    pub fn readVec(self: *File, rt: *Runtime, slices: [][]u8) (Cancelable || std.Io.Reader.Error)!usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, aio.ReadBuf.fromSlices(slices, &storage), self.position);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const bytes_read = op.getResult() catch return error.ReadFailed;

        // EOF is indicated by 0 bytes read
        if (bytes_read == 0) return error.EndOfStream;

        self.position += bytes_read;
        return bytes_read;
    }

    /// Write to file from multiple slices (vectored write).
    /// Returns std.Io.Writer compatible errors.
    pub fn writeVec(self: *File, rt: *Runtime, slices: []const []const u8) (Cancelable || std.Io.Writer.Error)!usize {
        const task = rt.getCurrentTask() orelse @panic("no active task");
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec_const = undefined;
        var op = aio.FileWrite.init(self.fd, aio.WriteBuf.fromSlices(slices, &storage), self.position);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        const bytes_written = op.getResult() catch return error.WriteFailed;
        self.position += bytes_written;
        return bytes_written;
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
