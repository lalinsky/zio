const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const io = @import("io.zig");
const Runtime = @import("runtime.zig").Runtime;
const Waiter = @import("runtime.zig").Waiter;

pub const File = struct {
    xev_file: xev.File,
    runtime: *Runtime,
    /// File position for sequential read/write operations.
    /// On Windows with overlapped I/O, we track this ourselves since the OS doesn't.
    /// Starts at 0, matching POSIX behavior for newly opened files.
    position: u64 = 0,

    pub fn init(runtime: *Runtime, std_file: std.fs.File) !File {
        return File{
            .xev_file = try xev.File.init(std_file),
            .runtime = runtime,
        };
    }

    pub fn initFd(runtime: *Runtime, fd: std.fs.File.Handle) File {
        return File{
            .xev_file = xev.File.initFd(fd),
            .runtime = runtime,
        };
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ReadError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                file: xev.File,
                buffer_inner: xev.ReadBuffer,
                result: xev.ReadError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = file;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        // Use pread with tracked position for cross-platform compatibility
        self.xev_file.pread(
            &self.runtime.loop,
            &completion,
            .{ .slice = buffer },
            self.position,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.runtime.yield(.waiting);

        const bytes_read = try result_data.result;
        self.position += bytes_read;
        return bytes_read;
    }

    pub fn write(self: *File, data: []const u8) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.WriteError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                file: xev.File,
                buffer_inner: xev.WriteBuffer,
                result: xev.WriteError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = file;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        // Use pwrite with tracked position for cross-platform compatibility
        self.xev_file.pwrite(
            &self.runtime.loop,
            &completion,
            .{ .slice = data },
            self.position,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.runtime.yield(.waiting);

        const bytes_written = try result_data.result;
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

    pub fn pread(self: *File, buffer: []u8, offset: u64) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.ReadError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                file: xev.File,
                buffer_inner: xev.ReadBuffer,
                result: xev.ReadError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = file;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_file.pread(
            &self.runtime.loop,
            &completion,
            .{ .slice = buffer },
            offset,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.runtime.yield(.waiting);

        return result_data.result;
    }

    pub fn pwrite(self: *File, data: []const u8, offset: u64) !usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.WriteError!usize = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                file: xev.File,
                buffer_inner: xev.WriteBuffer,
                result: xev.WriteError!usize,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = file;
                _ = buffer_inner;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_file.pwrite(
            &self.runtime.loop,
            &completion,
            .{ .slice = data },
            offset,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.runtime.yield(.waiting);

        return result_data.result;
    }

    /// Low-level read function that accepts xev.ReadBuffer directly.
    /// Returns std.io.Reader compatible errors.
    pub fn readBuf(self: *File, buffer: *xev.ReadBuffer) std.io.Reader.Error!usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            buffer: *xev.ReadBuffer,
            result: xev.ReadError!usize = undefined,
        };
        var result_data: Result = .{ .waiter = waiter, .buffer = buffer };

        // Use pread with tracked position for cross-platform compatibility
        self.xev_file.pread(
            &self.runtime.loop,
            &completion,
            buffer.*,
            self.position,
            Result,
            &result_data,
            (struct {
                fn callback(
                    result_ptr: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.File,
                    buf: xev.ReadBuffer,
                    result: xev.ReadError!usize,
                ) xev.CallbackAction {
                    const r = result_ptr.?;
                    r.result = result;
                    // Copy array data back to caller's buffer
                    if (buf == .array) {
                        r.buffer.array = buf.array;
                    }
                    r.waiter.markReady();
                    return .disarm;
                }
            }).callback,
        );

        waiter.runtime.yield(.waiting);

        const bytes_read = result_data.result catch |err| switch (err) {
            error.EOF => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        self.position += bytes_read;
        return bytes_read;
    }

    /// Low-level write function that accepts xev.WriteBuffer directly.
    /// Returns std.io.Writer compatible errors.
    pub fn writeBuf(self: *File, buffer: xev.WriteBuffer) std.io.Writer.Error!usize {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.WriteError!usize = undefined,
        };
        var result_data: Result = .{ .waiter = waiter };

        // Use pwrite with tracked position for cross-platform compatibility
        self.xev_file.pwrite(
            &self.runtime.loop,
            &completion,
            buffer,
            self.position,
            Result,
            &result_data,
            (struct {
                fn callback(
                    result_ptr: ?*Result,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: xev.File,
                    _: xev.WriteBuffer,
                    result: xev.WriteError!usize,
                ) xev.CallbackAction {
                    result_ptr.?.result = result;
                    result_ptr.?.waiter.markReady();
                    return .disarm;
                }
            }).callback,
        );

        waiter.runtime.yield(.waiting);

        const bytes_written = result_data.result catch return error.WriteFailed;
        self.position += bytes_written;
        return bytes_written;
    }

    pub fn close(self: *File) !void {
        var waiter = self.runtime.getWaiter();
        var completion: xev.Completion = undefined;

        const Result = struct {
            waiter: Waiter,
            result: xev.CloseError!void = undefined,

            pub fn callback(
                result_data_ptr: ?*@This(),
                loop: *xev.Loop,
                completion_inner: *xev.Completion,
                file: xev.File,
                result: xev.CloseError!void,
            ) xev.CallbackAction {
                _ = loop;
                _ = completion_inner;
                _ = file;

                const result_data = result_data_ptr.?;
                result_data.result = result;
                result_data.waiter.markReady();

                return .disarm;
            }
        };

        var result_data: Result = .{ .waiter = waiter };

        self.xev_file.close(
            &self.runtime.loop,
            &completion,
            Result,
            &result_data,
            Result.callback,
        );

        waiter.runtime.yield(.waiting);

        return result_data.result;
    }

    // Zig 0.15+ streaming interface
    pub const Reader = io.StreamReader(File);
    pub const Writer = io.StreamWriter(File);

    pub fn reader(self: *File, buffer: []u8) Reader {
        return Reader.init(self, buffer);
    }

    pub fn writer(self: *File, buffer: []u8) Writer {
        return Writer.init(self, buffer);
    }

    pub fn deinit(self: *const File) void {
        self.xev_file.deinit();
    }
};

