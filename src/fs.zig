// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-FileCopyrightText: Zig contributors (deleteTree, ported from std.Io.Dir)
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
const random = @import("random.zig").random;
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

pub fn deleteTree(path: []const u8) Dir.DeleteTreeError!void {
    const cwd = Dir.cwd();
    return cwd.deleteTree(path);
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

pub fn createFileAtomic(dest_path: []const u8, options: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!AtomicFile {
    const cwd = Dir.cwd();
    return cwd.createFileAtomic(dest_path, options);
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

    pub const CreateFileAtomicOptions = struct {
        /// Permission bits for the created file.
        mode: os.fs.mode_t = 0o664,
        /// Open the temporary file for reading as well as writing.
        read: bool = false,
    };

    pub const CreateFileAtomicError = CreateFileError || OpenDirError;

    /// Create a randomly named temporary file that can later be atomically
    /// moved to `dest_path` with `AtomicFile.link` or `AtomicFile.replace`.
    /// The temporary file is created in the destination's directory, so the
    /// final move is a rename, never a copy.
    ///
    /// The returned `AtomicFile` references the basename of `dest_path`, so
    /// `dest_path` must remain valid until `link`/`replace`. Always call
    /// `AtomicFile.deinit` to release resources, even after a successful
    /// `link`/`replace`.
    pub fn createFileAtomic(self: Dir, dest_path: []const u8, options: CreateFileAtomicOptions) CreateFileAtomicError!AtomicFile {
        if (std.Io.Dir.path.dirname(dest_path)) |dirname| {
            const parent = try self.openDir(dirname, .{});
            errdefer parent.close();
            return atomicFileInit(std.Io.Dir.path.basename(dest_path), parent, true, options);
        }
        return atomicFileInit(dest_path, self, false, options);
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

    /// Iterate the directory's entries. The directory must have been opened with
    /// `.iterate = true`. Returned entry names point into the iterator's own
    /// buffer and are only valid until the next call to `next()`.
    pub fn iterate(self: Dir) Iterator {
        return .{ .fd = self.fd };
    }

    pub const Iterator = struct {
        fd: Handle,
        buffer: [buffer_size]u8 = undefined,
        // index/end are positions in the raw-entry (unreserved) region.
        index: usize = 0,
        end: usize = 0,
        name_index: usize = 0,
        started: bool = false,
        finished: bool = false,

        const buffer_size = 2048;

        pub const Entry = os.fs.DirEntry;
        pub const Error = ev.DirRead.Error;

        /// Returns the next entry, or null at the end. "." and ".." are skipped.
        pub fn next(self: *Iterator) Error!?Entry {
            while (true) {
                if (self.end - self.index == 0) {
                    if (self.finished) return null;
                    const restart = !self.started;
                    self.started = true;

                    var op = ev.DirRead.init(self.fd, &self.buffer, restart);
                    try waitForIo(&op.c);
                    const n = try op.getResult();
                    if (n == 0) {
                        self.finished = true;
                        return null;
                    }
                    self.index = 0;
                    self.end = n;
                    self.name_index = 0;
                }

                // Reconstruct the parser each call (rather than storing it) so the
                // Iterator holds no slice into its own buffer and stays movable.
                var it = os.fs.DirEntryIterator.init(&self.buffer, self.index, self.end);
                it.name_index = self.name_index;
                const entry = it.next() orelse {
                    self.index = it.index;
                    self.end = it.end;
                    self.name_index = it.name_index;
                    continue;
                };
                self.index = it.index;
                self.name_index = it.name_index;
                return entry;
            }
        }
    };

    pub const DeleteTreeError = error{
        AccessDenied,
        PermissionDenied,
        FileBusy,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        NoDevice,
        NameTooLong,
        SystemResources,
        ReadOnlyFileSystem,
        /// One of the path components was not a directory.
        /// This error is unreachable if `path` does not contain a path separator.
        NotDir,
        BadPathName,
        NetworkNotFound,
        Unsupported,
        Unexpected,
    } || Cancelable;

    /// Whether `path` describes a symlink, file, or directory, this function
    /// removes it. If it cannot be removed because it is a non-empty directory,
    /// this function recursively removes its entries and then tries again.
    ///
    /// Symlinks are never followed: a symlink entry is removed itself, not the
    /// tree it points to. This operation is not atomic on most file systems.
    pub fn deleteTree(self: Dir, path: []const u8) DeleteTreeError!void {
        const initial_iterable_dir = (try self.deleteTreeOpenInitialSubpath(path, .file)) orelse return;

        const StackItem = struct {
            name: []const u8,
            parent_dir: Dir,
            iter: Iterator,
        };

        // Each Iterator embeds a 2 KiB read buffer, making this the dominant
        // stack cost of the function. Trees nested deeper than the stack
        // capacity are handled by the O(1)-memory fallback below.
        var stack_buffer: [16]StackItem = undefined;
        var stack: std.ArrayList(StackItem) = .initBuffer(&stack_buffer);
        defer for (stack.items) |*item| Dir.close(.{ .fd = item.iter.fd });

        stack.appendAssumeCapacity(.{
            .name = path,
            .parent_dir = self,
            .iter = initial_iterable_dir.iterate(),
        });

        process_stack: while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const top_dir: Dir = .{ .fd = top.iter.fd };
            while (try top.iter.next()) |entry| {
                var treat_as_dir = entry.kind == .directory;
                handle_entry: while (true) {
                    if (treat_as_dir) {
                        if (stack.items.len < stack_buffer.len) {
                            const iterable_dir = top_dir.openDir(entry.name, .{
                                .follow_symlinks = false,
                                .iterate = true,
                            }) catch |err| switch (err) {
                                error.NotDir => {
                                    treat_as_dir = false;
                                    continue :handle_entry;
                                },
                                error.FileNotFound => {
                                    // That's fine, we were trying to remove this directory anyway.
                                    break :handle_entry;
                                },
                                else => |e| return e,
                            };
                            // entry.name points into top's iterator buffer, which stays
                            // untouched until this child is popped and the name is used
                            // to delete the child directory from its parent.
                            stack.appendAssumeCapacity(.{
                                .name = entry.name,
                                .parent_dir = top_dir,
                                .iter = iterable_dir.iterate(),
                            });
                            continue :process_stack;
                        } else {
                            try top_dir.deleteTreeMinStackSizeWithKindHint(entry.name, entry.kind);
                            break :handle_entry;
                        }
                    } else {
                        if (top_dir.deleteFile(entry.name)) {
                            break :handle_entry;
                        } else |err| switch (err) {
                            error.FileNotFound => break :handle_entry,

                            // Impossible because we do not pass any path separators.
                            error.NotDir => unreachable,

                            error.IsDir => {
                                treat_as_dir = true;
                                continue :handle_entry;
                            },

                            else => |e| return e,
                        }
                    }
                }
            }

            // On Windows, we can't delete until the dir's handle has been closed, so
            // close it before we try to delete.
            top_dir.close();

            // In order to avoid double-closing the directory when cleaning up
            // the stack in the case of an error, we save the relevant portions and
            // pop the value from the stack.
            const parent_dir = top.parent_dir;
            const name = top.name;
            stack.items.len -= 1;

            var need_to_retry: bool = false;
            parent_dir.deleteDir(name) catch |err| switch (err) {
                error.FileNotFound => {},
                error.DirNotEmpty => need_to_retry = true,
                else => |e| return e,
            };

            if (need_to_retry) {
                // Since we closed the handle that the previous iterator used, we
                // need to re-open the dir and re-create the iterator.
                var treat_as_dir = true;
                const iterable_dir: Dir = handle_entry: while (true) {
                    if (treat_as_dir) {
                        break :handle_entry parent_dir.openDir(name, .{
                            .follow_symlinks = false,
                            .iterate = true,
                        }) catch |err| switch (err) {
                            error.NotDir => {
                                treat_as_dir = false;
                                continue :handle_entry;
                            },
                            error.FileNotFound => {
                                // That's fine, we were trying to remove this directory anyway.
                                continue :process_stack;
                            },
                            else => |e| return e,
                        };
                    } else {
                        if (parent_dir.deleteFile(name)) {
                            continue :process_stack;
                        } else |err| switch (err) {
                            error.FileNotFound => continue :process_stack,

                            // Impossible because we do not pass any path separators.
                            error.NotDir => unreachable,

                            error.IsDir => {
                                treat_as_dir = true;
                                continue :handle_entry;
                            },

                            else => |e| return e,
                        }
                    }
                };
                // We know there is room on the stack since we are just re-adding
                // the StackItem that we previously popped.
                stack.appendAssumeCapacity(.{
                    .name = name,
                    .parent_dir = parent_dir,
                    .iter = iterable_dir.iterate(),
                });
                continue :process_stack;
            }
        }
    }

    /// Like `deleteTree`, but keeps only one directory iterator open at a time,
    /// to minimize memory usage. This is slower than `deleteTree`, because it
    /// re-scans partially deleted directories from the top of the tree.
    pub fn deleteTreeMinStackSize(self: Dir, path: []const u8) DeleteTreeError!void {
        return self.deleteTreeMinStackSizeWithKindHint(path, .file);
    }

    fn deleteTreeMinStackSizeWithKindHint(parent: Dir, path: []const u8, kind_hint: os.fs.FileKind) DeleteTreeError!void {
        start_over: while (true) {
            var dir = (try parent.deleteTreeOpenInitialSubpath(path, kind_hint)) orelse return;
            var cleanup_dir_parent: ?Dir = null;
            defer if (cleanup_dir_parent) |d| d.close();

            var cleanup_dir = true;
            defer if (cleanup_dir) dir.close();

            // Only ever holds a single path component returned by the iterator,
            // which is at most NAME_MAX bytes (up to 3x that on Windows after
            // conversion to UTF-8).
            var dir_name_buf: [1024]u8 = undefined;
            var dir_name: []const u8 = path;

            // Here we must avoid recursion, in order to provide O(1) memory guarantee of this function.
            // Go through each entry and if it is not a directory, delete it. If it is a directory,
            // open it, and close the original directory. Repeat. Then start the entire operation over.

            scan_dir: while (true) {
                var dir_it = dir.iterate();
                dir_it: while (try dir_it.next()) |entry| {
                    var treat_as_dir = entry.kind == .directory;
                    handle_entry: while (true) {
                        if (treat_as_dir) {
                            const new_dir = dir.openDir(entry.name, .{
                                .follow_symlinks = false,
                                .iterate = true,
                            }) catch |err| switch (err) {
                                error.NotDir => {
                                    treat_as_dir = false;
                                    continue :handle_entry;
                                },
                                error.FileNotFound => {
                                    // That's fine, we were trying to remove this directory anyway.
                                    continue :dir_it;
                                },
                                else => |e| return e,
                            };
                            if (cleanup_dir_parent) |d| d.close();
                            cleanup_dir_parent = dir;
                            dir = new_dir;
                            const copied_name = dir_name_buf[0..entry.name.len];
                            @memcpy(copied_name, entry.name);
                            dir_name = copied_name;
                            continue :scan_dir;
                        } else {
                            if (dir.deleteFile(entry.name)) {
                                continue :dir_it;
                            } else |err| switch (err) {
                                error.FileNotFound => continue :dir_it,

                                // Impossible because we do not pass any path separators.
                                error.NotDir => unreachable,

                                error.IsDir => {
                                    treat_as_dir = true;
                                    continue :handle_entry;
                                },

                                else => |e| return e,
                            }
                        }
                    }
                }
                // Reached the end of the directory entries, which means we successfully deleted all of them.
                // Now to remove the directory itself.
                dir.close();
                cleanup_dir = false;

                if (cleanup_dir_parent) |d| {
                    d.deleteDir(dir_name) catch |err| switch (err) {
                        // These two things can happen due to file system race conditions.
                        error.FileNotFound, error.DirNotEmpty => continue :start_over,
                        else => |e| return e,
                    };
                    continue :start_over;
                } else {
                    parent.deleteDir(path) catch |err| switch (err) {
                        error.FileNotFound => return,
                        error.DirNotEmpty => continue :start_over,
                        else => |e| return e,
                    };
                    return;
                }
            }
        }
    }

    /// On successful delete, returns null.
    fn deleteTreeOpenInitialSubpath(self: Dir, path: []const u8, kind_hint: os.fs.FileKind) DeleteTreeError!?Dir {
        var treat_as_dir = kind_hint == .directory;
        handle_entry: while (true) {
            if (treat_as_dir) {
                return self.openDir(path, .{
                    .follow_symlinks = false,
                    .iterate = true,
                }) catch |err| switch (err) {
                    error.NotDir => {
                        treat_as_dir = false;
                        continue :handle_entry;
                    },
                    error.FileNotFound => {
                        // That's fine, we were trying to remove this directory anyway.
                        return null;
                    },
                    else => |e| return e,
                };
            } else {
                if (self.deleteFile(path)) {
                    return null;
                } else |err| switch (err) {
                    error.FileNotFound => return null,
                    error.IsDir => {
                        treat_as_dir = true;
                        continue :handle_entry;
                    },
                    else => |e| return e,
                }
            }
        }
    }
};

/// A file that is atomically materialized at its destination path when `link`
/// or `replace` is called. The data is first written to a randomly named
/// temporary file in the destination's directory, then moved into place with
/// an atomic rename. Created by `Dir.createFileAtomic`.
///
/// Always call `deinit` to release resources, even after a successful `link`
/// or `replace`; if the file was not moved into place, it is deleted.
pub const AtomicFile = struct {
    /// The open temporary file. Write the data here.
    file: File,
    file_basename_hex: u64,
    file_open: bool,
    file_exists: bool,

    dir: Dir,
    close_dir_on_deinit: bool,

    dest_sub_path: []const u8,

    pub fn deinit(self: *AtomicFile) void {
        if (self.file_open) {
            self.file.close();
            self.file_open = false;
        }
        if (self.file_exists) {
            const tmp_sub_path = std.fmt.hex(self.file_basename_hex);
            // Cleanup must run even when the task is being canceled, like close().
            var op = ev.DirDeleteFile.init(self.dir.fd, &tmp_sub_path);
            waitForIoUncancelable(&op.c);
            op.getResult() catch {};
            self.file_exists = false;
        }
        if (self.close_dir_on_deinit) {
            self.dir.close();
            self.close_dir_on_deinit = false;
        }
        self.* = undefined;
    }

    pub const LinkError = Dir.RenamePreserveError;

    /// Atomically move the temporary file to the destination path, failing
    /// with `error.PathAlreadyExists` if something already exists there.
    pub fn link(self: *AtomicFile) LinkError!void {
        if (self.file_open) {
            self.file.close();
            self.file_open = false;
        }
        const tmp_sub_path = std.fmt.hex(self.file_basename_hex);
        try self.dir.renamePreserve(&tmp_sub_path, self.dir, self.dest_sub_path);
        self.file_exists = false;
    }

    pub const ReplaceError = Dir.RenameError;

    /// Atomically move the temporary file to the destination path, replacing
    /// any file already there.
    pub fn replace(self: *AtomicFile) ReplaceError!void {
        if (self.file_open) {
            self.file.close();
            self.file_open = false;
        }
        const tmp_sub_path = std.fmt.hex(self.file_basename_hex);
        try self.dir.rename(&tmp_sub_path, self.dir, self.dest_sub_path);
        self.file_exists = false;
    }
};

fn atomicFileInit(dest_sub_path: []const u8, dir: Dir, close_dir_on_deinit: bool, options: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!AtomicFile {
    while (true) {
        var random_integer: u64 = undefined;
        random(std.mem.asBytes(&random_integer));
        const tmp_sub_path = std.fmt.hex(random_integer);
        const file = dir.createFile(&tmp_sub_path, .{
            .read = options.read,
            .exclusive = true,
            .mode = options.mode,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        return .{
            .file = file,
            .file_basename_hex = random_integer,
            .file_open = true,
            .file_exists = true,
            .dir = dir,
            .close_dir_on_deinit = close_dir_on_deinit,
            .dest_sub_path = dest_sub_path,
        };
    }
}

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

test "File: direct I/O round-trip" {
    // Direct I/O requires the buffer, offset, and length to be aligned to the
    // device's logical block size (O_DIRECT on Linux/BSD, FILE_FLAG_NO_BUFFERING
    // on Windows); macOS F_NOCACHE has no such constraint. A 4096-aligned,
    // 4096-byte transfer at offset 0 satisfies all of them. Windows is skipped:
    // unbuffered I/O there needs the exact sector size and is awkward to exercise
    // portably.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const file_path = "test_file_direct.bin";

    var file = dir.createFile(file_path, .{ .read = true, .direct = true }) catch |err| switch (err) {
        // Some filesystems (tmpfs, overlayfs, ...) reject O_DIRECT with EINVAL,
        // which surfaces as Unexpected. Nothing to exercise there.
        error.Unexpected => return error.SkipZigTest,
        else => return err,
    };
    defer dir.deleteFile(file_path) catch {};

    const block = 4096;
    var write_buf: [block]u8 align(block) = undefined;
    for (&write_buf, 0..) |*b, i| b.* = @truncate(i);

    // Write through the createFile(.direct) handle.
    try std.testing.expectEqual(block, try file.write(&write_buf, 0));
    file.close();

    // Read it back through a separate openFile(.direct) handle, exercising the
    // FileOpenFlags path as well as the FileCreateFlags one above.
    var read_file = try dir.openFile(file_path, .{ .mode = .read_only, .direct = true });
    defer read_file.close();

    var read_buf: [block]u8 align(block) = undefined;
    try std.testing.expectEqual(block, try read_file.read(&read_buf, 0));
    try std.testing.expectEqualSlices(u8, &write_buf, &read_buf);
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

test "Dir: createFileAtomic link" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dest_path = "test_atomic_file_link.txt";
    defer dir.deleteFile(dest_path) catch {};

    var af = try dir.createFileAtomic(dest_path, .{});
    defer af.deinit();

    _ = try af.file.write("atomic", 0);
    try af.link();

    var file = try dir.openFile(dest_path, .{ .mode = .read_only });
    defer file.close();
    var buffer: [16]u8 = undefined;
    const n = try file.read(&buffer, 0);
    try std.testing.expectEqualStrings("atomic", buffer[0..n]);
}

test "Dir: createFileAtomic link to existing destination" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dest_path = "test_atomic_file_link_existing.txt";
    defer dir.deleteFile(dest_path) catch {};

    var dest = try dir.createFile(dest_path, .{});
    _ = try dest.write("old", 0);
    dest.close();

    var af = try dir.createFileAtomic(dest_path, .{});
    const tmp_sub_path = std.fmt.hex(af.file_basename_hex);
    defer dir.deleteFile(&tmp_sub_path) catch {};

    _ = try af.file.write("new", 0);
    try std.testing.expectError(error.PathAlreadyExists, af.link());
    af.deinit();

    // The temporary file was cleaned up and the destination is unchanged.
    try std.testing.expectError(error.FileNotFound, dir.access(&tmp_sub_path, .{}));

    var file = try dir.openFile(dest_path, .{ .mode = .read_only });
    defer file.close();
    var buffer: [16]u8 = undefined;
    const n = try file.read(&buffer, 0);
    try std.testing.expectEqualStrings("old", buffer[0..n]);
}

test "Dir: createFileAtomic replace existing destination" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dest_path = "test_atomic_file_replace.txt";
    defer dir.deleteFile(dest_path) catch {};

    var dest = try dir.createFile(dest_path, .{});
    _ = try dest.write("old", 0);
    dest.close();

    var af = try dir.createFileAtomic(dest_path, .{});
    defer af.deinit();

    _ = try af.file.write("new", 0);
    try af.replace();

    var file = try dir.openFile(dest_path, .{ .mode = .read_only });
    defer file.close();
    var buffer: [16]u8 = undefined;
    const n = try file.read(&buffer, 0);
    try std.testing.expectEqualStrings("new", buffer[0..n]);
}

test "Dir: createFileAtomic in subdirectory" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const sub_dir_path = "test_atomic_file_subdir.tmp";
    try dir.createDir(sub_dir_path, 0o755);
    defer dir.deleteTree(sub_dir_path) catch {};

    var af = try dir.createFileAtomic(sub_dir_path ++ "/dest.txt", .{});
    defer af.deinit();

    _ = try af.file.write("atomic", 0);
    try af.link();

    var file = try dir.openFile(sub_dir_path ++ "/dest.txt", .{ .mode = .read_only });
    defer file.close();
    var buffer: [16]u8 = undefined;
    const n = try file.read(&buffer, 0);
    try std.testing.expectEqualStrings("atomic", buffer[0..n]);
}

test "Dir: createFileAtomic deinit without link removes temporary file" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const dir = Dir.cwd();
    const dest_path = "test_atomic_file_abandoned.txt";

    var af = try dir.createFileAtomic(dest_path, .{});
    const tmp_sub_path = std.fmt.hex(af.file_basename_hex);
    defer dir.deleteFile(&tmp_sub_path) catch {};

    _ = try af.file.write("abandoned", 0);
    af.deinit();

    try std.testing.expectError(error.FileNotFound, dir.access(&tmp_sub_path, .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(dest_path, .{}));
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

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "Dir: canceling a blocking open interrupts the worker" {
    // Only exercises the thread-pool-delegated path (kqueue/poll and friends);
    // backends that open natively (io_uring) cancel via the backend instead, and
    // the SIGURG mechanism is POSIX-only.
    if (ev.Backend.capabilities.file_open) return;
    if (!os.syscall_cancel.enabled) return;

    // A FIFO opened O_RDONLY with no writer blocks in the worker's openat(). On
    // POSIX the open is unconditionally blocking (O_NONBLOCK is applied only
    // *after* open, in probePollable), so this reliably parks a worker we can
    // then interrupt.
    const path = "zig-cache-zio-open-cancel.fifo";
    _ = std.c.unlink(path);
    try std.testing.expectEqual(0, mkfifo(path, 0o600));
    defer _ = std.c.unlink(path);

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const worker = struct {
        fn call(p: []const u8, result: *(Dir.OpenFileError!void)) void {
            if (openFile(p)) |file| {
                file.close();
                result.* = {};
            } else |err| {
                result.* = err;
            }
        }
    };

    var result: Dir.OpenFileError!void = {};
    var handle = try rt.spawn(worker.call, .{ path, &result });

    // Let the worker reach the blocking open, then cancel. The loop re-sends
    // SIGURG each tick until the worker acknowledges (covering a lost first
    // signal), so the open returns error.Canceled.
    try rt.sleep(.fromMilliseconds(50));
    handle.cancel();
    handle.join();

    try std.testing.expectError(error.Canceled, result);
}

test "Dir: iterate" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();
    const dir_path = "test_dir_iterate";
    try cwd.createDir(dir_path, 0o755);
    defer cwd.deleteDir(dir_path) catch {};

    var dir = try cwd.openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    (try dir.createFile("a.txt", .{})).close();
    (try dir.createFile("b.txt", .{})).close();
    try dir.createDir("sub", 0o755);
    defer {
        dir.deleteFile("a.txt") catch {};
        dir.deleteFile("b.txt") catch {};
        dir.deleteDir("sub") catch {};
    }

    var found_a = false;
    var found_b = false;
    var found_sub = false;
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "a.txt")) found_a = true;
        if (std.mem.eql(u8, entry.name, "b.txt")) found_b = true;
        if (std.mem.eql(u8, entry.name, "sub")) {
            found_sub = true;
            try std.testing.expectEqual(os.fs.FileKind.directory, entry.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(found_a and found_b and found_sub);
}

test "Dir: deleteTree" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();
    const root_path = "test_dir_delete_tree";
    try cwd.createDir(root_path, 0o755);
    errdefer cwd.deleteTree(root_path) catch {};

    // Close all handles into the tree before deleting; Windows cannot delete
    // directories that still have open handles.
    {
        const root = try cwd.openDir(root_path, .{});
        defer root.close();

        (try root.createFile("a.txt", .{})).close();
        try root.createDir("sub", 0o755);
        const sub = try root.openDir("sub", .{});
        defer sub.close();
        (try sub.createFile("b.txt", .{})).close();
        try sub.createDir("deeper", 0o755);
        const deeper = try sub.openDir("deeper", .{});
        defer deeper.close();
        (try deeper.createFile("c.txt", .{})).close();

        // A symlink inside the tree must be removed itself, not followed.
        if (builtin.os.tag != .windows) {
            (try root.createFile("target.txt", .{})).close();
            try sub.symLink("../target.txt", "link", .{});
        }
    }

    try cwd.deleteTree(root_path);
    try std.testing.expectError(error.FileNotFound, cwd.openDir(root_path, .{}));
}

test "Dir: deleteTree on a file and on a missing path" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();
    const file_path = "test_delete_tree_file.txt";
    (try cwd.createFile(file_path, .{})).close();

    try cwd.deleteTree(file_path);
    try std.testing.expectError(error.FileNotFound, cwd.openFile(file_path, .{}));

    // Deleting something that does not exist succeeds.
    try cwd.deleteTree("test_delete_tree_does_not_exist");
}

