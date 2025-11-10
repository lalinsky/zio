const std = @import("std");

const Loop = @import("loop.zig").Loop;
const Backend = @import("backend.zig").Backend;
const HeapNode = @import("heap.zig").HeapNode;
const net = @import("os/net.zig");
const fs = @import("os/fs.zig");

pub const OperationType = enum {
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
    file_close,
    file_read,
    file_write,
};

pub const Completion = struct {
    op: OperationType,
    state: State = .new,

    userdata: ?*anyopaque = null,
    callback: ?*const CallbackFn = null,

    canceled: ?*Cancel = null,

    /// Error result - null means success, error means failure.
    /// Stored here instead of in each operation type to simplify error handling.
    err: ?anyerror = null,

    /// Whether a result has been set (for debugging/assertions).
    has_result: bool = false,

    /// Intrusive linked list of completions.
    /// Used for submission queue OR poll queue (mutually exclusive).
    prev: ?*Completion = null,
    next: ?*Completion = null,

    pub const State = enum { new, adding, running, completed };

    pub const CallbackFn = fn (
        loop: *Loop,
        completion: *Completion,
    ) void;

    pub fn init(op: OperationType) Completion {
        return .{ .op = op };
    }

    pub fn call(c: *Completion, loop: *Loop) void {
        if (c.callback) |func| {
            func(loop, c);
        }
    }

    pub fn cast(c: *Completion, comptime T: type) *T {
        std.debug.assert(c.op == completionOp(T));
        return @fieldParentPtr("c", c);
    }

    pub fn getResult(c: *const Completion, comptime op: OperationType) (CompletionType(op).Error)!@FieldType(CompletionType(op), "result_private_do_not_touch") {
        std.debug.assert(c.has_result);
        std.debug.assert(c.op == op);
        if (c.err) |err| return @errorCast(err);
        const T = CompletionType(op);
        const parent: *const T = @fieldParentPtr("c", c);
        return parent.result_private_do_not_touch;
    }

    pub fn setError(c: *Completion, err: anyerror) void {
        std.debug.assert(!c.has_result);
        // If this operation was canceled but got a different error (race condition),
        // we need to mark the cancel as AlreadyCompleted.
        // If err is error.Canceled, the normal cancelation flow handles the cancel.
        if (c.canceled) |cancel| {
            if (err != error.Canceled) {
                cancel.c.err = error.AlreadyCompleted;
                cancel.c.has_result = true;
            }
        }

        c.err = err;
        c.has_result = true;
    }

    pub fn setResult(c: *Completion, comptime op: OperationType, result: @FieldType(CompletionType(op), "result_private_do_not_touch")) void {
        std.debug.assert(!c.has_result);
        std.debug.assert(c.op == op);
        // If this operation was canceled but completed successfully (race condition),
        // we need to mark the cancel as AlreadyCompleted.
        if (c.canceled) |cancel| {
            cancel.c.err = error.AlreadyCompleted;
            cancel.c.has_result = true;
        }

        const T = CompletionType(op);
        c.cast(T).result_private_do_not_touch = result;
        c.has_result = true;
    }
};

pub fn completionOp(comptime T: type) OperationType {
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
        FileClose => .file_close,
        FileRead => .file_read,
        FileWrite => .file_write,
        else => @compileError("unknown completion type"),
    };
}

pub fn CompletionType(comptime op: OperationType) type {
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
        .file_close => FileClose,
        .file_read => FileRead,
        .file_write => FileWrite,
    };
}

pub const Cancelable = error{Canceled};

pub const Cancel = struct {
    c: Completion,
    cancel_c: *Completion,
    result_private_do_not_touch: void = {},

    pub const Error = error{ AlreadyCanceled, AlreadyCompleted };

    pub fn init(cancel_c: *Completion) Cancel {
        return .{
            .c = .init(.cancel),
            .cancel_c = cancel_c,
        };
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
};

pub const Async = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    loop: *Loop = undefined,

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
            self.loop.wake();
        }
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

    pub const WorkFn = fn (loop: *Loop, work: *Work) void;

    pub fn init(func: *const WorkFn, userdata: ?*anyopaque) Work {
        return .{
            .c = .init(.work),
            .func = func,
            .userdata = userdata,
        };
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
};

