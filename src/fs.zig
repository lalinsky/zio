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
const waitForIoUncancelable = @import("common.zig").waitForIoUncancelable;
const timedWaitForIo = @import("common.zig").timedWaitForIo;
const fillBuf = @import("utils/writer.zig").fillBuf;
const probePollable = @import("ev/backends/common.zig").probePollable;
const Timeout = @import("time.zig").Timeout;

pub const Handle = os.fs.fd_t;

/// zio's std.Io integration. Imported for `debug_io` and `zioFileToStd`; the
/// mutual fs<->io import is fine (no comptime cycle).
const zio_io = @import("io.zig");

pub const max_vecs = switch (builtin.os.tag) {
    .windows => 1,
    else => 16,
};

pub fn openDir(path: []const u8) Dir.OpenDirError!Dir {
    const cwd = Dir.cwd();
    return cwd.openDir(path, .{});
}

pub fn openFile(path: []const u8) Dir.OpenFileError!File {
    const cwd = Dir.cwd();
    return cwd.openFile(path, .{});
}

pub fn deleteDir(path: []const u8) Dir.DeleteDirError!void {
    const cwd = Dir.cwd();
    return cwd.deleteDir(path);
}

pub fn deleteFile(path: []const u8) Dir.DeleteFileError!void {
    const cwd = Dir.cwd();
    return cwd.deleteFile(path);
}

pub fn rename(old_path: []const u8, new_path: []const u8) Dir.RenameError!void {
    const cwd = Dir.cwd();
    return cwd.rename(old_path, cwd, new_path);
}

pub fn createDir(path: []const u8, mode: os.fs.mode_t) Dir.CreateDirError!void {
    const cwd = Dir.cwd();
    return cwd.createDir(path, mode);
}

pub fn createFile(path: []const u8, flags: os.fs.FileCreateFlags) Dir.CreateFileError!File {
    const cwd = Dir.cwd();
    return cwd.createFile(path, flags);
}

pub const PipePair = struct {
    read: File,
    write: File,

    pub fn close(self: PipePair) void {
        self.read.close();
        self.write.close();
    }
};

pub fn createPipe() (os.fs.PipeError || Cancelable)!PipePair {
    var op = ev.PipeCreate.init();
    try waitForIo(&op.c);
    const fds = try op.getResult();
    return .{
        .read = File{ .fd = fds[0], .pollable = true },
        .write = File{ .fd = fds[1], .pollable = true },
    };
}

pub fn stdin() File {
    return stdioFile(os.fs.stdin());
}

pub fn stdout() File {
    return stdioFile(os.fs.stdout());
}

pub fn stderr() File {
    return stdioFile(os.fs.stderr());
}

/// Build a File for an inherited standard handle.
///
/// On Windows the std handles are not opened with FILE_FLAG_OVERLAPPED and are
/// not associated with the IOCP port, so the event loop cannot drive them at
/// all: both the overlapped streaming path and the positional file_read/
/// file_write path would issue a blocking overlapped operation on the loop
/// thread and stall every task. The only path that works is the thread pool's
/// blocking ReadFile/WriteFile, reached by a streaming op with pollable=false.
/// So force `pollable = false` (route to the thread pool) and `.streaming`
/// (so the Reader/Writer issues streaming ops, never positional). This holds
/// for consoles, inherited pipes, and file redirection alike. On POSIX the std
/// handles behave like any other fd.
fn stdioFile(fd: Handle) File {
    if (builtin.os.tag == .windows) {
        return .{ .fd = fd, .pollable = false, .preferred_mode = .streaming };
    }
    return .{ .fd = fd, .pollable = probePollable(fd) };
}

pub fn stat(path: []const u8) Dir.StatError!os.fs.FileStatInfo {
    const cwd = Dir.cwd();
    return cwd.statPath(path);
}

pub fn access(path: []const u8, flags: os.fs.AccessFlags) Dir.AccessError!void {
    const cwd = Dir.cwd();
    return cwd.access(path, flags);
}

