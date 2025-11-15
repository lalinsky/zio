const std = @import("std");

const Loop = @import("loop.zig").Loop;
const Backend = @import("backend.zig").Backend;
const HeapNode = @import("heap.zig").HeapNode;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const net = @import("os/net.zig");
const fs = @import("os/fs.zig");

pub const BackendCapabilities = struct {
    file_read: bool = false,
    file_write: bool = false,
    file_open: bool = false,
    file_create: bool = false,
    file_close: bool = false,
    file_sync: bool = false,
    file_rename: bool = false,
    file_delete: bool = false,

    pub fn supportsNonBlockingFileIo(comptime self: BackendCapabilities) bool {
        return self.file_read or self.file_write;
    }
};

pub const Op = enum {
    timer,
    cancel,
    async,
    work,
    net_open,
    net_bind,
    net_listen,
    net_connect,
    net_accept,
    net_recv,
    net_send,
    net_recvfrom,
    net_sendto,
    net_shutdown,
    net_close,
    file_open,
    file_create,
    file_close,
    file_read,
    file_write,
    file_sync,
    file_rename,
    file_delete,

    /// Get the completion type for this operation
    pub fn toType(comptime op: Op) type {
        return switch (op) {
            .timer => Timer,
            .cancel => Cancel,
            .async => Async,
            .work => Work,
            .net_open => NetOpen,
            .net_bind => NetBind,
            .net_listen => NetListen,
            .net_connect => NetConnect,
            .net_accept => NetAccept,
            .net_recv => NetRecv,
            .net_send => NetSend,
            .net_recvfrom => NetRecvFrom,
            .net_sendto => NetSendTo,
            .net_close => NetClose,
            .net_shutdown => NetShutdown,
            .file_open => FileOpen,
            .file_create => FileCreate,
            .file_close => FileClose,
            .file_read => FileRead,
            .file_write => FileWrite,
            .file_sync => FileSync,
            .file_rename => FileRename,
            .file_delete => FileDelete,
        };
    }

    /// Get the operation type from a completion type
    pub fn fromType(comptime T: type) Op {
        return switch (T) {
            Timer => .timer,
            Cancel => .cancel,
            Async => .async,
            Work => .work,
            NetOpen => .net_open,
            NetBind => .net_bind,
            NetListen => .net_listen,
            NetConnect => .net_connect,
            NetAccept => .net_accept,
            NetRecv => .net_recv,
            NetSend => .net_send,
            NetRecvFrom => .net_recvfrom,
            NetSendTo => .net_sendto,
            NetClose => .net_close,
            NetShutdown => .net_shutdown,
            FileOpen => .file_open,
            FileCreate => .file_create,
            FileClose => .file_close,
            FileRead => .file_read,
            FileWrite => .file_write,
            FileSync => .file_sync,
            FileRename => .file_rename,
            FileDelete => .file_delete,
            else => @compileError("unknown completion type"),
        };
    }
};