pub const NetOpen = struct {
    c: Completion,
    result_private_do_not_touch: Backend.NetHandle = undefined,
    domain: net.Domain,
    socket_type: net.Type,
    protocol: net.Protocol,
    flags: net.OpenFlags = .{ .nonblocking = true },

    pub const Error = net.OpenError || Cancelable;

    pub fn init(
        domain: net.Domain,
        socket_type: net.Type,
        protocol: net.Protocol,
    ) NetOpen {
        return .{
            .c = .init(.net_open),
            .domain = domain,
            .socket_type = socket_type,
            .protocol = protocol,
        };
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
};

pub const NetConnect = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
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
    buffers: []net.iovec,
    flags: net.RecvFlags,

    pub const Error = net.RecvError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffers: []net.iovec, flags: net.RecvFlags) NetRecv {
        return .{
            .c = .init(.net_recv),
            .handle = handle,
            .buffers = buffers,
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
    buffers: []const net.iovec_const,
    flags: net.SendFlags,

    pub const Error = net.SendError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffers: []const net.iovec_const, flags: net.SendFlags) NetSend {
        return .{
            .c = .init(.net_send),
            .handle = handle,
            .buffers = buffers,
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
    buffers: []net.iovec,
    flags: net.RecvFlags,
    addr: ?*net.sockaddr,
    addr_len: ?*net.socklen_t,

    pub const Error = net.RecvError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        buffers: []net.iovec,
        flags: net.RecvFlags,
        addr: ?*net.sockaddr,
        addr_len: ?*net.socklen_t,
    ) NetRecvFrom {
        return .{
            .c = .init(.net_recvfrom),
            .handle = handle,
            .buffers = buffers,
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
    buffers: []const net.iovec_const,
    flags: net.SendFlags,
    addr: *const net.sockaddr,
    addr_len: net.socklen_t,

    pub const Error = net.SendError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        buffers: []const net.iovec_const,
        flags: net.SendFlags,
        addr: *const net.sockaddr,
        addr_len: net.socklen_t,
    ) NetSendTo {
        return .{
            .c = .init(.net_sendto),
            .handle = handle,
            .buffers = buffers,
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
    internal: switch (@hasDecl(Backend, "supports_file_ops") and Backend.supports_file_ops) {
        true => if (@hasDecl(Backend, "FileOpenData")) Backend.FileOpenData else struct {},
        false => struct { work: Work = undefined, allocator: std.mem.Allocator = undefined },
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    mode: fs.mode_t,
    flags: fs.FileOpenFlags,

    pub const Error = fs.FileOpenError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, mode: fs.mode_t, flags: fs.FileOpenFlags) FileOpen {
        return .{
            .c = .init(.file_open),
            .dir = dir,
            .path = path,
            .flags = flags,
            .mode = mode,
        };
    }

    pub fn getResult(self: *const FileOpen) Error!fs.fd_t {
        return self.c.getResult(.file_open);
    }
};

pub const FileClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (@hasDecl(Backend, "supports_file_ops") and Backend.supports_file_ops) {
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
    internal: switch (@hasDecl(Backend, "supports_file_ops") and Backend.supports_file_ops) {
        true => if (@hasDecl(Backend, "FileReadData")) Backend.FileReadData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,
    buffers: []fs.iovec,
    offset: u64,

    pub const Error = fs.FileReadError || Cancelable;

    pub fn init(handle: fs.fd_t, buffers: []fs.iovec, offset: u64) FileRead {
        return .{
            .c = .init(.file_read),
            .handle = handle,
            .buffers = buffers,
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
    internal: switch (@hasDecl(Backend, "supports_file_ops") and Backend.supports_file_ops) {
        true => if (@hasDecl(Backend, "FileWriteData")) Backend.FileWriteData else struct {},
        false => struct { work: Work = undefined },
    } = .{},
    handle: fs.fd_t,
    buffers: []const fs.iovec_const,
    offset: u64,

    pub const Error = fs.FileWriteError || Cancelable;

    pub fn init(handle: fs.fd_t, buffers: []const fs.iovec_const, offset: u64) FileWrite {
        return .{
            .c = .init(.file_write),
            .handle = handle,
            .buffers = buffers,
            .offset = offset,
        };
    }

    pub fn getResult(self: *const FileWrite) Error!usize {
        return self.c.getResult(.file_write);
    }
};