test "Dir: deleteTree deeply nested tree" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();
    const root_path = "test_dir_delete_tree_deep";
    try cwd.createDir(root_path, 0o755);
    errdefer cwd.deleteTree(root_path) catch {};

    // Nest beyond deleteTree's internal stack capacity (16) to exercise the
    // min-stack-size fallback.
    var dir = try cwd.openDir(root_path, .{});
    for (0..20) |_| {
        try dir.createDir("nested", 0o755);
        (try dir.createFile("file.txt", .{})).close();
        const next = try dir.openDir("nested", .{});
        dir.close();
        dir = next;
    }
    dir.close();

    try cwd.deleteTree(root_path);
    try std.testing.expectError(error.FileNotFound, cwd.openDir(root_path, .{}));
}

test "Dir: deleteTreeMinStackSize" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const cwd = Dir.cwd();
    const root_path = "test_dir_delete_tree_min_stack";
    try cwd.createDir(root_path, 0o755);
    errdefer cwd.deleteTree(root_path) catch {};

    {
        const root = try cwd.openDir(root_path, .{});
        defer root.close();
        (try root.createFile("a.txt", .{})).close();
        try root.createDir("sub", 0o755);
        const sub = try root.openDir("sub", .{});
        defer sub.close();
        (try sub.createFile("b.txt", .{})).close();
    }

    try cwd.deleteTreeMinStackSize(root_path);
    try std.testing.expectError(error.FileNotFound, cwd.openDir(root_path, .{}));
}