pub const Completion = struct {
    op: Op,
    state: State = .new,

    userdata: ?*anyopaque = null,
    callback: ?*const CallbackFn = null,

    canceled: bool = false,
    canceled_by: ?*Cancel = null,

    /// Error result - null means success, error means failure.
    /// Stored here instead of in each operation type to simplify error handling.
    err: ?anyerror = null,

    /// Whether a result has been set (for debugging/assertions).
    has_result: bool = false,

    /// Backend-specific internal data for async operations.
    /// Used by backends like IOCP to store OVERLAPPED structures.
    internal: if (@hasDecl(Backend, "CompletionData")) Backend.CompletionData else struct {} = .{},

    /// Intrusive linked list of completions.
    /// Used for submission queue OR poll queue (mutually exclusive).
    prev: ?*Completion = null,
    next: ?*Completion = null,

    pub const State = enum { new, running, completed, dead };

    pub const CallbackFn = fn (
        loop: *Loop,
        completion: *Completion,
    ) void;

    pub fn init(op: Op) Completion {
        return .{ .op = op };
    }

    pub fn reset(c: *Completion) void {
        c.state = .new;
        c.has_result = false;
        c.err = null;
        c.canceled = false;
        c.canceled_by = null;
    }

    pub fn call(c: *Completion, loop: *Loop) void {
        if (c.callback) |func| {
            func(loop, c);
        }
    }

    pub fn cast(c: *Completion, comptime T: type) *T {
        std.debug.assert(c.op == Op.fromType(T));
        return @fieldParentPtr("c", c);
    }

    pub fn getResult(c: *const Completion, comptime op: Op) (op.toType().Error)!@FieldType(op.toType(), "result_private_do_not_touch") {
        std.debug.assert(c.has_result);
        std.debug.assert(c.op == op);
        if (c.err) |err| return @errorCast(err);
        const T = op.toType();
        const parent: *const T = @fieldParentPtr("c", c);
        return parent.result_private_do_not_touch;
    }

    pub fn setError(c: *Completion, err: anyerror) void {
        std.debug.assert(!c.has_result);
        // If this operation was canceled but got a different error (race condition),
        // we need to mark the cancel as AlreadyCompleted.
        // If err is error.Canceled, the normal cancelation flow handles the cancel.
        if (c.canceled_by) |cancel| {
            if (err != error.Canceled) {
                cancel.c.err = error.AlreadyCompleted;
                cancel.c.has_result = true;
            }
        }

        c.err = err;
        c.has_result = true;
    }

    pub fn setResult(c: *Completion, comptime op: Op, result: @FieldType(op.toType(), "result_private_do_not_touch")) void {
        std.debug.assert(!c.has_result);
        std.debug.assert(c.op == op);
        // If this operation was canceled but completed successfully (race condition),
        // we need to mark the cancel as AlreadyCompleted.
        if (c.canceled_by) |cancel| {
            cancel.c.err = error.AlreadyCompleted;
            cancel.c.has_result = true;
        }

        const T = op.toType();
        c.cast(T).result_private_do_not_touch = result;
        c.has_result = true;
    }
};

pub const Cancelable = error{Canceled};

pub const Cancel = struct {
    c: Completion,
    target: *Completion,
    result_private_do_not_touch: void = {},

    pub const Error = error{ AlreadyCanceled, AlreadyCompleted, Uncancelable };

    pub fn init(target: *Completion) Cancel {
        return .{
            .c = .init(.cancel),
            .target = target,
        };
    }

    pub fn getResult(self: *const Cancel) Error!void {
        return self.c.getResult(.cancel);
    }
};

pub const Timer = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    delay_ms: u64,
    deadline_ms: u64 = 0,
    heap: HeapNode(Timer) = .{},

    pub const Error = Cancelable;

    pub fn init(delay_ms: u64) Timer {
        return .{
            .c = .init(.timer),
            .delay_ms = delay_ms,
        };
    }

    pub fn getResult(self: *const Timer) Error!void {
        return self.c.getResult(.timer);
    }
};

pub const Async = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    loop: ?*Loop = null,

    pub const Error = Cancelable;

    pub fn init() Async {
        return .{
            .c = .init(.async),
        };
    }

    /// Notify the loop to wake up and complete this async handle (thread-safe)
    pub fn notify(self: *Async) void {
        // Atomically set pending flag
        const was_pending = self.pending.swap(1, .release);
        if (was_pending == 0) {
            // Only notify loop if transitioning from not-pending to pending
            // If loop is not set (not actively waiting), this is a no-op
            if (self.loop) |loop| {
                loop.wake();
            }
        }
    }

    pub fn getResult(self: *const Async) Error!void {
        return self.c.getResult(.async);
    }
};

pub const Work = struct {
    c: Completion,
    result_private_do_not_touch: void = {},

    func: *const WorkFn,
    userdata: ?*anyopaque,

    loop: ?*Loop = null,
    linked: ?*Completion = null,
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.pending),

    pub const Error = error{NoThreadPool} || Cancelable;

    pub const State = enum(u8) {
        pending,
        running,
        completed,
        canceled,
    };

    pub const WorkFn = fn (work: *Work) void;

    pub fn init(func: *const WorkFn, userdata: ?*anyopaque) Work {
        return .{
            .c = .init(.work),
            .func = func,
            .userdata = userdata,
        };
    }

    pub fn getResult(self: *const Work) Error!void {
        return self.c.getResult(.work);
    }
};

