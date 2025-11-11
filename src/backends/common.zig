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
const FileRename = @import("../completion.zig").FileRename;
const FileDelete = @import("../completion.zig").FileDelete;
const net = @import("../os/net.zig");
const fs = @import("../os/fs.zig");

/// Helper to handle socket open operation
pub fn handleNetOpen(c: *Completion) void {
    const data = c.cast(NetOpen);
    if (net.socket(data.domain, data.socket_type, data.flags)) |handle| {
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
    if (fs.sync(data.handle, data.flags)) |_| {
        c.setResult(.file_sync, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileOpen - performs blocking openat() syscall
pub fn fileOpenWork(work: *Work) void {
    const internal: *@FieldType(FileOpen, "internal") = @fieldParentPtr("work", work);
    const file_open: *FileOpen = @fieldParentPtr("internal", internal);
    handleFileOpen(&file_open.c, file_open.internal.allocator);
}

/// Work function for FileCreate - performs blocking openat() syscall with O_CREAT
pub fn fileCreateWork(work: *Work) void {
    const internal: *@FieldType(FileCreate, "internal") = @fieldParentPtr("work", work);
    const file_create: *FileCreate = @fieldParentPtr("internal", internal);
    handleFileCreate(&file_create.c, file_create.internal.allocator);
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
    const file_read: *FileRead = @fieldParentPtr("internal", internal);
    handleFileRead(&file_read.c);
}

/// Work function for FileWrite - performs blocking pwritev() syscall
pub fn fileWriteWork(work: *Work) void {
    const internal: *@FieldType(FileWrite, "internal") = @fieldParentPtr("work", work);
    const file_write: *FileWrite = @fieldParentPtr("internal", internal);
    handleFileWrite(&file_write.c);
}

/// Work function for FileSync - performs blocking fsync()/fdatasync() syscall
pub fn fileSyncWork(work: *Work) void {
    const internal: *@FieldType(FileSync, "internal") = @fieldParentPtr("work", work);
    const file_sync: *FileSync = @fieldParentPtr("internal", internal);
    handleFileSync(&file_sync.c);
}

/// Helper to handle file rename operation
pub fn handleFileRename(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileRename);
    if (fs.renameat(allocator, data.old_dir, data.old_path, data.new_dir, data.new_path)) |_| {
        c.setResult(.file_rename, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file delete operation
pub fn handleFileDelete(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileDelete);
    if (fs.unlinkat(allocator, data.dir, data.path)) |_| {
        c.setResult(.file_delete, {});
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileRename - performs blocking renameat() syscall
pub fn fileRenameWork(work: *Work) void {
    const internal: *@FieldType(FileRename, "internal") = @fieldParentPtr("work", work);
    const file_rename: *FileRename = @fieldParentPtr("internal", internal);
    handleFileRename(&file_rename.c, file_rename.internal.allocator);
}

/// Work function for FileDelete - performs blocking unlinkat() syscall
pub fn fileDeleteWork(work: *Work) void {
    const internal: *@FieldType(FileDelete, "internal") = @fieldParentPtr("work", work);
    const file_delete: *FileDelete = @fieldParentPtr("internal", internal);
    handleFileDelete(&file_delete.c, file_delete.internal.allocator);
}