test "File: basic read and write" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const fs = @import("fs.zig");

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            std.log.info("TestTask: Starting file test", .{});

            // Create a test file using the new fs module
            const file_path = "test_file_basic.txt";
            var zio_file = try fs.createFile(rt, file_path, .{});
            defer zio_file.deinit();
            defer std.fs.cwd().deleteFile(file_path) catch {};
            std.log.info("TestTask: Created file using fs module", .{});

            // Write test
            const write_data = "Hello, zio!";
            std.log.info("TestTask: About to write data", .{});
            const bytes_written = try zio_file.write(write_data);
            std.log.info("TestTask: Wrote {} bytes", .{bytes_written});
            try testing.expectEqual(write_data.len, bytes_written);

            // Close file before reopening for read
            try zio_file.close();
            std.log.info("TestTask: Closed file after write", .{});

            // Read test - reopen the file for reading
            var read_file = try fs.openFile(rt, file_path, .{ .mode = .read_only });
            defer read_file.deinit();
            defer read_file.close() catch |err| {
                std.log.warn("Failed to close read file: {}", .{err});
            };
            std.log.info("TestTask: Reopened file for reading", .{});

            var buffer: [100]u8 = undefined;
            const bytes_read = try read_file.read(&buffer);
            std.log.info("TestTask: Read {} bytes", .{bytes_read});
            try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            std.log.info("TestTask: File test completed successfully", .{});
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{&runtime}, .{});
}

test "File: positional read and write" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const fs = @import("fs.zig");

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const file_path = "test_file_positional.txt";
            var zio_file = try fs.createFile(rt, file_path, .{ .read = true });
            defer zio_file.deinit();
            defer zio_file.close() catch |err| {
                std.log.warn("Failed to close positional test file: {}", .{err});
            };
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write at different positions
            try testing.expectEqual(5, try zio_file.pwrite("HELLO", 0));
            try testing.expectEqual(5, try zio_file.pwrite("WORLD", 10));

            // Read from positions
            var buf: [5]u8 = undefined;
            try testing.expectEqual(5, try zio_file.pread(&buf, 0));
            try testing.expectEqualStrings("HELLO", &buf);

            try testing.expectEqual(5, try zio_file.pread(&buf, 10));
            try testing.expectEqualStrings("WORLD", &buf);

            // Test reading from gap (should be zeros or random data)
            var gap_buf: [3]u8 = undefined;
            try testing.expectEqual(3, try zio_file.pread(&gap_buf, 5));
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{&runtime}, .{});
}

test "File: close operation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const fs = @import("fs.zig");

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const file_path = "test_file_close.txt";
            var zio_file = try fs.createFile(rt, file_path, .{});
            defer zio_file.deinit();
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write some data
            const bytes_written = try zio_file.write("test data");
            try testing.expectEqual(9, bytes_written);

            // Close the file using zio
            try zio_file.close();

            // File should now be closed
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{&runtime}, .{});
}

test "File: reader and writer interface" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const fs = @import("fs.zig");

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            const file_path = "test_file_rw_interface.txt";
            defer std.fs.cwd().deleteFile(file_path) catch {};

            // Write using writer interface
            {
                var file = try fs.createFile(rt, file_path, .{});
                defer file.deinit();

                var write_buffer: [256]u8 = undefined;
                var writer = file.writer(&write_buffer);

                // Test writeSplatAll with single-character pattern
                var data = [_][]const u8{"x"};
                try writer.interface.writeSplatAll(&data, 10);
                try writer.interface.flush();

                try file.close();
            }

            // Read using reader interface
            {
                var file = try fs.openFile(rt, file_path, .{});
                defer file.deinit();

                var read_buffer: [256]u8 = undefined;
                var reader = file.reader(&read_buffer);

                var result: [20]u8 = undefined;
                const bytes_read = try reader.interface.readSliceShort(&result);

                try testing.expectEqual(10, bytes_read);
                try testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);

                try file.close();
            }
        }
    };

    try runtime.runUntilComplete(TestTask.run, .{&runtime}, .{});
}