pub const NetClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: Backend.NetHandle,

    pub const Error = Cancelable;

    pub fn init(handle: Backend.NetHandle) NetClose {
        return .{
            .c = .init(.net_close),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const NetClose) Error!void {
        return self.c.getResult(.net_close);
    }
};

pub const NetShutdown = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: Backend.NetHandle,
    how: net.ShutdownHow,

    pub const Error = net.ShutdownError || Cancelable;

    pub fn init(handle: Backend.NetHandle, how: net.ShutdownHow) NetShutdown {
        return .{
            .c = .init(.net_shutdown),
            .handle = handle,
            .how = how,
        };
    }

    pub fn getResult(self: *const NetShutdown) Error!void {
        return self.c.getResult(.net_shutdown);
    }
};

pub const NetOpen = struct {
    c: Completion,
    result_private_do_not_touch: Backend.NetHandle = undefined,
    domain: net.Domain,
    socket_type: net.Type,
    flags: net.OpenFlags = .{ .nonblocking = true },

    pub const Error = net.OpenError || Cancelable;

    pub fn init(
        domain: net.Domain,
        socket_type: net.Type,
        flags: net.OpenFlags,
    ) NetOpen {
        return .{
            .c = .init(.net_open),
            .domain = domain,
            .socket_type = socket_type,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const NetOpen) Error!Backend.NetHandle {
        return self.c.getResult(.net_open);
    }
};

pub const NetBind = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: Backend.NetHandle,
    addr: *net.sockaddr,
    addr_len: *net.socklen_t,

    pub const Error = net.BindError || Cancelable;

    pub fn init(handle: Backend.NetHandle, addr: *net.sockaddr, addr_len: *net.socklen_t) NetBind {
        return .{
            .c = .init(.net_bind),
            .handle = handle,
            .addr = addr,
            .addr_len = addr_len,
        };
    }

    pub fn getResult(self: *const NetBind) Error!void {
        return self.c.getResult(.net_bind);
    }
};

pub const NetListen = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: Backend.NetHandle,
    backlog: u31,

    pub const Error = net.ListenError || Cancelable;

    pub fn init(handle: Backend.NetHandle, backlog: u31) NetListen {
        return .{
            .c = .init(.net_listen),
            .handle = handle,
            .backlog = backlog,
        };
    }

    pub fn getResult(self: *const NetListen) Error!void {
        return self.c.getResult(.net_listen);
    }
};

pub const NetConnect = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: if (@hasDecl(Backend, "NetConnectData")) Backend.NetConnectData else struct {} = .{},
    handle: Backend.NetHandle,
    addr: *const net.sockaddr,
    addr_len: net.socklen_t,

    pub const Error = net.ConnectError || Cancelable;

    pub fn init(handle: Backend.NetHandle, addr: *const net.sockaddr, addr_len: net.socklen_t) NetConnect {
        return .{
            .c = .init(.net_connect),
            .handle = handle,
            .addr = addr,
            .addr_len = addr_len,
        };
    }

    pub fn getResult(self: *const NetConnect) Error!void {
        return self.c.getResult(.net_connect);
    }
};

pub const NetAccept = struct {
    c: Completion,
    result_private_do_not_touch: Backend.NetHandle = undefined,
    internal: if (@hasDecl(Backend, "NetAcceptData")) Backend.NetAcceptData else struct {} = .{},
    handle: Backend.NetHandle,
    addr: ?*net.sockaddr,
    addr_len: ?*net.socklen_t,
    flags: net.OpenFlags = .{ .nonblocking = true },

    pub const Error = net.AcceptError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        addr: ?*net.sockaddr,
        addr_len: ?*net.socklen_t,
    ) NetAccept {
        return .{
            .c = .init(.net_accept),
            .handle = handle,
            .addr = addr,
            .addr_len = addr_len,
        };
    }

    pub fn getResult(self: *const NetAccept) Error!Backend.NetHandle {
        return self.c.getResult(.net_accept);
    }
};

