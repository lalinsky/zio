// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const ev = @import("ev/root.zig");
const os = @import("os/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const waitForIo = @import("common.zig").waitForIo;
const timedWaitForIo = @import("common.zig").timedWaitForIo;
const fillBuf = @import("utils/writer.zig").fillBuf;
const Timeout = @import("time.zig").Timeout;

pub const Handle = os.fs.fd_t;

pub const max_vecs = switch (builtin.os.tag) {
    .windows => 1,
    else => 16,
};

pub fn openDir(rt: *Runtime, path: []const u8) Dir.OpenDirError!Dir {
    const cwd = Dir.cwd();
    return cwd.openDir(rt, path, .{});
}

pub fn openFile(rt: *Runtime, path: []const u8) Dir.OpenFileError!File {
    const cwd = Dir.cwd();
    return cwd.openFile(rt, path, .{});
}

pub fn deleteDir(rt: *Runtime, path: []const u8) Dir.DeleteDirError!void {
    const cwd = Dir.cwd();
    return cwd.deleteDir(rt, path);
}

pub fn deleteFile(rt: *Runtime, path: []const u8) Dir.DeleteFileError!void {
    const cwd = Dir.cwd();
    return cwd.deleteFile(rt, path);
}

pub fn rename(rt: *Runtime, old_path: []const u8, new_path: []const u8) Dir.RenameError!void {
    const cwd = Dir.cwd();
    return cwd.rename(rt, old_path, cwd, new_path);
}

pub fn createDir(rt: *Runtime, path: []const u8, mode: os.fs.mode_t) Dir.CreateDirError!void {
    const cwd = Dir.cwd();
    return cwd.createDir(rt, path, mode);
}

pub fn createFile(rt: *Runtime, path: []const u8, flags: os.fs.FileCreateFlags) Dir.CreateFileError!File {
    const cwd = Dir.cwd();
    return cwd.createFile(rt, path, flags);
}

pub fn createPipe(rt: *Runtime) (os.fs.PipeError || Cancelable)!PipePair {
    var op = ev.PipeCreate.init();
    try waitForIo(rt, &op.c);
    const fds = try op.getResult();
    return .{
        .read = Pipe.fromFd(fds[0]),
        .write = Pipe.fromFd(fds[1]),
    };
}

// Global state to track if stdio fds have been set to non-blocking mode
// TODO: This should be handled more generically by the backend
var stdio_nonblocking_mutex: std.Thread.Mutex = .{};
var stdio_nonblocking = [3]bool{ false, false, false };

pub fn stdin() Pipe {
    const fd = os.fs.stdin();
    // Only set non-blocking for backends that require it
    if (ev.backend != .io_uring and ev.backend != .iocp) {
        stdio_nonblocking_mutex.lock();
        defer stdio_nonblocking_mutex.unlock();
        if (!stdio_nonblocking[0]) {
            os.posix.setNonblocking(fd) catch {};
            stdio_nonblocking[0] = true;
        }
    }
    return Pipe.fromFd(fd);
}

pub fn stdout() Pipe {
    const fd = os.fs.stdout();
    // Only set non-blocking for backends that require it
    if (ev.backend != .io_uring and ev.backend != .iocp) {
        stdio_nonblocking_mutex.lock();
        defer stdio_nonblocking_mutex.unlock();
        if (!stdio_nonblocking[1]) {
            os.posix.setNonblocking(fd) catch {};
            stdio_nonblocking[1] = true;
        }
    }
    return Pipe.fromFd(fd);
}

pub fn stderr() Pipe {
    const fd = os.fs.stderr();
    // Only set non-blocking for backends that require it
    if (ev.backend != .io_uring and ev.backend != .iocp) {
        stdio_nonblocking_mutex.lock();
        defer stdio_nonblocking_mutex.unlock();
        if (!stdio_nonblocking[2]) {
            os.posix.setNonblocking(fd) catch {};
            stdio_nonblocking[2] = true;
        }
    }
    return Pipe.fromFd(fd);
}

pub fn stat(rt: *Runtime, path: []const u8) Dir.StatError!os.fs.FileStatInfo {
    const cwd = Dir.cwd();
    return cwd.statPath(rt, path);
}

pub fn access(rt: *Runtime, path: []const u8, flags: os.fs.AccessFlags) Dir.AccessError!void {
    const cwd = Dir.cwd();
    return cwd.access(rt, path, flags);
}

pub const Dir = struct {
    fd: Handle,

    pub fn cwd() Dir {
        return .{ .fd = os.fs.cwd() };
    }

    pub fn close(self: Dir, rt: *Runtime) void {
        var op = ev.DirClose.init(self.fd);
        rt.beginShield();
        defer rt.endShield();
        waitForIo(rt, &op.c) catch unreachable;
        _ = op.getResult() catch {};
    }

    pub const OpenDirError = os.fs.DirOpenError || Cancelable;

    pub fn openDir(self: Dir, rt: *Runtime, path: []const u8, flags: os.fs.DirOpenFlags) OpenDirError!Dir {
        var op = ev.DirOpen.init(self.fd, path, flags);
        try waitForIo(rt, &op.c);
        return .{ .fd = try op.getResult() };
    }

    pub const OpenFileError = os.fs.FileOpenError || Cancelable;

    pub fn openFile(self: Dir, rt: *Runtime, path: []const u8, flags: os.fs.FileOpenFlags) OpenFileError!File {
        var op = ev.FileOpen.init(self.fd, path, flags);
        try waitForIo(rt, &op.c);
        return .fromFd(try op.getResult());
    }

    pub const CreateDirError = os.fs.DirCreateDirError || Cancelable;

    pub fn createDir(self: Dir, rt: *Runtime, path: []const u8, mode: os.fs.mode_t) CreateDirError!void {
        var op = ev.DirCreateDir.init(self.fd, path, mode);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const CreateFileError = os.fs.FileCreateError || Cancelable;

    pub fn createFile(self: Dir, rt: *Runtime, path: []const u8, flags: os.fs.FileCreateFlags) CreateFileError!File {
        var op = ev.FileCreate.init(self.fd, path, flags);
        try waitForIo(rt, &op.c);
        return .fromFd(try op.getResult());
    }

    pub const DeleteDirError = os.fs.DirDeleteDirError || Cancelable;

    pub fn deleteDir(self: Dir, rt: *Runtime, path: []const u8) DeleteDirError!void {
        var op = ev.DirDeleteDir.init(self.fd, path);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const DeleteFileError = os.fs.DirDeleteFileError || Cancelable;

    pub fn deleteFile(self: Dir, rt: *Runtime, path: []const u8) DeleteFileError!void {
        var op = ev.DirDeleteFile.init(self.fd, path);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const RenameError = os.fs.DirRenameError || Cancelable;

    pub fn rename(self: Dir, rt: *Runtime, old_path: []const u8, new_dir: Dir, new_path: []const u8) RenameError!void {
        var op = ev.DirRename.init(self.fd, old_path, new_dir.fd, new_path);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const StatError = os.fs.FileStatError || Cancelable;

    pub fn stat(self: Dir, rt: *Runtime) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, null);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    pub fn statPath(self: Dir, rt: *Runtime, path: []const u8) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, path);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    pub const SetPermissionsError = os.fs.FileSetPermissionsError || Cancelable;

    pub fn setPermissions(self: Dir, rt: *Runtime, mode: os.fs.mode_t) SetPermissionsError!void {
        var op = ev.DirSetPermissions.init(self.fd, mode);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SetOwnerError = os.fs.FileSetOwnerError || Cancelable;

    pub fn setOwner(self: Dir, rt: *Runtime, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t) SetOwnerError!void {
        var op = ev.DirSetOwner.init(self.fd, uid, gid);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub fn setFilePermissions(self: Dir, rt: *Runtime, path: []const u8, mode: os.fs.mode_t, flags: os.fs.PathSetFlags) SetPermissionsError!void {
        var op = ev.DirSetFilePermissions.init(self.fd, path, mode, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub fn setFileOwner(self: Dir, rt: *Runtime, path: []const u8, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t, flags: os.fs.PathSetFlags) SetOwnerError!void {
        var op = ev.DirSetFileOwner.init(self.fd, path, uid, gid, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SetTimestampsError = os.fs.FileSetTimestampsError || Cancelable;

    pub fn setFileTimestamps(self: Dir, rt: *Runtime, path: []const u8, timestamps: os.fs.FileTimestamps, flags: os.fs.PathSetFlags) SetTimestampsError!void {
        var op = ev.DirSetFileTimestamps.init(self.fd, path, timestamps, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const ReadLinkError = os.fs.ReadLinkError || Cancelable;

    pub fn readLink(self: Dir, rt: *Runtime, path: []const u8, buffer: []u8) ReadLinkError![]u8 {
        var op = ev.DirReadLink.init(self.fd, path, buffer);
        try waitForIo(rt, &op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }

    pub const SymLinkError = os.fs.SymLinkError || Cancelable;

    pub fn symLink(self: Dir, rt: *Runtime, target: []const u8, link_path: []const u8, flags: os.fs.SymLinkFlags) SymLinkError!void {
        var op = ev.DirSymLink.init(self.fd, target, link_path, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const HardLinkError = os.fs.HardLinkError || Cancelable;

    pub fn hardLink(self: Dir, rt: *Runtime, old_path: []const u8, new_dir: Dir, new_path: []const u8, flags: os.fs.HardLinkFlags) HardLinkError!void {
        var op = ev.DirHardLink.init(self.fd, old_path, new_dir.fd, new_path, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const AccessError = os.fs.DirAccessError || Cancelable;

    pub fn access(self: Dir, rt: *Runtime, path: []const u8, flags: os.fs.AccessFlags) AccessError!void {
        var op = ev.DirAccess.init(self.fd, path, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const RealPathError = os.fs.DirRealPathError || Cancelable;

    pub fn realPath(self: Dir, rt: *Runtime, buffer: []u8) RealPathError![]u8 {
        var op = ev.DirRealPath.init(self.fd, buffer);
        try waitForIo(rt, &op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }

    pub const RealPathFileError = os.fs.DirRealPathFileError || Cancelable;

    pub fn realPathFile(self: Dir, rt: *Runtime, path: []const u8, buffer: []u8) RealPathFileError![]u8 {
        var op = ev.DirRealPathFile.init(self.fd, path, buffer);
        try waitForIo(rt, &op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }
};

pub const File = struct {
    fd: Handle,

    pub const ReadError = os.fs.FileReadError || Cancelable;
    pub const WriteError = os.fs.FileWriteError || Cancelable;

    pub fn fromFd(fd: Handle) File {
        return .{ .fd = fd };
    }

    /// Read from file into a single slice.
    pub fn read(self: File, rt: *Runtime, buffer: []u8, offset: u64) ReadError!usize {
        var storage: [1]os.iovec = undefined;
        var op = ev.FileRead.init(self.fd, .fromSlice(buffer, &storage), offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    /// Write to file from a single slice.
    pub fn write(self: File, rt: *Runtime, data: []const u8, offset: u64) WriteError!usize {
        var storage: [1]os.iovec_const = undefined;
        var op = ev.FileWrite.init(self.fd, .fromSlice(data, &storage), offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    /// Read from file into multiple slices (vectored read).
    pub fn readVec(self: File, rt: *Runtime, slices: []const []u8, offset: u64) ReadError!usize {
        var storage: [max_vecs]os.iovec = undefined;
        var op = ev.FileRead.init(self.fd, ev.ReadBuf.fromSlices(slices, &storage), offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    /// Write to file from multiple slices (vectored write).
    pub fn writeVec(self: File, rt: *Runtime, slices: []const []const u8, offset: u64) WriteError!usize {
        var storage: [max_vecs]os.iovec_const = undefined;
        var op = ev.FileWrite.init(self.fd, ev.WriteBuf.fromSlices(slices, &storage), offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    /// Read from file using ReadBuf (vectored read).
    pub fn readBuf(self: File, rt: *Runtime, buf: ev.ReadBuf, offset: u64) ReadError!usize {
        var op = ev.FileRead.init(self.fd, buf, offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    /// Write to file using WriteBuf (vectored write).
    pub fn writeBuf(self: File, rt: *Runtime, buf: ev.WriteBuf, offset: u64) WriteError!usize {
        var op = ev.FileWrite.init(self.fd, buf, offset);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    pub fn close(self: File, rt: *Runtime) void {
        var op = ev.FileClose.init(self.fd);
        rt.beginShield();
        defer rt.endShield();
        waitForIo(rt, &op.c) catch unreachable;
        _ = op.getResult() catch {};
    }

    pub const StatError = os.fs.FileStatError || Cancelable;

    pub fn stat(self: File, rt: *Runtime) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, null);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    pub const SyncError = os.fs.FileSyncError || Cancelable;

    pub fn sync(self: File, rt: *Runtime, flags: os.fs.FileSyncFlags) SyncError!void {
        var op = ev.FileSync.init(self.fd, flags);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SetSizeError = os.fs.FileSetSizeError || Cancelable;

    pub fn setSize(self: File, rt: *Runtime, length: u64) SetSizeError!void {
        var op = ev.FileSetSize.init(self.fd, length);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SizeError = os.fs.FileSizeError || Cancelable;

    pub fn size(self: File, rt: *Runtime) SizeError!u64 {
        var op = ev.FileSize.init(self.fd);
        try waitForIo(rt, &op.c);
        return try op.getResult();
    }

    pub const SetPermissionsError = os.fs.FileSetPermissionsError || Cancelable;

    pub fn setPermissions(self: File, rt: *Runtime, mode: os.fs.mode_t) SetPermissionsError!void {
        var op = ev.FileSetPermissions.init(self.fd, mode);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SetOwnerError = os.fs.FileSetOwnerError || Cancelable;

    pub fn setOwner(self: File, rt: *Runtime, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t) SetOwnerError!void {
        var op = ev.FileSetOwner.init(self.fd, uid, gid);
        try waitForIo(rt, &op.c);
        try op.getResult();
    }

    pub const SetTimestampsError = os.fs.FileSetTimestampsError || Cancelable;

    pub fn setTimestamps(self: File, rt: *Runtime, timestamps: os.fs.FileTimestamps) SetTimestampsError!void {
        var op = ev.FileSetTimestamps.init(self.fd, timestamps);
        try waitForIo(rt, &op.c);
        try op.getResult();
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
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
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
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
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
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));

        var iovec_storage: [1 + max_vecs]os.iovec = undefined;
        const dest_n, const data_size = if (builtin.os.tag == .windows)
            try io_reader.writableVectorWsa(&iovec_storage, data)
        else
            try io_reader.writableVectorPosix(&iovec_storage, data);
        if (dest_n == 0) return 0;

        const buf = ev.ReadBuf{ .iovecs = iovec_storage[0..dest_n] };
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
        const w: *FileWriter = @alignCast(@fieldParentPtr("interface", io_writer));
        const buffered = io_writer.buffered();

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
        const w: *FileWriter = @alignCast(@fieldParentPtr("interface", io_writer));

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

pub const PipePair = struct {
    read: Pipe,
    write: Pipe,

    /// Close both ends of the pipe
    pub fn close(self: PipePair, rt: *Runtime) void {
        self.read.close(rt);
        self.write.close(rt);
    }
};

pub const Pipe = struct {
    fd: Handle,

    pub const ReadError = os.fs.FileReadError || Cancelable || Timeoutable;
    pub const WriteError = os.fs.FileWriteError || Cancelable || Timeoutable;
    pub const PollError = os.fs.FileReadError || os.fs.FileWriteError || Cancelable || Timeoutable;
    pub const PollEvent = ev.PipePoll.Event;

    /// Create pipe from existing file descriptor
    pub fn fromFd(fd: Handle) Pipe {
        return .{ .fd = fd };
    }

    /// Read from pipe
    pub fn read(self: Pipe, rt: *Runtime, buffer: []u8, timeout: Timeout) ReadError!usize {
        var storage: [1]os.iovec = undefined;
        return self.readBuf(rt, .fromSlice(buffer, &storage), timeout);
    }

    /// Write to pipe
    pub fn write(self: Pipe, rt: *Runtime, data: []const u8, timeout: Timeout) WriteError!usize {
        var storage: [1]os.iovec_const = undefined;
        return self.writeBuf(rt, .fromSlice(data, &storage), timeout);
    }

    /// Read using ReadBuf (vectored I/O)
    pub fn readBuf(self: Pipe, rt: *Runtime, buf: ev.ReadBuf, timeout: Timeout) ReadError!usize {
        var op = ev.PipeRead.init(self.fd, buf);
        try timedWaitForIo(rt, &op.c, timeout);
        return try op.getResult();
    }

    /// Write using WriteBuf (vectored I/O)
    pub fn writeBuf(self: Pipe, rt: *Runtime, buf: ev.WriteBuf, timeout: Timeout) WriteError!usize {
        var op = ev.PipeWrite.init(self.fd, buf);
        try timedWaitForIo(rt, &op.c, timeout);
        return try op.getResult();
    }

    /// Poll for readiness
    /// Waits until the pipe is ready for the specified event (read or write)
    /// Note: Not supported on Windows (returns error.Unexpected)
    pub fn poll(self: Pipe, rt: *Runtime, event: PollEvent, timeout: Timeout) PollError!void {
        var op = ev.PipePoll.init(self.fd, event);
        try timedWaitForIo(rt, &op.c, timeout);
        return try op.getResult();
    }

    /// Close this end of the pipe
    pub fn close(self: Pipe, rt: *Runtime) void {
        var op = ev.PipeClose.init(self.fd);
        rt.beginShield();
        defer rt.endShield();
        waitForIo(rt, &op.c) catch unreachable;
        _ = op.getResult() catch {};
    }

    /// Get a buffered reader
    pub fn reader(self: Pipe, rt: *Runtime, buffer: []u8) PipeReader {
        return PipeReader.init(self, rt, buffer);
    }

    /// Get a buffered writer
    pub fn writer(self: Pipe, rt: *Runtime, buffer: []u8) PipeWriter {
        return PipeWriter.init(self, rt, buffer);
    }
};

pub const PipeReader = struct {
    pipe: Pipe,
    runtime: *Runtime,
    timeout: Timeout = .none,
    err: ?Pipe.ReadError = null,
    interface: std.Io.Reader,

    pub fn init(pipe: Pipe, runtime: *Runtime, buffer: []u8) PipeReader {
        return .{
            .pipe = pipe,
            .runtime = runtime,
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    pub fn setTimeout(self: *PipeReader, timeout: Timeout) void {
        self.timeout = timeout;
    }

    fn stream(io_reader: *std.Io.Reader, io_writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *PipeReader = @alignCast(@fieldParentPtr("interface", io_reader));
        const dest = limit.slice(try io_writer.writableSliceGreedy(1));

        const n = r.pipe.read(r.runtime, dest, r.timeout) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;

        io_writer.advance(n);
        return n;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *PipeReader = @alignCast(@fieldParentPtr("interface", io_reader));

        var iovec_storage: [1 + max_vecs]os.iovec = undefined;
        const dest_n, const data_size = if (builtin.os.tag == .windows)
            try io_reader.writableVectorWsa(&iovec_storage, data)
        else
            try io_reader.writableVectorPosix(&iovec_storage, data);
        if (dest_n == 0) return 0;

        const buf = ev.ReadBuf{ .iovecs = iovec_storage[0..dest_n] };
        const n = r.pipe.readBuf(r.runtime, buf, r.timeout) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };

        if (n == 0) return error.EndOfStream;

        if (n > data_size) {
            io_reader.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

pub const PipeWriter = struct {
    pipe: Pipe,
    runtime: *Runtime,
    timeout: Timeout = .none,
    err: ?Pipe.WriteError = null,
    interface: std.Io.Writer,

    pub fn init(pipe: Pipe, runtime: *Runtime, buffer: []u8) PipeWriter {
        return .{
            .pipe = pipe,
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

    pub fn setTimeout(self: *PipeWriter, timeout: Timeout) void {
        self.timeout = timeout;
    }

    fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *PipeWriter = @alignCast(@fieldParentPtr("interface", io_writer));
        const buffered = io_writer.buffered();

        var splat_buf: [64]u8 = undefined;
        var slices: [max_vecs][]const u8 = undefined;
        const buf_len = fillBuf(&slices, buffered, data, splat, &splat_buf);

        if (buf_len == 0) return 0;

        var storage: [max_vecs]os.iovec_const = undefined;
        const write_buf = ev.WriteBuf.fromSlices(slices[0..buf_len], &storage);
        const n = w.pipe.writeBuf(w.runtime, write_buf, w.timeout) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };

        return io_writer.consume(n);
    }

    fn flush(io_writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const w: *PipeWriter = @alignCast(@fieldParentPtr("interface", io_writer));

        while (io_writer.end > 0) {
            const buffered = io_writer.buffered();
            const n = w.pipe.write(w.runtime, buffered, w.timeout) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };

            if (n == 0) return error.WriteFailed;

            if (n < buffered.len) {
                std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                io_writer.end -= n;
            } else {
                io_writer.end = 0;
            }
        }
    }
};

const TestFile = struct {
    rt: *Runtime,
    dir: Dir,
    file: File,
    path: []const u8,

    pub fn create(path: []const u8, flags: os.fs.FileCreateFlags) !TestFile {
        const rt = try Runtime.init(std.testing.allocator, .{});
        errdefer rt.deinit();
        const dir = Dir.cwd();
        const file = try dir.createFile(rt, path, flags);
        return .{ .rt = rt, .dir = dir, .file = file, .path = path };
    }

    pub fn deinit(self: *TestFile) void {
        self.file.close(self.rt);
        self.dir.deleteFile(self.rt, self.path) catch {};
        self.rt.deinit();
    }
};

test {
    _ = openDir;
    _ = openFile;
    _ = deleteDir;
    _ = deleteFile;
    _ = rename;
    _ = createDir;
    _ = createFile;
    _ = createPipe;
    _ = stdin;
    _ = stdout;
    _ = stderr;
    _ = stat;
    _ = access;
}

test "File: basic read and write" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
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
    var t = try TestFile.create("test_file_positional.txt", .{ .read = true });
    defer t.deinit();

    // Write at different positions
    try std.testing.expectEqual(5, try t.file.write(t.rt, "HELLO", 0));
    try std.testing.expectEqual(5, try t.file.write(t.rt, "WORLD", 10));

    // Read from positions
    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(5, try t.file.read(t.rt, &buf, 0));
    try std.testing.expectEqualStrings("HELLO", &buf);

    try std.testing.expectEqual(5, try t.file.read(t.rt, &buf, 10));
    try std.testing.expectEqualStrings("WORLD", &buf);

    // Test reading from gap (should be zeros or random data)
    var gap_buf: [3]u8 = undefined;
    try std.testing.expectEqual(3, try t.file.read(t.rt, &gap_buf, 5));
}

test "File: sync operation" {
    var t = try TestFile.create("test_file_sync.txt", .{});
    defer t.deinit();

    // Write some data
    const bytes_written = try t.file.write(t.rt, "test data", 0);
    try std.testing.expectEqual(9, bytes_written);

    // Full sync (fsync)
    try t.file.sync(t.rt, .{});

    // Data-only sync (fdatasync)
    try t.file.sync(t.rt, .{ .only_data = true });
}

test "File: size and setSize" {
    var t = try TestFile.create("test_file_size.txt", .{ .read = true });
    defer t.deinit();

    // Write some data
    try std.testing.expectEqual(10, try t.file.write(t.rt, "0123456789", 0));

    // Check size
    try std.testing.expectEqual(10, try t.file.size(t.rt));

    // Truncate
    try t.file.setSize(t.rt, 5);
    try std.testing.expectEqual(5, try t.file.size(t.rt));

    // Verify content
    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(5, try t.file.read(t.rt, &buf, 0));
    try std.testing.expectEqualStrings("01234", buf[0..5]);

    // Extend
    try t.file.setSize(t.rt, 8);
    try std.testing.expectEqual(8, try t.file.size(t.rt));
}

test "File: setPermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var t = try TestFile.create("test_file_permissions.txt", .{});
    defer t.deinit();

    // Set permissions to read-only
    try t.file.setPermissions(t.rt, 0o444);

    // Verify via stat
    const info = try t.file.stat(t.rt);
    try std.testing.expectEqual(0o444, info.mode & 0o777);

    // Restore permissions for cleanup
    try t.file.setPermissions(t.rt, 0o644);
}

test "File: setTimestamps" {
    var t = try TestFile.create("test_file_timestamps.txt", .{});
    defer t.deinit();

    const atime: i96 = 1000000000 * std.time.ns_per_s; // 2001-09-09
    const mtime: i96 = 1500000000 * std.time.ns_per_s; // 2017-07-14

    try t.file.setTimestamps(t.rt, .{ .atime = atime, .mtime = mtime });

    const info = try t.file.stat(t.rt);
    try std.testing.expectEqual(atime, info.atime);
    try std.testing.expectEqual(mtime, info.mtime);
}

test "File: reader and writer interface" {
    var t = try TestFile.create("test_file_rw_interface.txt", .{});
    defer t.deinit();

    // Write using writer interface
    var write_buffer: [256]u8 = undefined;
    var writer = t.file.writer(t.rt, &write_buffer);

    var data = [_][]const u8{"x"};
    try writer.interface.writeSplatAll(&data, 10);
    try writer.interface.flush();

    // Reopen for reading
    t.file.close(t.rt);
    t.file = try t.dir.openFile(t.rt, t.path, .{});

    // Read using reader interface
    var read_buffer: [256]u8 = undefined;
    var reader = t.file.reader(t.rt, &read_buffer);

    var result: [20]u8 = undefined;
    const bytes_read = try reader.interface.readSliceShort(&result);

    try std.testing.expectEqual(10, bytes_read);
    try std.testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);
}

test "Dir: setPermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dir_path = "test_dir_permissions";

    try dir.createDir(rt, dir_path, 0o755);
    defer dir.deleteDir(rt, dir_path) catch {};

    // Open the directory with iterate=true to get a real fd (not O_PATH)
    var test_dir = try dir.openDir(rt, dir_path, .{ .iterate = true });
    defer test_dir.close(rt);

    // Set permissions
    try test_dir.setPermissions(rt, 0o700);

    // Verify via stat
    const info = try test_dir.stat(rt);
    try std.testing.expectEqual(0o700, info.mode & 0o777);
}

test "Dir: setFilePermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_dir_set_file_permissions.txt";

    // Create a test file
    var file = try dir.createFile(rt, file_path, .{});
    file.close(rt);
    defer dir.deleteFile(rt, file_path) catch {};

    // Set permissions via Dir
    try dir.setFilePermissions(rt, file_path, 0o444, .{});

    // Verify via stat
    const info = try dir.statPath(rt, file_path);
    try std.testing.expectEqual(0o444, info.mode & 0o777);
}

test "Dir: setFileTimestamps" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_dir_set_file_timestamps.txt";

    // Create a test file
    var file = try dir.createFile(rt, file_path, .{});
    file.close(rt);
    defer dir.deleteFile(rt, file_path) catch {};

    const atime: i96 = 1000000000 * std.time.ns_per_s; // 2001-09-09
    const mtime: i96 = 1500000000 * std.time.ns_per_s; // 2017-07-14

    try dir.setFileTimestamps(rt, file_path, .{ .atime = atime, .mtime = mtime }, .{});

    const info = try dir.statPath(rt, file_path);
    try std.testing.expectEqual(atime, info.atime);
    try std.testing.expectEqual(mtime, info.mtime);
}

test "Dir: symLink and readLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const target_path = "test_symlink_target.txt";
    const link_path = "test_symlink_link";

    // Create target file
    var file = try dir.createFile(rt, target_path, .{});
    file.close(rt);
    defer dir.deleteFile(rt, target_path) catch {};

    // Create symlink
    try dir.symLink(rt, target_path, link_path, .{});
    defer dir.deleteFile(rt, link_path) catch {};

    // Read symlink
    var buffer: [256]u8 = undefined;
    const result = try dir.readLink(rt, link_path, &buffer);
    try std.testing.expectEqualStrings(target_path, result);
}

test "Dir: hardLink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const original_path = "test_hardlink_original.txt";
    const link_path = "test_hardlink_link.txt";

    // Create original file with content
    var file = try dir.createFile(rt, original_path, .{ .read = true });
    _ = try file.write(rt, "hello", 0);
    file.close(rt);
    defer dir.deleteFile(rt, original_path) catch {};

    // Create hard link
    try dir.hardLink(rt, original_path, dir, link_path, .{});
    defer dir.deleteFile(rt, link_path) catch {};

    // Verify link has same content
    var link_file = try dir.openFile(rt, link_path, .{});
    defer link_file.close(rt);

    var buffer: [10]u8 = undefined;
    const n = try link_file.read(rt, &buffer, 0);
    try std.testing.expectEqualStrings("hello", buffer[0..n]);
}

test "Dir: rename" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const old_path = "test_rename_old.txt";
    const new_path = "test_rename_new.txt";

    // Create original file with content
    var file = try dir.createFile(rt, old_path, .{});
    _ = try file.write(rt, "renamed", 0);
    file.close(rt);

    // Rename file
    try dir.rename(rt, old_path, dir, new_path);
    defer dir.deleteFile(rt, new_path) catch {};

    // Verify old path no longer exists
    _ = dir.openFile(rt, old_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedError;
}

test "Dir: access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_access.txt";

    // Create a test file
    var file = try dir.createFile(rt, file_path, .{});
    file.close(rt);
    defer dir.deleteFile(rt, file_path) catch {};

    // Check read access - should succeed
    try dir.access(rt, file_path, .{ .read = true });

    // Check write access - should succeed
    try dir.access(rt, file_path, .{ .write = true });

    // Check non-existent file - should fail
    dir.access(rt, "nonexistent_file.txt", .{ .read = true }) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedError;
}

test "Pipe: basic read and write" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.close(rt);

    const write_data = "Hello, pipe!";
    const bytes_written = try pipe.write.write(rt, write_data, .none);
    try std.testing.expectEqual(write_data.len, bytes_written);

    var buffer: [100]u8 = undefined;
    const bytes_read = try pipe.read.read(rt, &buffer, .none);
    try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
}

test "Pipe: reader and writer interface" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.close(rt);

    var write_buffer: [256]u8 = undefined;
    var writer = pipe.write.writer(rt, &write_buffer);

    try writer.interface.writeAll("Line 1\n");
    try writer.interface.writeAll("Line 2\n");
    try writer.interface.flush();

    var read_buffer: [256]u8 = undefined;
    var reader = pipe.read.reader(rt, &read_buffer);

    const line1 = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("Line 1\n", line1);

    const line2 = try reader.interface.takeDelimiterInclusive('\n');
    try std.testing.expectEqualStrings("Line 2\n", line2);
}

test "Pipe: timeout on blocked read" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.close(rt);

    var buffer: [100]u8 = undefined;
    const timeout = Timeout.fromMilliseconds(10);

    const result = pipe.read.read(rt, &buffer, timeout);
    try std.testing.expectError(error.Timeout, result);
}

test "Pipe: poll for readability" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.close(rt);

    // Poll should timeout when no data available
    const timeout = Timeout.fromMilliseconds(10);
    const poll_result = pipe.read.poll(rt, .read, timeout);
    try std.testing.expectError(error.Timeout, poll_result);

    // Write some data
    const write_data = "poll test";
    _ = try pipe.write.write(rt, write_data, .none);

    // Now poll should succeed immediately
    try pipe.read.poll(rt, .read, .none);

    // And we should be able to read the data
    var buffer: [100]u8 = undefined;
    const bytes_read = try pipe.read.read(rt, &buffer, .none);
    try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
}

test "Pipe: poll on closed write end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.read.close(rt);

    // Close write end
    pipe.write.close(rt);

    // Poll should succeed immediately (EOF condition)
    try pipe.read.poll(rt, .read, .none);

    // Read should return 0 (EOF)
    var buffer: [100]u8 = undefined;
    const bytes_read = try pipe.read.read(rt, &buffer, .none);
    try std.testing.expectEqual(0, bytes_read);
}

test "Pipe: poll on closed read end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.write.close(rt);

    // Close read end
    pipe.read.close(rt);

    // Poll for writability succeeds (pipe appears writable)
    try pipe.write.poll(rt, .write, .none);

    // But actual write fails with BrokenPipe
    const write_data = "test";
    const result = pipe.write.write(rt, write_data, .none);
    try std.testing.expectError(error.BrokenPipe, result);
}

test "Pipe: half-close write end" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.read.close(rt);

    const write_data = "Data before close";
    _ = try pipe.write.write(rt, write_data, .none);

    // Close write end
    pipe.write.close(rt);

    // Should be able to read existing data
    var buffer: [100]u8 = undefined;
    const bytes_read = try pipe.read.read(rt, &buffer, .none);
    try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);

    // Next read should return 0 (EOF)
    const eof_read = try pipe.read.read(rt, &buffer, .none);
    try std.testing.expectEqual(0, eof_read);
}

test "Pipe: half-close read end" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const pipe = try createPipe(rt);
    defer pipe.write.close(rt);

    // Close read end first
    pipe.read.close(rt);

    // Try to write - should get BrokenPipe error
    const write_data = "Data after close";
    const result = pipe.write.write(rt, write_data, .none);
    try std.testing.expectError(error.BrokenPipe, result);
}
