const std = @import("std");
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

        self.xev_file.write(
            &self.runtime.loop,
            &completion,
            .{ .slice = data },
            Result,
            &result_data,
            Result.callback,
        );

        waiter.waitForReady();

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
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const TestTask = struct {
        fn run(rt: *Runtime) !void {
            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();

            const file = try tmp_dir.dir.createFile("test.txt", .{ .read = true });
            defer file.close();

            var zio_file = try File.init(rt, file);
            defer zio_file.deinit();

            // Write test
            const write_data = "Hello, zio!";
            const bytes_written = try zio_file.write(write_data);
            try testing.expect(bytes_written == write_data.len);

            // Read test - seek back to beginning first
            try file.seekTo(0);
            var buffer: [100]u8 = undefined;
            const bytes_read = try zio_file.read(&buffer);
            try testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
        }
    };

    const task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    // Clean API to check task result
    try task.result();
}

test "File: positional read and write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
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
            try testing.expect(5 == try zio_file.pwrite("HELLO", 0));
            try testing.expect(5 == try zio_file.pwrite("WORLD", 10));

            // Read from positions
            var buf: [5]u8 = undefined;
            try testing.expect(5 == try zio_file.pread(&buf, 0));
            try testing.expectEqualStrings("HELLO", &buf);

            try testing.expect(5 == try zio_file.pread(&buf, 10));
            try testing.expectEqualStrings("WORLD", &buf);

            // Test reading from gap (should be zeros or random data)
            var gap_buf: [3]u8 = undefined;
            try testing.expect(3 == try zio_file.pread(&gap_buf, 5));
        }
    };

    const task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    try task.result();
}

test "File: close operation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator);
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
            try testing.expect(bytes_written == 9);

            // Close the file using zio
            try zio_file.close();

            // File should now be closed
        }
    };

    const task = try runtime.spawn(TestTask.run, .{&runtime}, .{});
    defer task.deinit();

    try runtime.run();

    try task.result();
}