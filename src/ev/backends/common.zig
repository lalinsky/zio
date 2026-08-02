const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("../completion.zig").Completion;
const Work = @import("../completion.zig").Work;
const DelegatedWork = @import("../completion.zig").DelegatedWork;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetShutdown = @import("../completion.zig").NetShutdown;
const NetClose = @import("../completion.zig").NetClose;
const FileOpen = @import("../completion.zig").FileOpen;
const FileCreate = @import("../completion.zig").FileCreate;
const FileClose = @import("../completion.zig").FileClose;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;
const FileReadStreaming = @import("../completion.zig").FileReadStreaming;
const FileWriteStreaming = @import("../completion.zig").FileWriteStreaming;
const FileSync = @import("../completion.zig").FileSync;
const FileSetSize = @import("../completion.zig").FileSetSize;
const FileSetPermissions = @import("../completion.zig").FileSetPermissions;
const FileSetOwner = @import("../completion.zig").FileSetOwner;
const FileSetTimestamps = @import("../completion.zig").FileSetTimestamps;
const DirCreateDir = @import("../completion.zig").DirCreateDir;
const DirRename = @import("../completion.zig").DirRename;
const DirRenamePreserve = @import("../completion.zig").DirRenamePreserve;
const DirDeleteFile = @import("../completion.zig").DirDeleteFile;
const DirDeleteDir = @import("../completion.zig").DirDeleteDir;
const FileSize = @import("../completion.zig").FileSize;
const FileStat = @import("../completion.zig").FileStat;
const DirOpen = @import("../completion.zig").DirOpen;
const DirClose = @import("../completion.zig").DirClose;
const DirSetPermissions = @import("../completion.zig").DirSetPermissions;
const DirSetOwner = @import("../completion.zig").DirSetOwner;
const DirSetFilePermissions = @import("../completion.zig").DirSetFilePermissions;
const DirSetFileOwner = @import("../completion.zig").DirSetFileOwner;
const DirSetFileTimestamps = @import("../completion.zig").DirSetFileTimestamps;
const DirSymLink = @import("../completion.zig").DirSymLink;
const DirReadLink = @import("../completion.zig").DirReadLink;
const DirHardLink = @import("../completion.zig").DirHardLink;
const DirAccess = @import("../completion.zig").DirAccess;
const DirRead = @import("../completion.zig").DirRead;
const DirRealPath = @import("../completion.zig").DirRealPath;
const DirRealPathFile = @import("../completion.zig").DirRealPathFile;
const FileRealPath = @import("../completion.zig").FileRealPath;
const FileHardLink = @import("../completion.zig").FileHardLink;
const DeviceIoControl = @import("../completion.zig").DeviceIoControl;
const ProcessWait = @import("../completion.zig").ProcessWait;
const net = @import("../../os/net.zig");
const fs = @import("../../os/fs.zig");

fn delegated(work: *Work) *DelegatedWork {
    return @fieldParentPtr("work", work);
}

fn opFromWork(work: *Work, comptime T: type) *T {
    return delegated(work).linked_context.linked.cast(T);
}

