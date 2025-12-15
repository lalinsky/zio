// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const aio = @import("aio");
const Runtime = @import("../runtime.zig").Runtime;
const Cancelable = @import("../common.zig").Cancelable;
const waitForIo = @import("../io.zig").waitForIo;
const genericCallback = @import("../io.zig").genericCallback;
const fillBuf = @import("../io.zig").fillBuf;

const Handle = std.fs.File.Handle;

pub const File = struct {
    fd: Handle,

    pub const ReadError = aio.system.fs.FileReadError || Cancelable;
    pub const WriteError = aio.system.fs.FileWriteError || Cancelable;

    pub fn fromFd(fd: Handle) File {
        return .{ .fd = fd };
    }

    pub fn read(self: File, rt: *Runtime, buffer: []u8, offset: u64) ReadError!usize {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var storage: [1]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, .fromSlice(buffer, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    pub fn write(self: File, rt: *Runtime, data: []const u8, offset: u64) WriteError!usize {
        const task = rt.getCurrentTask();
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
    pub fn readVec(self: File, rt: *Runtime, slices: [][]u8, offset: u64) ReadError!usize {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec = undefined;
        var op = aio.FileRead.init(self.fd, aio.ReadBuf.fromSlices(slices, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    /// Write to file from multiple slices (vectored write).
    pub fn writeVec(self: File, rt: *Runtime, slices: []const []const u8, offset: u64) WriteError!usize {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var storage: [16]aio.system.iovec_const = undefined;
        var op = aio.FileWrite.init(self.fd, aio.WriteBuf.fromSlices(slices, &storage), offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    /// Read from file using ReadBuf (direct iovec access).
    pub fn readBuf(self: File, rt: *Runtime, buf: aio.ReadBuf, offset: u64) ReadError!usize {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var op = aio.FileRead.init(self.fd, buf, offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    /// Write to file using WriteBuf (direct iovec access).
    pub fn writeBuf(self: File, rt: *Runtime, buf: aio.WriteBuf, offset: u64) WriteError!usize {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var op = aio.FileWrite.init(self.fd, buf, offset);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    pub fn close(self: File, rt: *Runtime) void {
        const task = rt.getCurrentTask();
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

    pub const StatError = aio.system.fs.FileStatError || Cancelable;

    pub fn stat(self: File, rt: *Runtime) StatError!aio.system.fs.FileStatInfo {
        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        var op = aio.FileStat.init(self.fd, null);
        op.c.userdata = task;
        op.c.callback = genericCallback;

        executor.loop.add(&op.c);
        try waitForIo(rt, &op.c);

        return try op.getResult();
    }

    pub fn reader(self: File, rt: *Runtime, buffer: []u8) FileReader {
        return FileReader.init(self, rt, buffer);
    }

    pub fn writer(self: File, rt: *Runtime, buffer: []u8) FileWriter {
        return FileWriter.init(self, rt, buffer);
    }
};

/// File reader that tracks position and implements std.Io.Reader interface
pub const FileReader = struct {
    file: File,
    runtime: *Runtime,
    position: u64 = 0,
    err: ?File.ReadError = null,
    interface: std.Io.Reader,

    pub fn init(file: File, runtime: *Runtime, buffer: []u8) FileReader {
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

    pub fn logicalPos(self: *const FileReader) u64 {
        return self.position - self.interface.end + self.interface.seek;
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *FileReader = @fieldParentPtr("interface", io_reader);
        const dest = limit.slice(try w.writableSliceGreedy(1));

        const n = r.file.read(r.runtime, dest, r.position) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;

        r.position += n;
        w.advance(n);
        return n;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *FileReader = @fieldParentPtr("interface", io_reader);
        const to_discard = @intFromEnum(limit);

        // Nothing to discard
        if (to_discard == 0) return 0;

        // For physical files, we can just seek forward
        r.position += to_discard;

        // Verify we didn't seek past EOF by reading 2 bytes:
        // - 1 byte at position-1 (last byte we claim to have discarded)
        // - 1 byte at position (to verify there's more data or we're exactly at EOF)
        var buf: [2]u8 = undefined;
        const n = r.file.read(r.runtime, &buf, r.position - 1) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        // If we couldn't read even 1 byte, we went past EOF
        if (n == 0) return error.EndOfStream;

        return to_discard;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *FileReader = @fieldParentPtr("interface", io_reader);

        const max_vecs = 1 + switch (builtin.os.tag) {
            .windows => 1,
            else => 16,
        };
        var iovec_storage: [max_vecs]aio.system.iovec = undefined;
        const dest_n, const data_size = if (builtin.os.tag == .windows)
            try io_reader.writableVectorWsa(&iovec_storage, data)
        else
            try io_reader.writableVectorPosix(&iovec_storage, data);
        if (dest_n == 0) return 0;

        const buf = aio.ReadBuf{ .iovecs = iovec_storage[0..dest_n] };
        const n = r.file.readBuf(r.runtime, buf, r.position) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;

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
    file: File,
    runtime: *Runtime,
    position: u64 = 0,
    err: ?File.WriteError = null,
    interface: std.Io.Writer,

    pub fn init(file: File, runtime: *Runtime, buffer: []u8) FileWriter {
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

    pub fn logicalPos(self: *const FileWriter) u64 {
        return self.position + self.interface.end;
    }

    fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *FileWriter = @fieldParentPtr("interface", io_writer);
        const buffered = io_writer.buffered();

        const max_vecs = switch (builtin.os.tag) {
            .windows => 1,
            else => 16,
        };

        var splat_buf: [64]u8 = undefined;
        var slices: [max_vecs][]const u8 = undefined;
        const buf_len = fillBuf(&slices, buffered, data, splat, &splat_buf);

        if (buf_len == 0) return 0;

        const n = w.file.writeVec(w.runtime, slices[0..buf_len], w.position) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };

        w.position += n;
        return io_writer.consume(n);
    }

    fn flush(io_writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const w: *FileWriter = @fieldParentPtr("interface", io_writer);

        while (io_writer.end > 0) {
            const buffered = io_writer.buffered();
            const n = w.file.write(w.runtime, buffered, w.position) catch |err| {
                w.err = err;
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

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = fs.cwd();
    const file_path = "test_file_basic.txt";
    var zio_file = try dir.createFile(rt, file_path, .{});

    // Write test
    const write_data = "Hello, zio!";
    const bytes_written = try zio_file.write(rt, write_data, 0);
    try std.testing.expectEqual(write_data.len, bytes_written);

    // Close file before reopening for read
    zio_file.close(rt);

    // Read test - reopen the file for reading
    var read_file = try dir.openFile(rt, file_path, .{ .mode = .read_only });

    var buffer: [100]u8 = undefined;
    const bytes_read = try read_file.read(rt, &buffer, 0);
    try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
    read_file.close(rt);

    try dir.deleteFile(rt, file_path);
}

test "File: positional read and write" {
    const fs = @import("../fs.zig");

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

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

test "File: close operation" {
    const fs = @import("../fs.zig");

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

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

test "File: reader and writer interface" {
    const fs = @import("../fs.zig");

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = fs.cwd();
    const file_path = "test_file_rw_interface.txt";

    // Write using writer interface
    {
        var file = try dir.createFile(rt, file_path, .{});

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
        var file = try dir.openFile(rt, file_path, .{});

        var read_buffer: [256]u8 = undefined;
        var reader = file.reader(rt, &read_buffer);

        var result: [20]u8 = undefined;
        const bytes_read = try reader.interface.readSliceShort(&result);

        try std.testing.expectEqual(10, bytes_read);
        try std.testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);

        file.close(rt);
    }

    try dir.deleteFile(rt, file_path);
}

/// Positional write from vectored buffers (for std.Io compatibility).
/// Does not update any file position.
pub fn fileWritePositional(rt: *Runtime, fd: Handle, buffers: []const []const u8, offset: u64) !usize {
    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    var storage: [16]aio.system.iovec_const = undefined;
    var op = aio.FileWrite.init(fd, aio.WriteBuf.fromSlices(buffers, &storage), offset);
    op.c.userdata = task;
    op.c.callback = genericCallback;

    executor.loop.add(&op.c);
    try waitForIo(rt, &op.c);

    return try op.getResult();
}

/// Positional read into vectored buffers (for std.Io compatibility).
/// Does not update any file position.
pub fn fileReadPositional(rt: *Runtime, fd: Handle, buffers: [][]u8, offset: u64) !usize {
    const task = rt.getCurrentTask();
    const executor = task.getExecutor();

    var storage: [16]aio.system.iovec = undefined;
    var op = aio.FileRead.init(fd, aio.ReadBuf.fromSlices(buffers, &storage), offset);
    op.c.userdata = task;
    op.c.callback = genericCallback;

    executor.loop.add(&op.c);
    try waitForIo(rt, &op.c);

    return try op.getResult();
}