pub const NetRecv = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: if (@hasDecl(Backend, "NetRecvData")) Backend.NetRecvData else struct {} = .{},
    handle: Backend.NetHandle,
    buffers: ReadBuf,
    flags: net.RecvFlags,

    pub const Error = net.RecvError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffer: ReadBuf, flags: net.RecvFlags) NetRecv {
        return .{
            .c = .init(.net_recv),
            .handle = handle,
            .buffers = buffer,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const NetRecv) Error!usize {
        return self.c.getResult(.net_recv);
    }
};

pub const NetSend = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: if (@hasDecl(Backend, "NetSendData")) Backend.NetSendData else struct {} = .{},
    handle: Backend.NetHandle,
    buffer: WriteBuf,
    flags: net.SendFlags,

    pub const Error = net.SendError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffer: WriteBuf, flags: net.SendFlags) NetSend {
        return .{
            .c = .init(.net_send),
            .handle = handle,
            .buffer = buffer,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const NetSend) Error!usize {
        return self.c.getResult(.net_send);
    }
};

pub const NetRecvFrom = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: if (@hasDecl(Backend, "NetRecvFromData")) Backend.NetRecvFromData else struct {} = .{},
    handle: Backend.NetHandle,
    buffer: ReadBuf,
    flags: net.RecvFlags,
    addr: ?*net.sockaddr,
    addr_len: ?*net.socklen_t,

    pub const Error = net.RecvError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        buffer: ReadBuf,
        flags: net.RecvFlags,
        addr: ?*net.sockaddr,
        addr_len: ?*net.socklen_t,
    ) NetRecvFrom {
        return .{
            .c = .init(.net_recvfrom),
            .handle = handle,
            .buffer = buffer,
            .flags = flags,
            .addr = addr,
            .addr_len = addr_len,
        };
    }

    pub fn getResult(self: *const NetRecvFrom) Error!usize {
        return self.c.getResult(.net_recvfrom);
    }
};

pub const NetSendTo = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: if (@hasDecl(Backend, "NetSendToData")) Backend.NetSendToData else struct {} = .{},
    handle: Backend.NetHandle,
    buffer: WriteBuf,
    flags: net.SendFlags,
    addr: *const net.sockaddr,
    addr_len: net.socklen_t,

    pub const Error = net.SendError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        buffer: WriteBuf,
        flags: net.SendFlags,
        addr: *const net.sockaddr,
        addr_len: net.socklen_t,
    ) NetSendTo {
        return .{
            .c = .init(.net_sendto),
            .handle = handle,
            .buffer = buffer,
            .flags = flags,
            .addr = addr,
            .addr_len = addr_len,
        };
    }

    pub fn getResult(self: *const NetSendTo) Error!usize {
        return self.c.getResult(.net_sendto);
    }
};

