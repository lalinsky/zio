const std = @import("std");

const Loop = @import("loop.zig").Loop;
const Backend = @import("backend.zig").Backend;
const HeapNode = @import("heap.zig").HeapNode;
const socket = @import("os/posix/socket.zig");

pub const OperationType = enum {
    timer,
    cancel,
    net_open,
    net_bind,
    net_listen,
    net_connect,
    net_accept,
    net_recv,
    net_send,
    net_shutdown,
    net_close,
};

pub const Completion = struct {
    op: OperationType,
    state: State = .new,

    userdata: ?*anyopaque = null,
    callback: ?*const CallbackFn = null,

    canceled: ?*Completion = null,

    /// Intrusive queue of completions.
    next: ?*Completion = null,

    pub const State = enum { new, adding, running, completed };

    pub const CallbackAction = enum { disarm, rearm };
    pub const CallbackFn = fn (
        userdata: ?*anyopaque,
        loop: *Loop,
        completion: *Completion,
    ) CallbackAction;

    pub fn init(op: OperationType) Completion {
        return .{ .op = op };
    }

    pub fn call(c: *Completion, loop: *Loop) CallbackAction {
        if (c.callback) |func| {
            return func(c.userdata, loop, c);
        }
        return .disarm;
    }

    pub fn cast(c: *Completion, comptime T: type) *T {
        std.debug.assert(c.op == completionOp(T));
        return @fieldParentPtr("c", c);
    }
};

pub fn completionOp(comptime T: type) OperationType {
    return switch (T) {
        Timer => .timer,
        Cancel => .cancel,
        NetOpen => .net_open,
        NetBind => .net_bind,
        NetListen => .net_listen,
        NetConnect => .net_connect,
        NetAccept => .net_accept,
        NetRecv => .net_recv,
        NetSend => .net_send,
        NetClose => .net_close,
        NetShutdown => .net_shutdown,
        else => @compileError("unknown completion type"),
    };
}

pub fn CompletionType(comptime op: OperationType) type {
    return switch (op) {
        .timer => Timer,
        .cancel => Cancel,
        .net_open => NetOpen,
        .net_bind => NetBind,
        .net_listen => NetListen,
        .net_connect => NetConnect,
        .net_accept => NetAccept,
        .net_recv => NetRecv,
        .net_send => NetSend,
        .net_close => NetClose,
        .net_shutdown => NetShutdown,
    };
}

pub const Cancelable = error{Canceled};

pub const Timer = struct {
    c: Completion,
    result: Error!void = undefined,
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

pub const Cancel = struct {
    c: Completion,
    cancel_c: *Completion,
    result: void = {},

    pub fn init(cancel_c: *Completion) Cancel {
        return .{
            .c = .init(.cancel),
            .cancel_c = cancel_c,
        };
    }
};

pub const NetClose = struct {
    c: Completion,
    result: void = {},
    handle: Backend.NetHandle,

    pub fn init(handle: Backend.NetHandle) NetClose {
        return .{
            .c = .init(.net_close),
            .handle = handle,
        };
    }
};

pub const NetShutdown = struct {
    c: Completion,
    result: Error!void = undefined,
    handle: Backend.NetHandle,
    how: socket.ShutdownHow,

    pub const Error = socket.ShutdownError || Cancelable;

    pub fn init(handle: Backend.NetHandle, how: socket.ShutdownHow) NetShutdown {
        return .{
            .c = .init(.net_shutdown),
            .handle = handle,
            .how = how,
        };
    }
};

pub const NetOpen = struct {
    c: Completion,
    result: Error!Backend.NetHandle = undefined,
    domain: socket.Domain,
    socket_type: socket.Type,
    protocol: socket.Protocol,
    flags: socket.OpenFlags,

    pub const Error = socket.OpenError;

    pub fn init(
        domain: socket.Domain,
        socket_type: socket.Type,
        protocol: socket.Protocol,
        flags: socket.OpenFlags,
    ) NetOpen {
        return .{
            .c = .init(.net_open),
            .domain = domain,
            .socket_type = socket_type,
            .protocol = protocol,
            .flags = flags,
        };
    }
};

pub const NetBind = struct {
    c: Completion,
    result: Error!void = undefined,
    handle: Backend.NetHandle,
    addr: [*]const u8,
    addr_len: u32,

    pub const Error = socket.BindError;

    pub fn init(handle: Backend.NetHandle, addr: [*]const u8, addr_len: u32) NetBind {
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
    result: Error!void = undefined,
    handle: Backend.NetHandle,
    backlog: u31,

    pub const Error = socket.ListenError;

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
    result: Error!void = undefined,
    handle: Backend.NetHandle,
    addr: [*]const u8,
    addr_len: u32,

    pub const Error = socket.ConnectError || Cancelable;

    pub fn init(handle: Backend.NetHandle, addr: [*]const u8, addr_len: u32) NetConnect {
        return .{
            .c = .init(.net_connect),
            .handle = handle,
            .addr = addr,
            .addr_len = addr_len,
        };
    }
};

pub const NetAccept = struct {
    c: Completion,
    result: Error!Backend.NetHandle = undefined,
    handle: Backend.NetHandle,
    addr: ?[*]u8,
    addr_len: ?*u32,
    flags: socket.OpenFlags,

    pub const Error = socket.AcceptError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        addr: ?[*]u8,
        addr_len: ?*u32,
        flags: socket.OpenFlags,
    ) NetAccept {
        return .{
            .c = .init(.net_accept),
            .handle = handle,
            .addr = addr,
            .addr_len = addr_len,
            .flags = flags,
        };
    }
};

pub const NetRecv = struct {
    c: Completion,
    result: Error!usize = undefined,
    handle: Backend.NetHandle,
    buffer: []u8,
    flags: socket.RecvFlags,

    pub const Error = socket.RecvError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffer: []u8, flags: socket.RecvFlags) NetRecv {
        return .{
            .c = .init(.net_recv),
            .handle = handle,
            .buffer = buffer,
            .flags = flags,
        };
    }
};

pub const NetSend = struct {
    c: Completion,
    result: Error!usize = undefined,
    handle: Backend.NetHandle,
    buffer: []const u8,
    flags: socket.SendFlags,

    pub const Error = socket.SendError || Cancelable;

    pub fn init(handle: Backend.NetHandle, buffer: []const u8, flags: socket.SendFlags) NetSend {
        return .{
            .c = .init(.net_send),
            .handle = handle,
            .buffer = buffer,
            .flags = flags,
        };
    }
};