/// Helper to handle socket open operation
pub fn handleNetOpen(c: *Completion) void {
    const data = c.cast(NetOpen);
    if (net.socket(data.domain, data.socket_type, data.protocol, data.flags)) |handle| {
        c.setResult(.net_open, handle);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle bind operation with automatic getsockname call
pub fn handleNetBind(c: *Completion) void {
    const data = c.cast(NetBind);
    if (net.bind(data.handle, data.addr, data.addr_len.*)) |_| {
        // Update the address with the actual bound address
        if (net.getsockname(data.handle, data.addr, data.addr_len)) |_| {
            c.setResult(.net_bind, {});
        } else |err| {
            c.setError(err);
        }
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle listen operation
pub fn handleNetListen(c: *Completion) void {
    const data = c.cast(NetListen);
    if (net.listen(data.handle, data.backlog)) |_| {
        c.setResult(.net_listen, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle shutdown operation
pub fn handleNetShutdown(c: *Completion) void {
    const data = c.cast(NetShutdown);
    if (net.shutdown(data.handle, data.how)) |_| {
        c.setResult(.net_shutdown, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle close operation
pub fn handleNetClose(c: *Completion) void {
    const data = c.cast(NetClose);
    net.close(data.handle);
    c.setResult(.net_close, {});
}

/// Determine whether `handle` should use the direct I/O path for streaming:
/// pollable (non-seekable) fds return true. On POSIX, they are also switched to
/// non-blocking mode (required by the readiness poll path). Seekable fds (regular
/// files, block devices) return false.
pub fn probePollable(handle: fs.fd_t) bool {
    if (builtin.os.tag == .windows) {
        // On Windows, streaming (overlapped, zero-offset) I/O only works for
        // non-seekable handles (pipes/devices); no non-blocking mode to set.
        return @import("../../os/windows.zig").isPollable(handle);
    } else {
        const posix = @import("../../os/posix.zig");
        if (!posix.isPollable(handle)) return false;
        posix.setNonblocking(handle) catch return false;
        return true;
    }
}

pub fn handleFileOpen(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileOpen);
    if (fs.openat(allocator, data.dir, data.path, data.flags)) |fd| {
        c.setResult(.file_open, .{ .fd = fd, .pollable = probePollable(fd) });
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file create operation
pub fn handleFileCreate(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileCreate);
    if (fs.createat(allocator, data.dir, data.path, data.flags)) |fd| {
        c.setResult(.file_create, .{ .fd = fd, .pollable = probePollable(fd) });
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file close operation
pub fn handleFileClose(c: *Completion) void {
    const data = c.cast(FileClose);
    if (fs.close(data.handle)) |_| {
        c.setResult(.file_close, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file read operation
pub fn handleFileRead(c: *Completion) void {
    const data = c.cast(FileRead);
    if (fs.preadv(data.handle, data.buffer.iovecs, data.offset)) |bytes_read| {
        c.setResult(.file_read, bytes_read);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file write operation
pub fn handleFileWrite(c: *Completion) void {
    const data = c.cast(FileWrite);
    if (fs.pwritev(data.handle, data.buffer.iovecs, data.offset)) |bytes_written| {
        c.setResult(.file_write, bytes_written);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle streaming file read operation (uses current file position)
/// Block until `fd` is ready for `events` (POSIX poll). Used by the blocking
/// streaming handlers to wait on non-blocking pollable fds without an event loop.
fn pollForReady(fd: net.fd_t, events: i16) !void {
    var pfd = [_]net.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    _ = try net.poll(&pfd, -1);
}

pub fn handleFileReadStreaming(c: *Completion) void {
    const data = c.cast(FileReadStreaming);

    // Windows: blocking read, no readiness poll available.
    if (builtin.os.tag == .windows) {
        if (fs.readv(data.handle, data.buffer.iovecs)) |bytes_read| {
            c.setResult(.file_read_streaming, bytes_read);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // Pollable fds (pipes/sockets) are non-blocking: on WouldBlock, wait for
    // readiness and retry. Seekable (blocking) fds return on the first readv.
    while (true) {
        if (fs.readv(data.handle, data.buffer.iovecs)) |bytes_read| {
            c.setResult(.file_read_streaming, bytes_read);
            return;
        } else |err| switch (err) {
            error.WouldBlock => pollForReady(data.handle, net.POLL.IN) catch |perr| {
                c.setError(perr);
                return;
            },
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle streaming file write operation (uses current file position)
pub fn handleFileWriteStreaming(c: *Completion) void {
    const data = c.cast(FileWriteStreaming);

    // Windows: blocking write, no readiness poll available.
    if (builtin.os.tag == .windows) {
        if (fs.writev(data.handle, data.buffer.iovecs)) |bytes_written| {
            c.setResult(.file_write_streaming, bytes_written);
        } else |err| {
            c.setError(err);
        }
        return;
    }

    // Pollable fds (pipes/sockets) are non-blocking: on WouldBlock, wait for
    // writability and retry. Seekable (blocking) fds return on the first writev.
    while (true) {
        if (fs.writev(data.handle, data.buffer.iovecs)) |bytes_written| {
            c.setResult(.file_write_streaming, bytes_written);
            return;
        } else |err| switch (err) {
            error.WouldBlock => pollForReady(data.handle, net.POLL.OUT) catch |perr| {
                c.setError(perr);
                return;
            },
            else => {
                c.setError(err);
                return;
            },
        }
    }
}

/// Helper to handle file sync operation
pub fn handleFileSync(c: *Completion) void {
    const data = c.cast(FileSync);
    if (fs.fileSync(data.handle, data.flags)) |_| {
        c.setResult(.file_sync, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file set size operation
pub fn handleFileSetSize(c: *Completion) void {
    const data = c.cast(FileSetSize);
    if (fs.fileSetSize(data.handle, data.length)) |_| {
        c.setResult(.file_set_size, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file set permissions operation
pub fn handleFileSetPermissions(c: *Completion) void {
    const data = c.cast(FileSetPermissions);
    if (fs.fileSetPermissions(data.handle, data.mode)) |_| {
        c.setResult(.file_set_permissions, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file set owner operation
pub fn handleFileSetOwner(c: *Completion) void {
    const data = c.cast(FileSetOwner);
    if (fs.fileSetOwner(data.handle, data.uid, data.gid)) |_| {
        c.setResult(.file_set_owner, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file set timestamps operation
pub fn handleFileSetTimestamps(c: *Completion) void {
    const data = c.cast(FileSetTimestamps);
    if (fs.fileSetTimestamps(data.handle, data.timestamps)) |_| {
        c.setResult(.file_set_timestamps, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileOpen - performs blocking openat() syscall
pub fn fileOpenWork(work: *Work) void {
    const linked_work = delegated(work);
    const file_open = opFromWork(work, FileOpen);
    const loop = linked_work.linked_context.loop;

    if (@TypeOf(loop.backend).supports_nonblocking_file_io) {
        file_open.flags.nonblocking = true;
    }

    handleFileOpen(&file_open.c, linked_work.allocator);

    // If the operation failed, exit early
    if (file_open.c.err != null) return;

    // If the file was successfully opened, give the backend a chance to post-process the handle
    if (@hasDecl(@TypeOf(loop.backend), "postProcessFileHandle")) {
        loop.backend.postProcessFileHandle(file_open.result_private_do_not_touch.fd) catch |err| {
            // Failed to post-process - close the file and set error
            fs.close(file_open.result_private_do_not_touch.fd) catch {};
            file_open.c.has_result = false;
            file_open.c.setError(err);
        };
    }
}

/// Work function for FileCreate - performs blocking openat() syscall with O_CREAT
pub fn fileCreateWork(work: *Work) void {
    const linked_work = delegated(work);
    const file_create = opFromWork(work, FileCreate);
    const loop = linked_work.linked_context.loop;

    if (@TypeOf(loop.backend).supports_nonblocking_file_io) {
        file_create.flags.nonblocking = true;
    }

    handleFileCreate(&file_create.c, linked_work.allocator);

    // If the operation failed, exit early
    if (file_create.c.err != null) return;

    // If the file was successfully created, give the backend a chance to post-process the handle
    if (@hasDecl(@TypeOf(loop.backend), "postProcessFileHandle")) {
        loop.backend.postProcessFileHandle(file_create.result_private_do_not_touch.fd) catch |err| {
            // Failed to post-process - close the file and set error
            fs.close(file_create.result_private_do_not_touch.fd) catch {};
            file_create.c.has_result = false;
            file_create.c.setError(err);
        };
    }
}

/// Work function for FileClose - performs blocking close() syscall
pub fn fileCloseWork(work: *Work) void {
    const file_close = opFromWork(work, FileClose);
    handleFileClose(&file_close.c);
}

/// Work function for FileRead - performs blocking preadv() syscall
pub fn fileReadWork(work: *Work) void {
    const file_read = opFromWork(work, FileRead);
    handleFileRead(&file_read.c);
}

/// Work function for FileWrite - performs blocking pwritev() syscall
pub fn fileWriteWork(work: *Work) void {
    const file_write = opFromWork(work, FileWrite);
    handleFileWrite(&file_write.c);
}

/// Work function for FileReadStreaming - performs blocking readv() syscall
pub fn fileReadStreamingWork(work: *Work) void {
    const file_read = opFromWork(work, FileReadStreaming);
    handleFileReadStreaming(&file_read.c);
}

/// Work function for FileWriteStreaming - performs blocking writev() syscall
pub fn fileWriteStreamingWork(work: *Work) void {
    const file_write = opFromWork(work, FileWriteStreaming);
    handleFileWriteStreaming(&file_write.c);
}

/// Work function for FileSync - performs blocking fsync()/fdatasync() syscall
pub fn fileSyncWork(work: *Work) void {
    const file_sync = opFromWork(work, FileSync);
    handleFileSync(&file_sync.c);
}

/// Work function for FileSetSize - performs blocking ftruncate() syscall
pub fn fileSetSizeWork(work: *Work) void {
    const file_set_size = opFromWork(work, FileSetSize);
    handleFileSetSize(&file_set_size.c);
}

/// Work function for FileSetPermissions - performs blocking fchmod() syscall
pub fn fileSetPermissionsWork(work: *Work) void {
    const file_set_permissions = opFromWork(work, FileSetPermissions);
    handleFileSetPermissions(&file_set_permissions.c);
}

/// Work function for FileSetOwner - performs blocking fchown() syscall
pub fn fileSetOwnerWork(work: *Work) void {
    const file_set_owner = opFromWork(work, FileSetOwner);
    handleFileSetOwner(&file_set_owner.c);
}

/// Work function for FileSetTimestamps - performs blocking futimens() syscall
pub fn fileSetTimestampsWork(work: *Work) void {
    const file_set_timestamps = opFromWork(work, FileSetTimestamps);
    handleFileSetTimestamps(&file_set_timestamps.c);
}

/// Helper to handle dir set permissions operation (on handle)
pub fn handleDirSetPermissions(c: *Completion) void {
    const data = c.cast(DirSetPermissions);
    if (fs.fileSetPermissions(data.handle, data.mode)) |_| {
        c.setResult(.dir_set_permissions, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSetPermissions
pub fn dirSetPermissionsWork(work: *Work) void {
    const data = opFromWork(work, DirSetPermissions);
    handleDirSetPermissions(&data.c);
}

/// Helper to handle dir set owner operation (on handle)
pub fn handleDirSetOwner(c: *Completion) void {
    const data = c.cast(DirSetOwner);
    if (fs.fileSetOwner(data.handle, data.uid, data.gid)) |_| {
        c.setResult(.dir_set_owner, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSetOwner
pub fn dirSetOwnerWork(work: *Work) void {
    const data = opFromWork(work, DirSetOwner);
    handleDirSetOwner(&data.c);
}

/// Helper to handle dir set file permissions operation
pub fn handleDirSetFilePermissions(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirSetFilePermissions);
    if (fs.dirSetFilePermissions(allocator, data.dir, data.path, data.mode, data.flags)) |_| {
        c.setResult(.dir_set_file_permissions, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSetFilePermissions
pub fn dirSetFilePermissionsWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirSetFilePermissions);
    handleDirSetFilePermissions(&data.c, linked_work.allocator);
}

/// Helper to handle dir set file owner operation
pub fn handleDirSetFileOwner(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirSetFileOwner);
    if (fs.dirSetFileOwner(allocator, data.dir, data.path, data.uid, data.gid, data.flags)) |_| {
        c.setResult(.dir_set_file_owner, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSetFileOwner
pub fn dirSetFileOwnerWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirSetFileOwner);
    handleDirSetFileOwner(&data.c, linked_work.allocator);
}

/// Helper to handle dir set file timestamps operation
pub fn handleDirSetFileTimestamps(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirSetFileTimestamps);
    if (fs.dirSetFileTimestamps(allocator, data.dir, data.path, data.timestamps, data.flags)) |_| {
        c.setResult(.dir_set_file_timestamps, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSetFileTimestamps
pub fn dirSetFileTimestampsWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirSetFileTimestamps);
    handleDirSetFileTimestamps(&data.c, linked_work.allocator);
}

/// Helper to handle dir sym link operation
pub fn handleDirSymLink(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirSymLink);
    if (fs.dirSymLink(allocator, data.dir, data.target, data.link_path, data.flags)) |_| {
        c.setResult(.dir_sym_link, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirSymLink
pub fn dirSymLinkWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirSymLink);
    handleDirSymLink(&data.c, linked_work.allocator);
}

/// Helper to handle dir read link operation
pub fn handleDirReadLink(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirReadLink);
    if (fs.dirReadLink(allocator, data.dir, data.path, data.buffer)) |len| {
        c.setResult(.dir_read_link, len);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirReadLink
pub fn dirReadLinkWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirReadLink);
    handleDirReadLink(&data.c, linked_work.allocator);
}

/// Helper to handle dir hard link operation
pub fn handleDirHardLink(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirHardLink);
    if (fs.dirHardLink(allocator, data.old_dir, data.old_path, data.new_dir, data.new_path, data.flags)) |_| {
        c.setResult(.dir_hard_link, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirHardLink
pub fn dirHardLinkWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirHardLink);
    handleDirHardLink(&data.c, linked_work.allocator);
}

/// Helper to handle dir access operation
pub fn handleDirAccess(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirAccess);
    if (fs.dirAccess(allocator, data.dir, data.path, data.flags)) |_| {
        c.setResult(.dir_access, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirAccess
pub fn dirAccessWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirAccess);
    handleDirAccess(&data.c, linked_work.allocator);
}

/// Helper to handle dir read operation
pub fn handleDirRead(c: *Completion) void {
    const data = c.cast(DirRead);
    const buffer = fs.DirEntryIterator.getUnreservedBuffer(data.buffer);
    if (fs.dirRead(data.handle, buffer, data.restart)) |bytes| {
        c.setResult(.dir_read, bytes);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirRead
pub fn dirReadWork(work: *Work) void {
    const data = opFromWork(work, DirRead);
    handleDirRead(&data.c);
}

/// Helper to handle dir real path operation
pub fn handleDirRealPath(c: *Completion) void {
    const data = c.cast(DirRealPath);
    if (fs.dirRealPath(data.fd, data.buffer)) |len| {
        c.setResult(.dir_real_path, len);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirRealPath
pub fn dirRealPathWork(work: *Work) void {
    const data = opFromWork(work, DirRealPath);
    handleDirRealPath(&data.c);
}

/// Helper to handle dir real path file operation
pub fn handleDirRealPathFile(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirRealPathFile);
    if (fs.dirRealPathFile(allocator, data.dir, data.path, data.buffer)) |len| {
        c.setResult(.dir_real_path_file, len);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirRealPathFile
pub fn dirRealPathFileWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, DirRealPathFile);
    handleDirRealPathFile(&data.c, linked_work.allocator);
}

/// Helper to handle file real path operation
pub fn handleFileRealPath(c: *Completion) void {
    const data = c.cast(FileRealPath);
    if (fs.dirRealPath(data.fd, data.buffer)) |len| {
        c.setResult(.file_real_path, len);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileRealPath
pub fn fileRealPathWork(work: *Work) void {
    const data = opFromWork(work, FileRealPath);
    handleFileRealPath(&data.c);
}

/// Helper to handle file hard link operation
pub fn handleFileHardLink(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileHardLink);
    if (fs.fileHardLink(allocator, data.fd, data.new_dir, data.new_path, data.flags)) |_| {
        c.setResult(.file_hard_link, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileHardLink
pub fn fileHardLinkWork(work: *Work) void {
    const linked_work = delegated(work);
    const data = opFromWork(work, FileHardLink);
    handleFileHardLink(&data.c, linked_work.allocator);
}

/// Helper to handle dir create dir operation
pub fn handleDirCreateDir(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirCreateDir);
    if (fs.mkdirat(allocator, data.dir, data.path, data.mode)) |_| {
        c.setResult(.dir_create_dir, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle dir rename operation
pub fn handleDirRename(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirRename);
    if (fs.renameat(allocator, data.old_dir, data.old_path, data.new_dir, data.new_path)) |_| {
        c.setResult(.dir_rename, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle dir rename preserve operation
pub fn handleDirRenamePreserve(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirRenamePreserve);
    if (fs.renameatPreserve(allocator, data.old_dir, data.old_path, data.new_dir, data.new_path)) |_| {
        c.setResult(.dir_rename_preserve, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle dir delete file operation
pub fn handleDirDeleteFile(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirDeleteFile);
    if (fs.dirDeleteFile(allocator, data.dir, data.path)) |_| {
        c.setResult(.dir_delete_file, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle dir delete dir operation
pub fn handleDirDeleteDir(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirDeleteDir);
    if (fs.dirDeleteDir(allocator, data.dir, data.path)) |_| {
        c.setResult(.dir_delete_dir, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirCreateDir - performs blocking mkdirat() syscall
pub fn dirCreateDirWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_create_dir = opFromWork(work, DirCreateDir);
    handleDirCreateDir(&dir_create_dir.c, linked_work.allocator);
}

/// Work function for DirRename - performs blocking renameat() syscall
pub fn dirRenameWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_rename = opFromWork(work, DirRename);
    handleDirRename(&dir_rename.c, linked_work.allocator);
}

/// Work function for DirRenamePreserve - performs blocking renameat2() syscall with NOREPLACE
pub fn dirRenamePreserveWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_rename_preserve = opFromWork(work, DirRenamePreserve);
    handleDirRenamePreserve(&dir_rename_preserve.c, linked_work.allocator);
}

/// Work function for DirDeleteFile - performs blocking unlinkat() syscall
pub fn dirDeleteFileWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_delete_file = opFromWork(work, DirDeleteFile);
    handleDirDeleteFile(&dir_delete_file.c, linked_work.allocator);
}

/// Work function for DirDeleteDir - performs blocking unlinkat() syscall with AT_REMOVEDIR
pub fn dirDeleteDirWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_delete_dir = opFromWork(work, DirDeleteDir);
    handleDirDeleteDir(&dir_delete_dir.c, linked_work.allocator);
}

/// Helper to handle file size operation
pub fn handleFileSize(c: *Completion) void {
    const data = c.cast(FileSize);
    if (fs.fileSize(data.handle)) |size| {
        c.setResult(.file_size, size);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileSize - performs blocking fstat() syscall
pub fn fileSizeWork(work: *Work) void {
    const file_size = opFromWork(work, FileSize);
    handleFileSize(&file_size.c);
}

/// Helper to handle file stat operation
/// If path is null, stats the file descriptor directly (fstat).
/// If path is provided, stats the file at path relative to handle (fstatat).
pub fn handleFileStat(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileStat);
    const result = if (data.path) |path|
        fs.fstatat(allocator, data.handle, path, data.flags)
    else
        fs.fstat(data.handle);

    if (result) |stat| {
        c.setResult(.file_stat, stat);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileStat - performs blocking fstat()/fstatat() syscall
pub fn fileStatWork(work: *Work) void {
    const linked_work = delegated(work);
    const file_stat = opFromWork(work, FileStat);
    handleFileStat(&file_stat.c, linked_work.allocator);
}

/// Helper to handle directory open operation
pub fn handleDirOpen(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(DirOpen);
    if (fs.dirOpen(allocator, data.dir, data.path, data.flags)) |fd| {
        c.setResult(.dir_open, fd);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirOpen - performs blocking openat() syscall
pub fn dirOpenWork(work: *Work) void {
    const linked_work = delegated(work);
    const dir_open = opFromWork(work, DirOpen);
    handleDirOpen(&dir_open.c, linked_work.allocator);
}

/// Helper to handle directory close operation
pub fn handleDirClose(c: *Completion) void {
    const data = c.cast(DirClose);
    if (fs.close(data.handle)) |_| {
        c.setResult(.dir_close, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirClose - performs blocking close() syscall
pub fn dirCloseWork(work: *Work) void {
    const dir_close = opFromWork(work, DirClose);
    handleDirClose(&dir_close.c);
}

/// Helper to handle process wait operation
pub fn handleProcessWait(c: *Completion) void {
    const data = c.cast(ProcessWait);

    if (builtin.os.tag == .windows) {
        const windows = @import("../../os/windows.zig");
        // Wait for the process to exit
        const wait_result = windows.WaitForSingleObject(data.handle, windows.INFINITE);
        if (wait_result != windows.WAIT_OBJECT_0) {
            c.setError(error.Unexpected);
            return;
        }
        // Get the exit code
        var exit_code: windows.DWORD = 0;
        if (windows.GetExitCodeProcess(data.handle, &exit_code) == .FALSE) {
            c.setError(error.Unexpected);
            return;
        }
        c.setResult(.process_wait, .{
            .code = @truncate(exit_code),
            .signal = null, // Windows doesn't have signals
        });
    } else if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const posix = @import("../../os/posix.zig");
        var siginfo: linux.siginfo_t = undefined;
        const rc = linux.waitid(.PID, data.handle, &siginfo, linux.W.EXITED, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                // With waitid(), si_status contains the value directly (not encoded like waitpid)
                const si_status = siginfo.fields.common.second.sigchld.status;
                const si_code = siginfo.code;
                const CLD_EXITED = 1;
                const CLD_KILLED = 2;
                const CLD_DUMPED = 3;
                const terminated_by_signal = (si_code == CLD_KILLED or si_code == CLD_DUMPED);
                c.setResult(.process_wait, .{
                    .code = if (si_code == CLD_EXITED) @intCast(si_status) else 0,
                    .signal = if (terminated_by_signal) @intCast(si_status) else null,
                });
            },
            .CHILD => c.setError(error.ProcessNotFound),
            else => c.setError(error.Unexpected),
        }
    } else {
        // macOS, BSDs - use waitpid via libc
        var status: c_int = 0;
        const rc = std.c.waitpid(data.handle, &status, 0);
        if (rc < 0) {
            c.setError(error.Unexpected);
        } else {
            // Decode wait status (WEXITSTATUS and WTERMSIG equivalent)
            const ustatus: u32 = @bitCast(status);
            const exit_code: u8 = @intCast((ustatus >> 8) & 0xff);
            const signal_num: u8 = @intCast(ustatus & 0x7f);
            c.setResult(.process_wait, .{
                .code = exit_code,
                .signal = if (signal_num != 0) signal_num else null,
            });
        }
    }
}

/// Work function for ProcessWait - performs blocking wait for process exit
pub fn processWaitWork(work: *Work) void {
    const process_wait = opFromWork(work, ProcessWait);
    handleProcessWait(&process_wait.c);
}

/// Work function for DeviceIoControl - performs blocking ioctl
pub fn deviceIoControlWork(work: *Work) void {
    const device_io_control = opFromWork(work, DeviceIoControl);
    handleDeviceIoControl(&device_io_control.c);
}

pub fn handleDeviceIoControl(c: *Completion) void {
    const data = c.cast(DeviceIoControl);
    if (builtin.os.tag == .windows) {
        c.setResult(.device_io_control, fs.ioctl(data.handle, data.code, data.in, data.out));
    } else {
        c.setResult(.device_io_control, fs.ioctl(data.handle, data.code, data.arg));
    }
}