pub const FileOpen = struct {
    c: Completion,
    result_private_do_not_touch: fs.fd_t = undefined,
    internal: switch (Backend.capabilities.file_open) {
        true => if (@hasDecl(Backend, "FileOpenData")) Backend.FileOpenData else struct {},
        false => struct { work: Work = undefined, allocator: std.mem.Allocator = undefined },
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    flags: fs.FileOpenFlags,

    pub const Error = fs.FileOpenError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, flags: fs.FileOpenFlags) FileOpen {
        return .{
            .c = .init(.file_open),
            .dir = dir,
            .path = path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const FileOpen) Error!fs.fd_t {
        return self.c.getResult(.file_open);
    }
};

pub const FileCreate = struct {
    c: Completion,
    result_private_do_not_touch: fs.fd_t = undefined,
    internal: switch (Backend.capabilities.file_create) {
        true => if (@hasDecl(Backend, "FileCreateData")) Backend.FileCreateData else struct {},
        false => struct { work: Work = undefined, allocator: std.mem.Allocator = undefined },
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    flags: fs.FileCreateFlags,

    pub const Error = fs.FileOpenError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, flags: fs.FileCreateFlags) FileCreate {
        return .{
            .c = .init(.file_create),
            .dir = dir,
            .path = path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const FileCreate) Error!fs.fd_t {
        return self.c.getResult(.file_create);
    }
};

pub const FileClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_close) {
        true => if (@hasDecl(Backend, "FileCloseData")) Backend.FileCloseData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,

    pub const Error = Cancelable;

    pub fn init(handle: fs.fd_t) FileClose {
        return .{
            .c = .init(.file_close),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const FileClose) Error!void {
        return self.c.getResult(.file_close);
    }
};

pub const FileRead = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.file_read) {
        true => if (@hasDecl(Backend, "FileReadData")) Backend.FileReadData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,
    buffer: ReadBuf,
    offset: u64,

    pub const Error = fs.FileReadError || Cancelable;

    pub fn init(handle: fs.fd_t, buffer: ReadBuf, offset: u64) FileRead {
        return .{
            .c = .init(.file_read),
            .handle = handle,
            .buffer = buffer,
            .offset = offset,
        };
    }

    pub fn getResult(self: *const FileRead) Error!usize {
        return self.c.getResult(.file_read);
    }
};

pub const FileWrite = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.file_write) {
        true => if (@hasDecl(Backend, "FileWriteData")) Backend.FileWriteData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,
    buffer: WriteBuf,
    offset: u64,

    pub const Error = fs.FileWriteError || Cancelable;

    pub fn init(handle: fs.fd_t, buffer: WriteBuf, offset: u64) FileWrite {
        return .{
            .c = .init(.file_write),
            .handle = handle,
            .buffer = buffer,
            .offset = offset,
        };
    }

    pub fn getResult(self: *const FileWrite) Error!usize {
        return self.c.getResult(.file_write);
    }
};

pub const FileSync = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_sync) {
        true => if (@hasDecl(Backend, "FileSyncData")) Backend.FileSyncData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,
    flags: fs.FileSyncFlags,

    pub const Error = fs.FileSyncError || Cancelable;

    pub fn init(handle: fs.fd_t, flags: fs.FileSyncFlags) FileSync {
        return .{
            .c = .init(.file_sync),
            .handle = handle,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const FileSync) Error!void {
        return self.c.getResult(.file_sync);
    }
};

pub const FileRename = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_rename) {
        true => if (@hasDecl(Backend, "FileRenameData")) Backend.FileRenameData else struct {},
        false => struct { work: Work = undefined, allocator: std.mem.Allocator = undefined },
    } = .{},
    old_dir: fs.fd_t,
    old_path: []const u8,
    new_dir: fs.fd_t,
    new_path: []const u8,

    pub const Error = fs.FileRenameError || Cancelable;

    pub fn init(old_dir: fs.fd_t, old_path: []const u8, new_dir: fs.fd_t, new_path: []const u8) FileRename {
        return .{
            .c = .init(.file_rename),
            .old_dir = old_dir,
            .old_path = old_path,
            .new_dir = new_dir,
            .new_path = new_path,
        };
    }

    pub fn getResult(self: *const FileRename) Error!void {
        return self.c.getResult(.file_rename);
    }
};

pub const FileDelete = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_delete) {
        true => if (@hasDecl(Backend, "FileDeleteData")) Backend.FileDeleteData else struct {},
        false => struct { work: Work = undefined, allocator: std.mem.Allocator = undefined },
    } = .{},
    dir: fs.fd_t,
    path: []const u8,

    pub const Error = fs.FileDeleteError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8) FileDelete {
        return .{
            .c = .init(.file_delete),
            .dir = dir,
            .path = path,
        };
    }

    pub fn getResult(self: *const FileDelete) Error!void {
        return self.c.getResult(.file_delete);
    }
};
