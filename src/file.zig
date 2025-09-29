const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Waiter = @import("runtime.zig").Waiter;

pub const File = struct {
    xev_file: xev.File,
    runtime: *Runtime,

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

        self.xev_file.read(
            &self.runtime.loop,
            &completion,
            .{ .slice = buffer },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

        return result_data.result;
    }

    pub fn write(self: *File, data: []const u8) !usize {
        std.log.info("File.write: Starting write of {} bytes", .{data.len});
        var waiter = self.runtime.getWaiter();
        std.log.info("File.write: Got waiter", .{});
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

        std.log.info("File.write: About to call xev_file.write", .{});
        self.xev_file.write(
            &self.runtime.loop,
            &completion,
            .{ .slice = data },
            Result,
            &result_data,
            Result.callback,
        );

        std.log.info("File.write: Called xev_file.write, now waiting for ready", .{});
        waiter.waitForReady();

        std.log.info("File.write: Wait completed, returning result", .{});
        return result_data.result;
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

        waiter.waitForReady();

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

        waiter.waitForReady();

        return result_data.result;
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

        waiter.waitForReady();

        return result_data.result;
    }

    pub fn deinit(self: *const File) void {
        self.xev_file.deinit();
    }
};

test "File: basic read and write" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            std.log.info("TestTask: Starting file test", .{});

            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();
            std.log.info("TestTask: Created tmp dir", .{});

            const file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
            defer file.close();
            std.log.info("TestTask: Created file", .{});

            var zio_file = try File.init(rt, file);
            defer zio_file.deinit();
            std.log.info("TestTask: Initialized zio file", .{});

            // Write test
            const write_data = "Hello, zio!";
            std.log.info("TestTask: About to write data", .{});
            const bytes_written = try zio_file.write(write_data);
            std.log.info("TestTask: Wrote {} bytes", .{bytes_written});
            try testing.expectEqual(write_data.len, bytes_written);

            // Read test - seek back to beginning first
            std.log.info("TestTask: About to seek to beginning", .{});
            try file.seekTo(0);
            std.log.info("TestTask: About to read data", .{});
            var buffer: [100]u8 = undefined;
            const bytes_read = try zio_file.read(&buffer);
            std.log.info("TestTask: Read {} bytes", .{bytes_read});
            try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
            std.log.info("TestTask: File test completed successfully", .{});
        }
    };

    var task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    // Clean API to check task result
    try task.result();
}

test "File: positional read and write" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
            defer file.close();

            var zio_file = try File.init(rt, file);
            defer zio_file.deinit();

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

    var task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    try task.result();
}

test "File: close operation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
            // Don't defer file.close() here since we're testing zio_file.close()

            var zio_file = try File.init(rt, file);
            defer zio_file.deinit();

            // Write some data
            const bytes_written = try zio_file.write("test data");
            try testing.expectEqual(9, bytes_written);

            // Close the file using zio
            try zio_file.close();

            // File should now be closed
        }
    };

    var task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    try task.result();
}