pub const Dir = struct {
    fd: Handle,

    pub fn cwd() Dir {
        return .{ .fd = os.fs.cwd() };
    }

    pub fn close(self: Dir) void {
        var op = ev.DirClose.init(self.fd);
        waitForIoUncancelable(&op.c);
        _ = op.getResult() catch {};
    }

    pub const OpenDirError = os.fs.DirOpenError || Cancelable;

    pub fn openDir(self: Dir, path: []const u8, flags: os.fs.DirOpenFlags) OpenDirError!Dir {
        var op = ev.DirOpen.init(self.fd, path, flags);
        try waitForIo(&op.c);
        return .{ .fd = try op.getResult() };
    }

    pub const OpenFileError = os.fs.FileOpenError || Cancelable;

    pub fn openFile(self: Dir, path: []const u8, flags: os.fs.FileOpenFlags) OpenFileError!File {
        var op = ev.FileOpen.init(self.fd, path, flags);
        try waitForIo(&op.c);
        const result = try op.getResult();
        return .{ .fd = result.fd, .pollable = result.pollable };
    }

    pub const CreateDirError = os.fs.DirCreateDirError || Cancelable;

    pub fn createDir(self: Dir, path: []const u8, mode: os.fs.mode_t) CreateDirError!void {
        var op = ev.DirCreateDir.init(self.fd, path, mode);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const CreateFileError = os.fs.FileCreateError || Cancelable;

    pub fn createFile(self: Dir, path: []const u8, flags: os.fs.FileCreateFlags) CreateFileError!File {
        var op = ev.FileCreate.init(self.fd, path, flags);
        try waitForIo(&op.c);
        const result = try op.getResult();
        return .{ .fd = result.fd, .pollable = result.pollable };
    }

    pub const DeleteDirError = os.fs.DirDeleteDirError || Cancelable;

    pub fn deleteDir(self: Dir, path: []const u8) DeleteDirError!void {
        var op = ev.DirDeleteDir.init(self.fd, path);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const DeleteFileError = os.fs.DirDeleteFileError || Cancelable;

    pub fn deleteFile(self: Dir, path: []const u8) DeleteFileError!void {
        var op = ev.DirDeleteFile.init(self.fd, path);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const RenameError = os.fs.DirRenameError || Cancelable;

    pub fn rename(self: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8) RenameError!void {
        var op = ev.DirRename.init(self.fd, old_path, new_dir.fd, new_path);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const RenamePreserveError = os.fs.DirRenamePreserveError || Cancelable;

    pub fn renamePreserve(self: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8) RenamePreserveError!void {
        var op = ev.DirRenamePreserve.init(self.fd, old_path, new_dir.fd, new_path);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const StatError = os.fs.FileStatError || Cancelable;

    pub fn stat(self: Dir) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, null, .{});
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub fn statPath(self: Dir, path: []const u8) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, path, .{});
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub const SetPermissionsError = os.fs.FileSetPermissionsError || Cancelable;

    pub fn setPermissions(self: Dir, mode: os.fs.mode_t) SetPermissionsError!void {
        var op = ev.DirSetPermissions.init(self.fd, mode);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SetOwnerError = os.fs.FileSetOwnerError || Cancelable;

    pub fn setOwner(self: Dir, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t) SetOwnerError!void {
        var op = ev.DirSetOwner.init(self.fd, uid, gid);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub fn setFilePermissions(self: Dir, path: []const u8, mode: os.fs.mode_t, flags: os.fs.PathSetFlags) SetPermissionsError!void {
        var op = ev.DirSetFilePermissions.init(self.fd, path, mode, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub fn setFileOwner(self: Dir, path: []const u8, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t, flags: os.fs.PathSetFlags) SetOwnerError!void {
        var op = ev.DirSetFileOwner.init(self.fd, path, uid, gid, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SetTimestampsError = os.fs.FileSetTimestampsError || Cancelable;

    pub fn setFileTimestamps(self: Dir, path: []const u8, timestamps: os.fs.FileTimestamps, flags: os.fs.PathSetFlags) SetTimestampsError!void {
        var op = ev.DirSetFileTimestamps.init(self.fd, path, timestamps, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const ReadLinkError = os.fs.ReadLinkError || Cancelable;

    pub fn readLink(self: Dir, path: []const u8, buffer: []u8) ReadLinkError![]u8 {
        var op = ev.DirReadLink.init(self.fd, path, buffer);
        try waitForIo(&op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }

    pub const SymLinkError = os.fs.SymLinkError || Cancelable;

    pub fn symLink(self: Dir, target: []const u8, link_path: []const u8, flags: os.fs.SymLinkFlags) SymLinkError!void {
        var op = ev.DirSymLink.init(self.fd, target, link_path, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const HardLinkError = os.fs.HardLinkError || Cancelable;

    pub fn hardLink(self: Dir, old_path: []const u8, new_dir: Dir, new_path: []const u8, flags: os.fs.HardLinkFlags) HardLinkError!void {
        var op = ev.DirHardLink.init(self.fd, old_path, new_dir.fd, new_path, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const AccessError = os.fs.DirAccessError || Cancelable;

    pub fn access(self: Dir, path: []const u8, flags: os.fs.AccessFlags) AccessError!void {
        var op = ev.DirAccess.init(self.fd, path, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const RealPathError = os.fs.DirRealPathError || Cancelable;

    pub fn realPath(self: Dir, buffer: []u8) RealPathError![]u8 {
        var op = ev.DirRealPath.init(self.fd, buffer);
        try waitForIo(&op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }

    pub const RealPathFileError = os.fs.DirRealPathFileError || Cancelable;

    pub fn realPathFile(self: Dir, path: []const u8, buffer: []u8) RealPathFileError![]u8 {
        var op = ev.DirRealPathFile.init(self.fd, path, buffer);
        try waitForIo(&op.c);
        const len = try op.getResult();
        return buffer[0..len];
    }
};

/// Whether the Reader/Writer issues positional (offset-based) or streaming
/// (current-position) I/O ops. Independent of `File.pollable`, which decides
/// event-loop vs thread-pool routing: a console, for example, is `.streaming`
/// yet not loop-drivable.
pub const Mode = enum {
    /// Use positional I/O (pread/pwrite) with explicit offset.
    positional,
    /// Use streaming I/O (read/write) at the current file position.
    streaming,
};

pub const File = struct {
    fd: Handle,
    /// Whether `fd` is pollable (non-seekable) and can be driven by the event
    /// loop for streaming I/O. Set from the open/create result; `null` when
    /// unknown (e.g. constructed via `fromFd`). When false, streaming ops are
    /// routed to the thread pool.
    pollable: ?bool = null,
    /// Explicit Reader/Writer `Mode` hint. `null` means infer from `pollable`.
    /// Set when seekability and loop-drivability disagree (e.g. a Windows
    /// console: non-seekable, so `.streaming`, but not loop-drivable).
    preferred_mode: ?Mode = null,

    pub const ReadError = os.fs.FileReadError || Cancelable;
    pub const WriteError = os.fs.FileWriteError || Cancelable;

    pub fn fromFd(fd: Handle) File {
        return .{ .fd = fd };
    }

    /// Read from file into a single slice.
    pub fn read(self: File, buffer: []u8, offset: u64) ReadError!usize {
        var storage: [1]os.iovec = undefined;
        var op = ev.FileRead.init(self.fd, .fromSlice(buffer, &storage), offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Write to file from a single slice.
    pub fn write(self: File, data: []const u8, offset: u64) WriteError!usize {
        var storage: [1]os.iovec_const = undefined;
        var op = ev.FileWrite.init(self.fd, .fromSlice(data, &storage), offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Read from file into multiple slices (vectored read).
    pub fn readVec(self: File, slices: []const []u8, offset: u64) ReadError!usize {
        var storage: [max_vecs]os.iovec = undefined;
        var op = ev.FileRead.init(self.fd, ev.ReadBuf.fromSlices(slices, &storage), offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Write to file from multiple slices (vectored write).
    pub fn writeVec(self: File, slices: []const []const u8, offset: u64) WriteError!usize {
        var storage: [max_vecs]os.iovec_const = undefined;
        var op = ev.FileWrite.init(self.fd, ev.WriteBuf.fromSlices(slices, &storage), offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Read from file using ReadBuf (vectored read).
    pub fn readBuf(self: File, buf: ev.ReadBuf, offset: u64) ReadError!usize {
        var op = ev.FileRead.init(self.fd, buf, offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub const ReadStreamingError = os.fs.FileReadError || Cancelable;
    pub const ReadStreamingTimeoutError = ReadStreamingError || Timeoutable;

    /// Read from file at its current position (streaming), no timeout.
    pub fn readStreaming(self: File, buf: ev.ReadBuf) ReadStreamingError!usize {
        var op = ev.FileReadStreaming.init(self.fd, buf);
        op.pollable = self.pollable;
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Read from file at its current position (streaming), with timeout.
    pub fn readStreamingTimeout(self: File, buf: ev.ReadBuf, timeout: Timeout) ReadStreamingTimeoutError!usize {
        var op = ev.FileReadStreaming.init(self.fd, buf);
        op.pollable = self.pollable;
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    /// Write to file using WriteBuf (vectored write).
    pub fn writeBuf(self: File, buf: ev.WriteBuf, offset: u64) WriteError!usize {
        var op = ev.FileWrite.init(self.fd, buf, offset);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub const WriteStreamingError = os.fs.FileWriteError || Cancelable;
    pub const WriteStreamingTimeoutError = WriteStreamingError || Timeoutable;

    /// Write to file at its current position (streaming), no timeout.
    pub fn writeStreaming(self: File, buf: ev.WriteBuf) WriteStreamingError!usize {
        var op = ev.FileWriteStreaming.init(self.fd, buf);
        op.pollable = self.pollable;
        try waitForIo(&op.c);
        return try op.getResult();
    }

    /// Write to file at its current position (streaming), with timeout.
    pub fn writeStreamingTimeout(self: File, buf: ev.WriteBuf, timeout: Timeout) WriteStreamingTimeoutError!usize {
        var op = ev.FileWriteStreaming.init(self.fd, buf);
        op.pollable = self.pollable;
        try timedWaitForIo(&op.c, timeout);
        return try op.getResult();
    }

    pub fn close(self: File) void {
        var op = ev.FileClose.init(self.fd);
        waitForIoUncancelable(&op.c);
        _ = op.getResult() catch {};
    }

    pub const StatError = os.fs.FileStatError || Cancelable;

    pub fn stat(self: File) StatError!os.fs.FileStatInfo {
        var op = ev.FileStat.init(self.fd, null, .{});
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub const SyncError = os.fs.FileSyncError || Cancelable;

    pub fn sync(self: File, flags: os.fs.FileSyncFlags) SyncError!void {
        var op = ev.FileSync.init(self.fd, flags);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SetSizeError = os.fs.FileSetSizeError || Cancelable;

    pub fn setSize(self: File, length: u64) SetSizeError!void {
        var op = ev.FileSetSize.init(self.fd, length);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SizeError = os.fs.FileSizeError || Cancelable;

    pub fn size(self: File) SizeError!u64 {
        var op = ev.FileSize.init(self.fd);
        try waitForIo(&op.c);
        return try op.getResult();
    }

    pub const SetPermissionsError = os.fs.FileSetPermissionsError || Cancelable;

    pub fn setPermissions(self: File, mode: os.fs.mode_t) SetPermissionsError!void {
        var op = ev.FileSetPermissions.init(self.fd, mode);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SetOwnerError = os.fs.FileSetOwnerError || Cancelable;

    pub fn setOwner(self: File, uid: ?os.fs.uid_t, gid: ?os.fs.gid_t) SetOwnerError!void {
        var op = ev.FileSetOwner.init(self.fd, uid, gid);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub const SetTimestampsError = os.fs.FileSetTimestampsError || Cancelable;

    pub fn setTimestamps(self: File, timestamps: os.fs.FileTimestamps) SetTimestampsError!void {
        var op = ev.FileSetTimestamps.init(self.fd, timestamps);
        try waitForIo(&op.c);
        try op.getResult();
    }

    pub fn reader(self: File, buffer: []u8) FileReader {
        return FileReader.init(self, buffer);
    }

    pub fn writer(self: File, buffer: []u8) FileWriter {
        return FileWriter.init(self, buffer);
    }

    /// Wrap this file as a `std.Io.File.Reader`, for std.Io APIs that require
    /// that exact type (e.g. `std.Io.Writer.sendFileAll`). Unlike `reader`,
    /// which returns zio's own `FileReader`, this returns std's reader bound to
    /// zio's `std.Io`. I/O through it still goes through zio's runtime: it
    /// suspends on the current task's loop when called from a zio task, and runs
    /// synchronously otherwise.
    pub fn stdReader(self: File, buffer: []u8) std.Io.File.Reader {
        return zio_io.zioFileToStd(self).reader(zio_io.debug_io, buffer);
    }

    /// Like `stdReader`, but returns a `std.Io.File.Writer`.
    pub fn stdWriter(self: File, buffer: []u8) std.Io.File.Writer {
        return zio_io.zioFileToStd(self).writer(zio_io.debug_io, buffer);
    }
};

/// Pick the Reader/Writer mode for a file: an explicit `preferred_mode` wins,
/// otherwise infer from `pollable` (non-seekable -> streaming, seekable or
/// unknown -> positional).
pub fn resolveMode(file: File) Mode {
    if (file.preferred_mode) |m| return m;
    return if (file.pollable) |p|
        if (p) .streaming else .positional
    else
        .positional;
}

/// File reader that implements std.Io.Reader interface.
/// Dispatches between positional I/O (regular files) and streaming I/O
/// (pipes, sockets, ttys) based on the File's mode.
pub const FileReader = struct {
    pub const Error = os.fs.FileReadError || Cancelable || Timeoutable;

    file: File,
    mode: Mode,
    position: u64 = 0,
    timeout: Timeout = .none,
    err: ?Error = null,
    interface: std.Io.Reader,

    pub fn init(file: File, buffer: []u8) FileReader {
        const mode: Mode = resolveMode(file);
        return .{
            .file = file,
            .mode = mode,
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

    pub fn setTimeout(self: *FileReader, timeout: Timeout) void {
        self.timeout = timeout;
    }

    pub fn logicalPos(self: *const FileReader) u64 {
        return self.position - self.interface.end + self.interface.seek;
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
        switch (r.mode) {
            .positional => {
                const dest = limit.slice(try w.writableSliceGreedy(1));
                var storage: [1]os.iovec = undefined;
                var op = ev.FileRead.init(r.file.fd, ev.ReadBuf.fromSlice(dest, &storage), r.position);
                timedWaitForIo(&op.c, r.timeout) catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                const n = op.getResult() catch |err| switch (err) {
                    error.Unseekable => {
                        r.mode = .streaming;
                        return 0;
                    },
                    else => |e| {
                        r.err = e;
                        return error.ReadFailed;
                    },
                };
                if (n == 0) return error.EndOfStream;
                r.position += n;
                w.advance(n);
                return n;
            },
            .streaming => {
                const dest = limit.slice(try w.writableSliceGreedy(1));
                var storage: [1]os.iovec = undefined;
                const n = r.file.readStreamingTimeout(ev.ReadBuf.fromSlice(dest, &storage), r.timeout) catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                if (n == 0) return error.EndOfStream;
                w.advance(n);
                return n;
            },
        }
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));
        const to_discard = @intFromEnum(limit);
        if (to_discard == 0) return 0;

        switch (r.mode) {
            .positional => {
                // For regular files, we can just seek forward
                r.position += to_discard;

                // Verify we didn't seek past EOF by reading 2 bytes:
                // - 1 byte at position-1 (last byte we claim to have discarded)
                // - 1 byte at position (to verify there's more data or we're exactly at EOF)
                var buf: [2]u8 = undefined;
                var iovec_storage: [1]os.iovec = undefined;
                var op = ev.FileRead.init(r.file.fd, ev.ReadBuf.fromSlice(&buf, &iovec_storage), r.position - 1);
                timedWaitForIo(&op.c, r.timeout) catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                const n = op.getResult() catch |err| switch (err) {
                    error.Unseekable => {
                        r.mode = .streaming;
                        return 0;
                    },
                    else => |e| {
                        r.err = e;
                        return error.ReadFailed;
                    },
                };
                if (n == 0) return error.EndOfStream;
                return to_discard;
            },
            .streaming => {
                // Read and discard loop.
                var remaining = to_discard;
                var trash: [128]u8 = undefined;
                while (remaining > 0) {
                    var storage: [1]os.iovec = undefined;
                    const to_read = @min(remaining, trash.len);
                    const n = r.file.readStreamingTimeout(ev.ReadBuf.fromSlice(trash[0..to_read], &storage), r.timeout) catch |err| {
                        r.err = err;
                        return error.ReadFailed;
                    };
                    if (n == 0) return error.EndOfStream;
                    remaining -= n;
                }
                return to_discard;
            },
        }
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *FileReader = @alignCast(@fieldParentPtr("interface", io_reader));

        var iovec_storage: [1 + max_vecs]os.iovec = undefined;
        const dest_n, const data_size = if (builtin.os.tag == .windows)
            try io_reader.writableVectorWsa(&iovec_storage, data)
        else
            try io_reader.writableVectorPosix(&iovec_storage, data);
        if (dest_n == 0) return 0;

        switch (r.mode) {
            .positional => {
                const buf = ev.ReadBuf{ .iovecs = iovec_storage[0..dest_n] };
                var op = ev.FileRead.init(r.file.fd, buf, r.position);
                timedWaitForIo(&op.c, r.timeout) catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                const n = op.getResult() catch |err| switch (err) {
                    error.Unseekable => {
                        r.mode = .streaming;
                        return 0;
                    },
                    else => |e| {
                        r.err = e;
                        return error.ReadFailed;
                    },
                };
                if (n == 0) return error.EndOfStream;
                r.position += n;
                if (n > data_size) {
                    io_reader.end += n - data_size;
                    return data_size;
                }
                return n;
            },
            .streaming => {
                const buf = ev.ReadBuf{ .iovecs = iovec_storage[0..dest_n] };
                const n = r.file.readStreamingTimeout(buf, r.timeout) catch |err| {
                    r.err = err;
                    return error.ReadFailed;
                };
                if (n == 0) return error.EndOfStream;
                if (n > data_size) {
                    io_reader.end += n - data_size;
                    return data_size;
                }
                return n;
            },
        }
    }
};

/// File writer that implements std.Io.Writer interface.
/// Dispatches between positional I/O (regular files) and streaming I/O
/// (pipes, sockets, ttys) based on the File's mode.
pub const FileWriter = struct {
    pub const Error = os.fs.FileWriteError || Cancelable || Timeoutable;

    file: File,
    mode: Mode,
    position: u64 = 0,
    timeout: Timeout = .none,
    err: ?Error = null,
    interface: std.Io.Writer,

    pub fn init(file: File, buffer: []u8) FileWriter {
        const mode: Mode = resolveMode(file);
        return .{
            .file = file,
            .mode = mode,
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

    pub fn setTimeout(self: *FileWriter, timeout: Timeout) void {
        self.timeout = timeout;
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

        switch (w.mode) {
            .positional => {
                var storage: [max_vecs]os.iovec_const = undefined;
                const write_buf = ev.WriteBuf.fromSlices(slices[0..buf_len], &storage);
                var op = ev.FileWrite.init(w.file.fd, write_buf, w.position);
                timedWaitForIo(&op.c, w.timeout) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                const n = op.getResult() catch |err| switch (err) {
                    error.Unseekable => {
                        w.mode = .streaming;
                        return 0;
                    },
                    else => |e| {
                        w.err = e;
                        return error.WriteFailed;
                    },
                };
                w.position += n;
                return io_writer.consume(n);
            },
            .streaming => {
                var storage: [max_vecs]os.iovec_const = undefined;
                const write_buf = ev.WriteBuf.fromSlices(slices[0..buf_len], &storage);
                const n = w.file.writeStreamingTimeout(write_buf, w.timeout) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                return io_writer.consume(n);
            },
        }
    }

    fn flush(io_writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const w: *FileWriter = @alignCast(@fieldParentPtr("interface", io_writer));

        while (io_writer.end > 0) {
            const buffered = io_writer.buffered();

            switch (w.mode) {
                .positional => {
                    var storage: [1]os.iovec_const = undefined;
                    var op = ev.FileWrite.init(w.file.fd, ev.WriteBuf.fromSlice(buffered, &storage), w.position);
                    timedWaitForIo(&op.c, w.timeout) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                    const n = op.getResult() catch |err| switch (err) {
                        error.Unseekable => {
                            w.mode = .streaming;
                            continue;
                        },
                        else => |e| {
                            w.err = e;
                            return error.WriteFailed;
                        },
                    };
                    if (n == 0) return error.WriteFailed;
                    w.position += n;
                    if (n < buffered.len) {
                        std.mem.copyForwards(u8, io_writer.buffer, buffered[n..]);
                        io_writer.end -= n;
                    } else {
                        io_writer.end = 0;
                    }
                },
                .streaming => {
                    var storage: [1]os.iovec_const = undefined;
                    const n = w.file.writeStreamingTimeout(ev.WriteBuf.fromSlice(buffered, &storage), w.timeout) catch |err| {
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
                },
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
        const file = try dir.createFile(path, flags);
        return .{ .rt = rt, .dir = dir, .file = file, .path = path };
    }

    pub fn deinit(self: *TestFile) void {
        self.file.close();
        self.dir.deleteFile(self.path) catch {};
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
    var zio_file = try dir.createFile(file_path, .{});

    // Write test
    const write_data = "Hello, zio!";
    const bytes_written = try zio_file.write(write_data, 0);
    try std.testing.expectEqual(write_data.len, bytes_written);

    // Close file before reopening for read
    zio_file.close();

    // Read test - reopen the file for reading
    var read_file = try dir.openFile(file_path, .{ .mode = .read_only });

    var buffer: [100]u8 = undefined;
    const bytes_read = try read_file.read(&buffer, 0);
    try std.testing.expectEqualStrings(write_data, buffer[0..bytes_read]);
    read_file.close();

    try dir.deleteFile(file_path);
}

test "File: positional read and write" {
    var t = try TestFile.create("test_file_positional.txt", .{ .read = true });
    defer t.deinit();

    // Write at different positions
    try std.testing.expectEqual(5, try t.file.write("HELLO", 0));
    try std.testing.expectEqual(5, try t.file.write("WORLD", 10));

    // Read from positions
    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(5, try t.file.read(&buf, 0));
    try std.testing.expectEqualStrings("HELLO", &buf);

    try std.testing.expectEqual(5, try t.file.read(&buf, 10));
    try std.testing.expectEqualStrings("WORLD", &buf);

    // Test reading from gap (should be zeros or random data)
    var gap_buf: [3]u8 = undefined;
    try std.testing.expectEqual(3, try t.file.read(&gap_buf, 5));
}

test "File: sync operation" {
    var t = try TestFile.create("test_file_sync.txt", .{});
    defer t.deinit();

    // Write some data
    const bytes_written = try t.file.write("test data", 0);
    try std.testing.expectEqual(9, bytes_written);

    // Full sync (fsync)
    try t.file.sync(.{});

    // Data-only sync (fdatasync)
    try t.file.sync(.{ .only_data = true });
}

test "File: size and setSize" {
    var t = try TestFile.create("test_file_size.txt", .{ .read = true });
    defer t.deinit();

    // Write some data
    try std.testing.expectEqual(10, try t.file.write("0123456789", 0));

    // Check size
    try std.testing.expectEqual(10, try t.file.size());

    // Truncate
    try t.file.setSize(5);
    try std.testing.expectEqual(5, try t.file.size());

    // Verify content
    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(5, try t.file.read(&buf, 0));
    try std.testing.expectEqualStrings("01234", buf[0..5]);

    // Extend
    try t.file.setSize(8);
    try std.testing.expectEqual(8, try t.file.size());
}

test "File: setPermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var t = try TestFile.create("test_file_permissions.txt", .{});
    defer t.deinit();

    // Set permissions to read-only
    try t.file.setPermissions(0o444);

    // Verify via stat
    const info = try t.file.stat();
    try std.testing.expectEqual(0o444, info.mode & 0o777);

    // Restore permissions for cleanup
    try t.file.setPermissions(0o644);
}

test "File: setTimestamps" {
    var t = try TestFile.create("test_file_timestamps.txt", .{});
    defer t.deinit();

    const atime: i96 = 1000000000 * std.time.ns_per_s; // 2001-09-09
    const mtime: i96 = 1500000000 * std.time.ns_per_s; // 2017-07-14

    try t.file.setTimestamps(.{ .atime = atime, .mtime = mtime });

    const info = try t.file.stat();
    try std.testing.expectEqual(atime, info.atime);
    try std.testing.expectEqual(mtime, info.mtime);
}

test "File: reader and writer interface" {
    var t = try TestFile.create("test_file_rw_interface.txt", .{});
    defer t.deinit();

    // Write using writer interface
    var write_buffer: [256]u8 = undefined;
    var writer = t.file.writer(&write_buffer);

    var data = [_][]const u8{"x"};
    try writer.interface.writeSplatAll(&data, 10);
    try writer.interface.flush();

    // Reopen for reading
    t.file.close();
    t.file = try t.dir.openFile(t.path, .{});

    // Read using reader interface
    var read_buffer: [256]u8 = undefined;
    var reader = t.file.reader(&read_buffer);

    var result: [20]u8 = undefined;
    const bytes_read = try reader.interface.readSliceShort(&result);

    try std.testing.expectEqual(10, bytes_read);
    try std.testing.expectEqualStrings("xxxxxxxxxx", result[0..bytes_read]);
}

test "File: stdReader and stdWriter round-trip" {
    var t = try TestFile.create("test_file_std_rw.txt", .{});
    defer t.deinit();

    // Write via std.Io.File.Writer (zio file -> std reader/writer).
    var write_buffer: [256]u8 = undefined;
    var writer = t.file.stdWriter(&write_buffer);
    try writer.interface.writeAll("hello std.Io");
    try writer.interface.flush();

    // Reopen and read back via std.Io.File.Reader.
    t.file.close();
    t.file = try t.dir.openFile(t.path, .{});

    var read_buffer: [256]u8 = undefined;
    var reader = t.file.stdReader(&read_buffer);
    var result: [32]u8 = undefined;
    const n = try reader.interface.readSliceShort(&result);
    try std.testing.expectEqualStrings("hello std.Io", result[0..n]);
}

test "Dir: setPermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dir_path = "test_dir_permissions";

    try dir.createDir(dir_path, 0o755);
    defer dir.deleteDir(dir_path) catch {};

    // Open the directory with iterate=true to get a real fd (not O_PATH)
    var test_dir = try dir.openDir(dir_path, .{ .iterate = true });
    defer test_dir.close();

    // Set permissions
    try test_dir.setPermissions(0o700);

    // Verify via stat
    const info = try test_dir.stat();
    try std.testing.expectEqual(0o700, info.mode & 0o777);
}

test "Dir: setFilePermissions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_dir_set_file_permissions.txt";

    // Create a test file
    var file = try dir.createFile(file_path, .{});
    file.close();
    defer dir.deleteFile(file_path) catch {};

    // Set permissions via Dir
    try dir.setFilePermissions(file_path, 0o444, .{});

    // Verify via stat
    const info = try dir.statPath(file_path);
    try std.testing.expectEqual(0o444, info.mode & 0o777);
}

test "Dir: setFileTimestamps" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_dir_set_file_timestamps.txt";

    // Create a test file
    var file = try dir.createFile(file_path, .{});
    file.close();
    defer dir.deleteFile(file_path) catch {};

    const atime: i96 = 1000000000 * std.time.ns_per_s; // 2001-09-09
    const mtime: i96 = 1500000000 * std.time.ns_per_s; // 2017-07-14

    try dir.setFileTimestamps(file_path, .{ .atime = atime, .mtime = mtime }, .{});

    const info = try dir.statPath(file_path);
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
    var file = try dir.createFile(target_path, .{});
    file.close();
    defer dir.deleteFile(target_path) catch {};

    // Create symlink
    try dir.symLink(target_path, link_path, .{});
    defer dir.deleteFile(link_path) catch {};

    // Read symlink
    var buffer: [256]u8 = undefined;
    const result = try dir.readLink(link_path, &buffer);
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
    var file = try dir.createFile(original_path, .{ .read = true });
    _ = try file.write("hello", 0);
    file.close();
    defer dir.deleteFile(original_path) catch {};

    // Create hard link
    try dir.hardLink(original_path, dir, link_path, .{});
    defer dir.deleteFile(link_path) catch {};

    // Verify link has same content
    var link_file = try dir.openFile(link_path, .{});
    defer link_file.close();

    var buffer: [10]u8 = undefined;
    const n = try link_file.read(&buffer, 0);
    try std.testing.expectEqualStrings("hello", buffer[0..n]);
}

test "Dir: rename" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const old_path = "test_rename_old.txt";
    const new_path = "test_rename_new.txt";

    // Create original file with content
    var file = try dir.createFile(old_path, .{});
    _ = try file.write("renamed", 0);
    file.close();

    // Rename file
    try dir.rename(old_path, dir, new_path);
    defer dir.deleteFile(new_path) catch {};

    // Verify old path no longer exists
    _ = dir.openFile(old_path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedError;
}

test "Dir: renamePreserve" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const old_path = "test_rename_preserve_old.txt";
    const new_path = "test_rename_preserve_new.txt";

    var file = try dir.createFile(old_path, .{});
    file.close();

    // Rename to a path that doesn't exist yet — should succeed.
    try dir.renamePreserve(old_path, dir, new_path);
    defer dir.deleteFile(new_path) catch {};

    // Old path should be gone.
    try std.testing.expectError(error.FileNotFound, dir.openFile(old_path, .{}));

    // Rename again to an existing destination — should fail.
    var file2 = try dir.createFile(old_path, .{});
    file2.close();
    defer dir.deleteFile(old_path) catch {};

    try std.testing.expectError(error.PathAlreadyExists, dir.renamePreserve(old_path, dir, new_path));
}

test "Dir: access" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_access.txt";

    // Create a test file
    var file = try dir.createFile(file_path, .{});
    file.close();
    defer dir.deleteFile(file_path) catch {};

    // Check read access - should succeed
    try dir.access(file_path, .{ .read = true });

    // Check write access - should succeed
    try dir.access(file_path, .{ .write = true });

    // Check non-existent file - should fail
    dir.access("nonexistent_file.txt", .{ .read = true }) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedError;
}

test "Dir: resolve_beneath blocks parent escape" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();

    try cwd.createDir("test-resolve-beneath-dir1", 0o755);
    defer cwd.deleteDir("test-resolve-beneath-dir1") catch {};

    const dir1 = try cwd.openDir("test-resolve-beneath-dir1", .{});
    defer dir1.close();

    var file1 = try dir1.createFile("file1", .{});
    file1.close();
    defer dir1.deleteFile("file1") catch {};

    try dir1.createDir("dir2", 0o755);
    defer dir1.deleteDir("dir2") catch {};

    const dir2 = try dir1.openDir("dir2", .{});
    defer dir2.close();

    // Opening ../file1 from dir2 without resolve_beneath succeeds
    var f = try dir2.openFile(".." ++ std.fs.path.sep_str ++ "file1", .{});
    f.close();

    // Opening ../file1 from dir2 with resolve_beneath must fail
    if (dir2.openFile(".." ++ std.fs.path.sep_str ++ "file1", .{ .resolve_beneath = true })) |file| {
        file.close();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.AccessDenied, error.Unsupported => {},
        else => return err,
    }
}
