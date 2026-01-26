const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const Completion = @import("../completion.zig").Completion;
const Work = @import("../completion.zig").Work;
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
const FileSync = @import("../completion.zig").FileSync;
const FileSetSize = @import("../completion.zig").FileSetSize;
const FileSetPermissions = @import("../completion.zig").FileSetPermissions;
const FileSetOwner = @import("../completion.zig").FileSetOwner;
const FileSetTimestamps = @import("../completion.zig").FileSetTimestamps;
const DirCreateDir = @import("../completion.zig").DirCreateDir;
const DirRename = @import("../completion.zig").DirRename;
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
const net = @import("../../os/net.zig");
const fs = @import("../../os/fs.zig");

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

/// Helper to handle file open operation
pub fn handleFileOpen(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileOpen);
    if (fs.openat(allocator, data.dir, data.path, data.flags)) |fd| {
        c.setResult(.file_open, fd);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file create operation
pub fn handleFileCreate(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileCreate);
    if (fs.createat(allocator, data.dir, data.path, data.flags)) |fd| {
        c.setResult(.file_create, fd);
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
    const internal: *@FieldType(FileOpen, "internal") = @fieldParentPtr("work", work);
    const file_open: *FileOpen = @fieldParentPtr("internal", internal);
    const loop = internal.linked_context.loop;

    if (@TypeOf(loop.backend).capabilities.supportsNonBlockingFileIo()) {
        file_open.flags.nonblocking = true;
    }

    handleFileOpen(&file_open.c, file_open.internal.allocator);

    // If the operation failed, exit early
    if (file_open.c.err != null) return;

    // If the file was successfully opened, give the backend a chance to post-process the handle
    if (@hasDecl(@TypeOf(loop.backend), "postProcessFileHandle")) {
        loop.backend.postProcessFileHandle(file_open.result_private_do_not_touch) catch |err| {
            // Failed to post-process - close the file and set error
            fs.close(file_open.result_private_do_not_touch) catch {};
            file_open.c.has_result = false;
            file_open.c.setError(err);
        };
    }
}

/// Work function for FileCreate - performs blocking openat() syscall with O_CREAT
pub fn fileCreateWork(work: *Work) void {
    const internal: *@FieldType(FileCreate, "internal") = @fieldParentPtr("work", work);
    const file_create: *FileCreate = @fieldParentPtr("internal", internal);
    const loop = internal.linked_context.loop;

    if (@TypeOf(loop.backend).capabilities.supportsNonBlockingFileIo()) {
        file_create.flags.nonblocking = true;
    }

    handleFileCreate(&file_create.c, file_create.internal.allocator);

    // If the operation failed, exit early
    if (file_create.c.err != null) return;

    // If the file was successfully created, give the backend a chance to post-process the handle
    if (@hasDecl(@TypeOf(loop.backend), "postProcessFileHandle")) {
        loop.backend.postProcessFileHandle(file_create.result_private_do_not_touch) catch |err| {
            // Failed to post-process - close the file and set error
            fs.close(file_create.result_private_do_not_touch) catch {};
            file_create.c.has_result = false;
            file_create.c.setError(err);
        };
    }
}

/// Work function for FileClose - performs blocking close() syscall
pub fn fileCloseWork(work: *Work) void {
    const internal: *@FieldType(FileClose, "internal") = @fieldParentPtr("work", work);
    const file_close: *FileClose = @fieldParentPtr("internal", internal);
    handleFileClose(&file_close.c);
}

/// Work function for FileRead - performs blocking preadv() syscall
pub fn fileReadWork(work: *Work) void {
    const internal: *@FieldType(FileRead, "internal") = @fieldParentPtr("work", work);
    const file_read: *FileRead = @alignCast(@fieldParentPtr("internal", internal));
    handleFileRead(&file_read.c);
}

/// Work function for FileWrite - performs blocking pwritev() syscall
pub fn fileWriteWork(work: *Work) void {
    const internal: *@FieldType(FileWrite, "internal") = @fieldParentPtr("work", work);
    const file_write: *FileWrite = @alignCast(@fieldParentPtr("internal", internal));
    handleFileWrite(&file_write.c);
}

/// Work function for FileSync - performs blocking fsync()/fdatasync() syscall
pub fn fileSyncWork(work: *Work) void {
    const internal: *@FieldType(FileSync, "internal") = @fieldParentPtr("work", work);
    const file_sync: *FileSync = @fieldParentPtr("internal", internal);
    handleFileSync(&file_sync.c);
}

/// Work function for FileSetSize - performs blocking ftruncate() syscall
pub fn fileSetSizeWork(work: *Work) void {
    const internal: *@FieldType(FileSetSize, "internal") = @fieldParentPtr("work", work);
    const file_set_size: *FileSetSize = @alignCast(@fieldParentPtr("internal", internal));
    handleFileSetSize(&file_set_size.c);
}

/// Work function for FileSetPermissions - performs blocking fchmod() syscall
pub fn fileSetPermissionsWork(work: *Work) void {
    const internal: *@FieldType(FileSetPermissions, "internal") = @fieldParentPtr("work", work);
    const file_set_permissions: *FileSetPermissions = @fieldParentPtr("internal", internal);
    handleFileSetPermissions(&file_set_permissions.c);
}

/// Work function for FileSetOwner - performs blocking fchown() syscall
pub fn fileSetOwnerWork(work: *Work) void {
    const internal: *@FieldType(FileSetOwner, "internal") = @fieldParentPtr("work", work);
    const file_set_owner: *FileSetOwner = @fieldParentPtr("internal", internal);
    handleFileSetOwner(&file_set_owner.c);
}

/// Work function for FileSetTimestamps - performs blocking futimens() syscall
pub fn fileSetTimestampsWork(work: *Work) void {
    const internal: *@FieldType(FileSetTimestamps, "internal") = @fieldParentPtr("work", work);
    const file_set_timestamps: *FileSetTimestamps = @alignCast(@fieldParentPtr("internal", internal));
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
    const internal: *@FieldType(DirSetPermissions, "internal") = @fieldParentPtr("work", work);
    const data: *DirSetPermissions = @fieldParentPtr("internal", internal);
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
    const internal: *@FieldType(DirSetOwner, "internal") = @fieldParentPtr("work", work);
    const data: *DirSetOwner = @fieldParentPtr("internal", internal);
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
    const internal: *@FieldType(DirSetFilePermissions, "internal") = @fieldParentPtr("work", work);
    const data: *DirSetFilePermissions = @fieldParentPtr("internal", internal);
    handleDirSetFilePermissions(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirSetFileOwner, "internal") = @fieldParentPtr("work", work);
    const data: *DirSetFileOwner = @fieldParentPtr("internal", internal);
    handleDirSetFileOwner(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirSetFileTimestamps, "internal") = @fieldParentPtr("work", work);
    const data: *DirSetFileTimestamps = @alignCast(@fieldParentPtr("internal", internal));
    handleDirSetFileTimestamps(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirSymLink, "internal") = @fieldParentPtr("work", work);
    const data: *DirSymLink = @fieldParentPtr("internal", internal);
    handleDirSymLink(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirReadLink, "internal") = @fieldParentPtr("work", work);
    const data: *DirReadLink = @fieldParentPtr("internal", internal);
    handleDirReadLink(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirHardLink, "internal") = @fieldParentPtr("work", work);
    const data: *DirHardLink = @fieldParentPtr("internal", internal);
    handleDirHardLink(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirAccess, "internal") = @fieldParentPtr("work", work);
    const data: *DirAccess = @fieldParentPtr("internal", internal);
    handleDirAccess(&data.c, data.internal.allocator);
}

/// Helper to handle dir read operation
pub fn handleDirRead(c: *Completion) void {
    const data = c.cast(DirRead);
    if (fs.dirRead(data.handle, data.buffer, data.restart)) |bytes| {
        c.setResult(.dir_read, bytes);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for DirRead
pub fn dirReadWork(work: *Work) void {
    const internal: *@FieldType(DirRead, "internal") = @fieldParentPtr("work", work);
    const data: *DirRead = @fieldParentPtr("internal", internal);
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
    const internal: *@FieldType(DirRealPath, "internal") = @fieldParentPtr("work", work);
    const data: *DirRealPath = @fieldParentPtr("internal", internal);
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
    const internal: *@FieldType(DirRealPathFile, "internal") = @fieldParentPtr("work", work);
    const data: *DirRealPathFile = @fieldParentPtr("internal", internal);
    handleDirRealPathFile(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(FileRealPath, "internal") = @fieldParentPtr("work", work);
    const data: *FileRealPath = @fieldParentPtr("internal", internal);
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
    const internal: *@FieldType(FileHardLink, "internal") = @fieldParentPtr("work", work);
    const data: *FileHardLink = @fieldParentPtr("internal", internal);
    handleFileHardLink(&data.c, data.internal.allocator);
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
    const internal: *@FieldType(DirCreateDir, "internal") = @fieldParentPtr("work", work);
    const dir_create_dir: *DirCreateDir = @fieldParentPtr("internal", internal);
    handleDirCreateDir(&dir_create_dir.c, dir_create_dir.internal.allocator);
}

/// Work function for DirRename - performs blocking renameat() syscall
pub fn dirRenameWork(work: *Work) void {
    const internal: *@FieldType(DirRename, "internal") = @fieldParentPtr("work", work);
    const dir_rename: *DirRename = @fieldParentPtr("internal", internal);
    handleDirRename(&dir_rename.c, dir_rename.internal.allocator);
}

/// Work function for DirDeleteFile - performs blocking unlinkat() syscall
pub fn dirDeleteFileWork(work: *Work) void {
    const internal: *@FieldType(DirDeleteFile, "internal") = @fieldParentPtr("work", work);
    const dir_delete_file: *DirDeleteFile = @fieldParentPtr("internal", internal);
    handleDirDeleteFile(&dir_delete_file.c, dir_delete_file.internal.allocator);
}

/// Work function for DirDeleteDir - performs blocking unlinkat() syscall with AT_REMOVEDIR
pub fn dirDeleteDirWork(work: *Work) void {
    const internal: *@FieldType(DirDeleteDir, "internal") = @fieldParentPtr("work", work);
    const dir_delete_dir: *DirDeleteDir = @fieldParentPtr("internal", internal);
    handleDirDeleteDir(&dir_delete_dir.c, dir_delete_dir.internal.allocator);
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
    const internal: *@FieldType(FileSize, "internal") = @fieldParentPtr("work", work);
    const file_size: *FileSize = @alignCast(@fieldParentPtr("internal", internal));
    handleFileSize(&file_size.c);
}

/// Helper to handle file stat operation
/// If path is null, stats the file descriptor directly (fstat).
/// If path is provided, stats the file at path relative to handle (fstatat).
pub fn handleFileStat(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileStat);
    const result = if (data.path) |path|
        fs.fstatat(allocator, data.handle, path)
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
    const internal: *@FieldType(FileStat, "internal") = @fieldParentPtr("work", work);
    const file_stat: *FileStat = @alignCast(@fieldParentPtr("internal", internal));
    handleFileStat(&file_stat.c, file_stat.internal.allocator);
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
    const internal: *@FieldType(DirOpen, "internal") = @fieldParentPtr("work", work);
    const dir_open: *DirOpen = @fieldParentPtr("internal", internal);
    handleDirOpen(&dir_open.c, dir_open.internal.allocator);
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
    const internal: *@FieldType(DirClose, "internal") = @fieldParentPtr("work", work);
    const dir_close: *DirClose = @fieldParentPtr("internal", internal);
    handleDirClose(&dir_close.c);
}
