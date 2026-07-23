const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../os/posix.zig");

const Loop = @import("loop.zig").Loop;
const Backend = @import("backend.zig").Backend;
const HeapNode = @import("heap.zig").HeapNode;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const os = @import("../os/root.zig");
const net = @import("../os/net.zig");
const fs = @import("../os/fs.zig");
const Timestamp = @import("../time.zig").Timestamp;
const Timeout = @import("../time.zig").Timeout;
const Clock = @import("../time.zig").Clock;

pub const BackendCapabilities = struct {
    file_read: bool = false,
    file_write: bool = false,
    file_read_streaming: bool = false,
    file_write_streaming: bool = false,
    file_open: bool = false,
    file_create: bool = false,
    file_close: bool = false,
    file_sync: bool = false,
    file_set_size: bool = false,
    file_set_permissions: bool = false,
    file_set_owner: bool = false,
    file_set_timestamps: bool = false,
    dir_create_dir: bool = false,
    dir_rename: bool = false,
    dir_rename_preserve: bool = false,
    dir_delete_file: bool = false,
    dir_delete_dir: bool = false,
    file_size: bool = false,
    file_stat: bool = false,
    dir_open: bool = false,
    dir_close: bool = false,
    dir_set_permissions: bool = false,
    dir_set_owner: bool = false,
    dir_set_file_permissions: bool = false,
    dir_set_file_owner: bool = false,
    dir_set_file_timestamps: bool = false,
    dir_sym_link: bool = false,
    dir_read_link: bool = false,
    dir_hard_link: bool = false,
    dir_access: bool = false,
    dir_read: bool = false,
    dir_real_path: bool = false,
    dir_real_path_file: bool = false,
    file_real_path: bool = false,
    file_hard_link: bool = false,
    /// When true, the backend implements file-to-socket transfer natively
    /// (e.g. io_uring splice). When false, the loop drives a generic
    /// read/write callback loop fallback (see NetSendFile).
    net_send_file: bool = false,
    device_io_control: bool = false,
    process_wait: bool = false,
    /// When true, the backend arms boot/real (wall-clock) timers natively via
    /// `syncWallTimers`, so the loop must not fold them into the poll timeout.
    /// When false, the loop falls back to the capped poll-timeout re-evaluation.
    native_wall_timers: bool = false,

    pub fn supportsNonBlockingFileIo(comptime self: BackendCapabilities) bool {
        return self.file_read or self.file_write or self.file_read_streaming or self.file_write_streaming;
    }
};

pub const Op = enum {
    group,
    timer,
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
    net_recvmsg,
    net_sendmsg,
    net_poll,
    net_shutdown,
    net_close,
    net_send_file,
    file_open,
    file_create,
    file_close,
    file_read,
    file_write,
    file_read_streaming,
    file_write_streaming,
    file_sync,
    file_set_size,
    file_set_permissions,
    file_set_owner,
    file_set_timestamps,
    dir_create_dir,
    dir_rename,
    dir_rename_preserve,
    dir_delete_file,
    dir_delete_dir,
    file_size,
    file_stat,
    dir_open,
    dir_close,
    dir_set_permissions,
    dir_set_owner,
    dir_set_file_permissions,
    dir_set_file_owner,
    dir_set_file_timestamps,
    dir_sym_link,
    dir_read_link,
    dir_hard_link,
    dir_access,
    dir_read,
    dir_real_path,
    dir_real_path_file,
    file_real_path,
    file_hard_link,
    pipe_poll,
    pipe_create,
    pipe_close,
    device_io_control,
    mach_port,
    process_wait,

    /// Get the completion type for this operation
    pub fn toType(comptime op: Op) type {
        return switch (op) {
            .group => Group,
            .timer => Timer,
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
            .net_recvmsg => NetRecvMsg,
            .net_sendmsg => NetSendMsg,
            .net_poll => NetPoll,
            .net_close => NetClose,
            .net_shutdown => NetShutdown,
            .net_send_file => NetSendFile,
            .file_open => FileOpen,
            .file_create => FileCreate,
            .file_close => FileClose,
            .file_read => FileRead,
            .file_write => FileWrite,
            .file_read_streaming => FileReadStreaming,
            .file_write_streaming => FileWriteStreaming,
            .file_sync => FileSync,
            .file_set_size => FileSetSize,
            .file_set_permissions => FileSetPermissions,
            .file_set_owner => FileSetOwner,
            .file_set_timestamps => FileSetTimestamps,
            .dir_create_dir => DirCreateDir,
            .dir_rename => DirRename,
            .dir_rename_preserve => DirRenamePreserve,
            .dir_delete_file => DirDeleteFile,
            .dir_delete_dir => DirDeleteDir,
            .file_size => FileSize,
            .file_stat => FileStat,
            .dir_open => DirOpen,
            .dir_close => DirClose,
            .dir_set_permissions => DirSetPermissions,
            .dir_set_owner => DirSetOwner,
            .dir_set_file_permissions => DirSetFilePermissions,
            .dir_set_file_owner => DirSetFileOwner,
            .dir_set_file_timestamps => DirSetFileTimestamps,
            .dir_sym_link => DirSymLink,
            .dir_read_link => DirReadLink,
            .dir_hard_link => DirHardLink,
            .dir_access => DirAccess,
            .dir_read => DirRead,
            .dir_real_path => DirRealPath,
            .dir_real_path_file => DirRealPathFile,
            .file_real_path => FileRealPath,
            .file_hard_link => FileHardLink,
            .pipe_poll => PipePoll,
            .pipe_create => PipeCreate,
            .pipe_close => PipeClose,
            .device_io_control => DeviceIoControl,
            .mach_port => MachPort,
            .process_wait => ProcessWait,
        };
    }

    /// Get the operation type from a completion type
    pub fn fromType(comptime T: type) Op {
        return switch (T) {
            Group => .group,
            Timer => .timer,
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
            NetRecvMsg => .net_recvmsg,
            NetSendMsg => .net_sendmsg,
            NetPoll => .net_poll,
            NetClose => .net_close,
            NetShutdown => .net_shutdown,
            NetSendFile => .net_send_file,
            FileOpen => .file_open,
            FileCreate => .file_create,
            FileClose => .file_close,
            FileRead => .file_read,
            FileWrite => .file_write,
            FileReadStreaming => .file_read_streaming,
            FileWriteStreaming => .file_write_streaming,
            FileSync => .file_sync,
            FileSetSize => .file_set_size,
            FileSetPermissions => .file_set_permissions,
            FileSetOwner => .file_set_owner,
            FileSetTimestamps => .file_set_timestamps,
            DirCreateDir => .dir_create_dir,
            DirRename => .dir_rename,
            DirRenamePreserve => .dir_rename_preserve,
            DirDeleteFile => .dir_delete_file,
            DirDeleteDir => .dir_delete_dir,
            FileSize => .file_size,
            FileStat => .file_stat,
            DirOpen => .dir_open,
            DirClose => .dir_close,
            DirSetPermissions => .dir_set_permissions,
            DirSetOwner => .dir_set_owner,
            DirSetFilePermissions => .dir_set_file_permissions,
            DirSetFileOwner => .dir_set_file_owner,
            DirSetFileTimestamps => .dir_set_file_timestamps,
            DirSymLink => .dir_sym_link,
            DirReadLink => .dir_read_link,
            DirHardLink => .dir_hard_link,
            DirAccess => .dir_access,
            DirRead => .dir_read,
            DirRealPath => .dir_real_path,
            DirRealPathFile => .dir_real_path_file,
            FileRealPath => .file_real_path,
            FileHardLink => .file_hard_link,
            PipePoll => .pipe_poll,
            PipeCreate => .pipe_create,
            PipeClose => .pipe_close,
            DeviceIoControl => .device_io_control,
            MachPort => .mach_port,
            ProcessWait => .process_wait,
            else => @compileError("unknown completion type"),
        };
    }
};

pub const Completion = struct {
    pub const Flags = packed struct(u8) {
        /// Finish through the completions queue instead of synchronously from
        /// whatever context completed the op; a deferred callback may freely
        /// chain further operations. Opt out only when the callback just
        /// records a result or wakes a waiter (waitForIo does).
        defer_callback: bool = true,
        /// Re-add the completion after its callback returns (persistent
        /// handles). Implies the deferred finish: a synchronous re-add can
        /// recurse when the handle completes immediately. The callback must
        /// not free the completion.
        rearm: bool = false,
        _reserved: u6 = 0,
    };

    op: Op,
    state: State = .new,

    flags: Flags = .{},

    userdata: ?*anyopaque = null,
    callback: ?*const CallbackFn = null,

    /// Loop this completion was submitted to. Set by `Loop.add`/`Loop.setTimer`,
    /// cleared by `reset`. Read cross-thread (`Async.notify`, cancel routing,
    /// finish routing), so always access through `setLoop`/`getLoop`.
    loop: ?*Loop = null,

    /// Cross-thread cancellation state (atomic for thread-safe cancel)
    cancel_state: std.atomic.Value(CancelState) = .init(.{}),

    /// Cancel queue intrusive linked list
    cancel_next: ?*Completion = null,

    /// Intrusive node for group/queue membership.
    /// Used by ev.Group to link children, and by CompletionQueue for pending/completed tracking.
    /// A completion can only be in one group or queue at a time.
    group: struct {
        next: ?*@This() = null,
        prev: ?*@This() = null,
        owner: ?*anyopaque = null,
        owner_callback: ?*const fn (*Loop, *Completion) void = null,
        userdata: usize = 0,
        in_list: if (std.debug.runtime_safety) bool else void =
            if (std.debug.runtime_safety) false else {},
    } = .{},

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

    /// Atomic state for cross-thread cancellation coordination
    pub const CancelState = packed struct(u8) {
        requested: bool = false, // Cancel was requested
        in_queue: bool = false, // Completion is in cancel queue, queue will call finish
        completed: bool = false, // markCompleted ran, result is set
        _pad: u5 = 0,
    };

    pub const CallbackFn = fn (
        loop: *Loop,
        completion: *Completion,
    ) void;

    pub fn init(op: Op) Completion {
        return .{ .op = op };
    }

    pub fn setLoop(c: *Completion, loop: ?*Loop) void {
        @atomicStore(?*Loop, &c.loop, loop, .release);
    }

    pub fn getLoop(c: *const Completion) ?*Loop {
        return @atomicLoad(?*Loop, &c.loop, .acquire);
    }

    pub fn reset(c: *Completion) void {
        c.state = .new;
        c.has_result = false;
        c.err = null;
        // An Async.notify() landing in the null window between this and the
        // re-add's setLoop is picked up by add() via the `pending` flag.
        c.setLoop(null);
        c.cancel_state.store(.{}, .release);
        c.cancel_next = null;
        c.group.next = null;
        c.group.prev = null;
        c.group.owner = null;
        c.group.owner_callback = null;
        c.group.userdata = 0;
        if (std.debug.runtime_safety) {
            c.group.in_list = false;
        }
    }

    pub fn call(c: *Completion, loop: *Loop) void {
        if (c.callback) |func| {
            func(loop, c);
        }
    }

    pub fn cast(c: *Completion, comptime T: type) *T {
        std.debug.assert(c.op == Op.fromType(T));
        return @alignCast(@fieldParentPtr("c", c));
    }

    pub fn getResult(c: *const Completion, comptime op: Op) (op.toType().Error)!@FieldType(op.toType(), "result_private_do_not_touch") {
        std.debug.assert(c.has_result);
        std.debug.assert(c.op == op);
        if (c.err) |err| return @errorCast(err);
        const T = op.toType();
        const parent: *const T = @alignCast(@fieldParentPtr("c", c));
        return parent.result_private_do_not_touch;
    }

    pub fn setError(c: *Completion, err: anyerror) void {
        std.debug.assert(!c.has_result);
        c.err = err;
        c.has_result = true;
    }

    pub fn setResult(c: *Completion, comptime op: Op, result: @FieldType(op.toType(), "result_private_do_not_touch")) void {
        std.debug.assert(!c.has_result);
        std.debug.assert(c.op == op);
        const T = op.toType();
        c.cast(T).result_private_do_not_touch = result;
        c.has_result = true;
    }
};

pub const Cancelable = error{Canceled};

pub const Group = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    head: ?*GroupNode = null,
    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    race: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const GroupNode = @FieldType(Completion, "group");

    pub const Error = Cancelable;

    pub const Mode = enum { gather, race };

    pub fn init(mode: Mode) Group {
        return .{
            .c = .init(.group),
            .race = std.atomic.Value(bool).init(mode == .race),
        };
    }

    /// Add a completion to this group. Must be called before submitting the group.
    pub fn add(self: *Group, c: *Completion) void {
        std.debug.assert(c.state == .new);
        std.debug.assert(self.c.state == .new); // Group must not be submitted yet
        std.debug.assert(c.group.owner == null);
        std.debug.assert(!c.flags.rearm); // groups are single-shot
        c.group.next = self.head;
        c.group.owner = self;
        c.group.owner_callback = &groupCallback;
        self.head = &c.group;
        _ = self.remaining.fetchAdd(1, .monotonic);
    }

    fn groupCallback(loop: *Loop, completion: *Completion) void {
        const self: *Group = @ptrCast(@alignCast(completion.group.owner.?));

        // Race mode: first to clear the flag wins, cancels siblings.
        //
        // This MUST run before the `remaining` decrement below. With a
        // multi-threaded backend (IOCP, or epoll/kqueue once a socket op is
        // serviced cross-loop) the children of a race group can complete
        // concurrently on different loops - e.g. the I/O on the owner loop and
        // its timeout timer on the submitting loop. Whichever thread drives
        // `remaining` to zero completes the group and wakes its waiter, which
        // frees the stack frame the Group (and the sibling completions) live on.
        // If we decremented first, that free could happen while this thread is
        // still walking `self.head` to cancel siblings -> use-after-free. By
        // cancelling before decrementing, `remaining` stays >= 1 for the duration
        // of this loop, so the frame cannot be freed until the final decrementer
        // runs - by which point every sibling cancellation has completed.
        if (self.race.swap(false, .acq_rel)) {
            var node = self.head;
            while (node) |n| {
                const next = n.next;
                const c: *Completion = @fieldParentPtr("group", n);
                if (c != completion) {
                    loop.cancel(c);
                }
                node = next;
            }
        }

        const prev = self.remaining.fetchSub(1, .acq_rel);
        if (prev == 1) {
            if (self.c.cancel_state.load(.acquire).requested) {
                self.c.setError(error.Canceled);
            } else {
                self.c.setResult(.group, {});
            }
            loop.state.markCompleted(&self.c);
        }
    }

    pub fn getResult(self: *const Group) Error!void {
        return self.c.getResult(.group);
    }
};

pub const Timer = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    timeout: Timeout,
    /// Clock the `timeout`/`deadline` is measured against. Only the wall-clock
    /// clocks are valid for a timer; the CPU-time clocks are rejected when the
    /// timer is set. Defaults to `.awake` (monotonic), the historical behavior.
    clock: Clock = .awake,
    deadline: Timestamp = .zero,
    heap: HeapNode(Timer) = .{},

    pub const Error = Cancelable;

    pub fn init(timeout: Timeout) Timer {
        return .{
            .c = .init(.timer),
            .timeout = timeout,
        };
    }

    pub fn initClock(timeout: Timeout, clock: Clock) Timer {
        return .{
            .c = .init(.timer),
            .timeout = timeout,
            .clock = clock,
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

    pub const Error = Cancelable;

    pub fn init() Async {
        return .{
            .c = .init(.async),
        };
    }

    /// Notify the loop to wake up and complete this async handle (thread-safe)
    pub fn notify(self: *Async) void {
        // Pairs with the `pending` swap in Loop.add: both are acq_rel RMWs on
        // the same variable, so they order against each other. If add's swap
        // came first, the acquire here makes its setLoop visible and we wake
        // the loop; if ours came first, add sees `pending` set and completes
        // the handle itself. Reading a null loop therefore proves add will
        // handle it.
        const was_pending = self.pending.swap(1, .acq_rel);
        if (was_pending == 0) {
            if (self.c.getLoop()) |loop| {
                loop.wakeAsync();
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

    func: *const fn (work: *Work) void,
    userdata: ?*anyopaque,

    completion_fn: ?*const fn (ctx: ?*anyopaque, work: *Work) void = null,
    completion_context: ?*anyopaque = null,
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.pending),

    /// Optional token enabling cancellation of blocking syscalls made by `func`.
    /// When set, the worker binds it (`enter`/`exit`) around `func`, and
    /// `ThreadPool.cancel` signals it to interrupt an in-progress syscall.
    cancel_token: ?*os.syscall_cancel.Token = null,

    /// When set, the pool guarantees a worker will pick this job up: at submit it
    /// reuses an idle worker if one is free, and only spawns a new worker (beyond
    /// `max_threads` if needed) when idle workers can't cover every outstanding
    /// reserved job. Used to honor std.Io's `concurrent` guarantee from a
    /// saturated pool without deadlocking — a job queued behind blocked workers
    /// that are themselves waiting on it. See issue #567.
    reserve_thread: bool = false,

    /// Intrusive link + membership key for the loop's cancel-resend list
    /// (`Loop.cancel_resend`). A canceled-but-still-blocked worker is added here
    /// so `tick` re-sends `SIGURG` until it acknowledges. `resend_key` is the
    /// public completion whose finalization removes this work from the list
    /// (== `&c` for a plain `.work` op, or the owning op's completion for a
    /// delegated file op); non-null means "in the list". Touched only on the
    /// owning loop's thread.
    resend_next: ?*Work = null,
    resend_key: ?*Completion = null,

    pub const Error = error{NoThreadPool} || Cancelable;

    pub const State = enum(u8) {
        pending,
        running,
        completed,
        canceled,
    };

    pub fn init(func: *const fn (work: *Work) void, userdata: ?*anyopaque) Work {
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
    protocol: net.Protocol = .ip,
    flags: net.OpenFlags = .{ .nonblocking = true },

    pub const Error = net.OpenError || Cancelable;

    pub fn init(
        domain: net.Domain,
        socket_type: net.Type,
        protocol: net.Protocol,
        flags: net.OpenFlags,
    ) NetOpen {
        return .{
            .c = .init(.net_open),
            .domain = domain,
            .socket_type = socket_type,
            .protocol = protocol,
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

/// Transfer the contents of a file to a socket ("sendfile").
///
/// Backends that advertise `net_send_file` handle this natively (e.g. io_uring
/// splice). Otherwise the loop drives a generic read/write callback loop using
/// the `Fallback` state below: read a chunk from the file into `buf`, send it to
/// the socket, repeat until EOF or `remaining` is exhausted. Socket short-writes
/// drain the remaining buffer before the next read.
pub const NetSendFile = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,

    /// Destination socket.
    handle: Backend.NetHandle,
    /// Source file.
    file: fs.fd_t,
    /// Current read offset into the file.
    offset: u64,
    /// Bytes still allowed to send (use `maxInt(usize)` for the whole file).
    remaining: usize,
    /// Up to two scratch buffers borrowed from the caller for the generic
    /// fallback loop. If both are non-empty the loop double-buffers (read into
    /// one while sending the other); if only `bufs[0]` is non-empty it runs a
    /// serial read-then-send loop. The two buffers may differ in size (e.g. the
    /// writer's buffer and the reader's buffer). Unused by native backends.
    bufs: [2][]u8,

    internal: switch (Backend.capabilities.net_send_file) {
        true => if (@hasDecl(Backend, "NetSendFileData")) Backend.NetSendFileData else struct {},
        false => Fallback,
    } = .{},

    /// State for the generic read/write loop. Unused by native backends.
    pub const Fallback = struct {
        read: FileRead = undefined,
        send: NetSend = undefined,
        /// Two ping-pong transfer buffers (userspace equivalent of the splice
        /// pipe). One is filled by a read while the other is drained by a send.
        /// Derived from the caller's buffers by `netSendFileStart`; an empty
        /// `bufs[1]` means a single-buffer serial loop.
        bufs: [2][]u8 = .{ &.{}, &.{} },
        /// Bytes available in each buffer (0 = empty/free).
        filled: [2]usize = .{ 0, 0 },
        /// Drain cursor within the buffer currently being sent.
        sent: [2]usize = .{ 0, 0 },
        /// Next buffer index to read into / send from (both alternate 0,1,0,1
        /// from the same start, preserving send order).
        next_read: u1 = 0,
        next_send: u1 = 0,
        /// Index of the buffer with a read / send currently in flight.
        reading: ?u1 = null,
        sending: ?u1 = null,
        /// Set once the source file is exhausted.
        eof: bool = false,
        /// Bytes still allowed to be read from the file (the limit).
        read_remaining: usize = 0,
        /// Total bytes sent so far (the operation result).
        total: usize = 0,
        /// First error (or cancel) seen; parked until the sibling op drains.
        pending_err: ?anyerror = null,
        read_iov: [1]os.iovec = undefined,
        send_iov: [1]os.iovec_const = undefined,
    };

    pub const Error = (net.SendError || fs.FileReadError) || Cancelable;

    /// `bufs` are borrowed for the generic fallback loop and must outlive the
    /// operation. Provide two non-empty buffers for double-buffering, or one
    /// (with `bufs[1]` empty) for a serial loop. `bufs[0]` must be non-empty.
    /// Native backends ignore `bufs`.
    pub fn init(handle: Backend.NetHandle, file: fs.fd_t, offset: u64, limit: usize, bufs: [2][]u8) NetSendFile {
        return .{
            .c = .init(.net_send_file),
            .handle = handle,
            .file = file,
            .offset = offset,
            .remaining = limit,
            .bufs = bufs,
        };
    }

    pub fn getResult(self: *const NetSendFile) Error!usize {
        return self.c.getResult(.net_send_file);
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

pub const NetRecvMsg = struct {
    c: Completion,
    result_private_do_not_touch: net.RecvMsgResult = undefined,
    internal: if (@hasDecl(Backend, "NetRecvMsgData")) Backend.NetRecvMsgData else struct {} = .{},
    handle: Backend.NetHandle,
    data: ReadBuf,
    flags: net.RecvFlags,
    addr: ?*net.sockaddr,
    addr_len: ?*net.socklen_t,
    control: ?[]u8,

    pub const Error = net.RecvError || Cancelable;
    pub const Result = net.RecvMsgResult;

    pub fn init(
        handle: Backend.NetHandle,
        data: ReadBuf,
        flags: net.RecvFlags,
        addr: ?*net.sockaddr,
        addr_len: ?*net.socklen_t,
        control: ?[]u8,
    ) NetRecvMsg {
        return .{
            .c = .init(.net_recvmsg),
            .handle = handle,
            .data = data,
            .flags = flags,
            .addr = addr,
            .addr_len = addr_len,
            .control = control,
        };
    }

    pub fn getResult(self: *const NetRecvMsg) Error!Result {
        return self.c.getResult(.net_recvmsg);
    }
};

pub const NetSendMsg = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: if (@hasDecl(Backend, "NetSendMsgData")) Backend.NetSendMsgData else struct {} = .{},
    handle: Backend.NetHandle,
    data: WriteBuf,
    flags: net.SendFlags,
    addr: ?*const net.sockaddr,
    addr_len: net.socklen_t,
    control: ?[]const u8,

    pub const Error = net.SendError || Cancelable;

    pub fn init(
        handle: Backend.NetHandle,
        data: WriteBuf,
        flags: net.SendFlags,
        addr: ?*const net.sockaddr,
        addr_len: net.socklen_t,
        control: ?[]const u8,
    ) NetSendMsg {
        return .{
            .c = .init(.net_sendmsg),
            .handle = handle,
            .data = data,
            .flags = flags,
            .addr = addr,
            .addr_len = addr_len,
            .control = control,
        };
    }

    pub fn getResult(self: *const NetSendMsg) Error!usize {
        return self.c.getResult(.net_sendmsg);
    }
};

/// Result of a file open/create: the new fd plus whether it is pollable
/// (non-seekable). The pollable verdict is determined when the backend opens the
/// file via the thread pool (always false on backends with native open/streaming
/// and on Windows), letting callers seed streaming ops without re-probing.
pub const FileOpenResult = struct {
    fd: fs.fd_t,
    pollable: bool = false,
};

/// Shared `internal` payload for file/dir ops delegated to the thread pool on
/// backends without native async support (kqueue/poll). Bundles the pool `Work`,
/// the loop linkage, an allocator slot (used by path-based ops), and the syscall
/// cancellation token bound by the worker. The cancel-resend list link lives on
/// the embedded `work` (see `Work.resend_next`/`resend_key`); `linked_context.linked`
/// back-points to the owning `Completion` and is used as the work's `resend_key`,
/// so the loop finds the entry from a completion at finalization without any
/// per-op-type knowledge.
pub const DelegatedWork = struct {
    work: Work = undefined,
    allocator: std.mem.Allocator = undefined,
    linked_context: Loop.LinkedWorkContext = undefined,
    /// Bound by the worker (`enter`/`exit`) around the syscall; signaled on
    /// cancel. See `os.syscall_cancel`. The cancel-resend linkage now lives on
    /// the embedded `work` (see `Work.resend_next`/`resend_key`), keyed on
    /// `linked_context.linked` so it is reachable generically from a completion.
    token: os.syscall_cancel.Token = .{},
};

pub const FileOpen = struct {
    c: Completion,
    result_private_do_not_touch: FileOpenResult = undefined,
    internal: switch (Backend.capabilities.file_open) {
        true => if (@hasDecl(Backend, "FileOpenData")) Backend.FileOpenData else struct {},
        false => DelegatedWork,
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

    pub fn getResult(self: *const FileOpen) Error!FileOpenResult {
        return self.c.getResult(.file_open);
    }
};

pub const FileCreate = struct {
    c: Completion,
    result_private_do_not_touch: FileOpenResult = undefined,
    internal: switch (Backend.capabilities.file_create) {
        true => if (@hasDecl(Backend, "FileCreateData")) Backend.FileCreateData else struct {},
        false => DelegatedWork,
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

    pub fn getResult(self: *const FileCreate) Error!FileOpenResult {
        return self.c.getResult(.file_create);
    }
};

pub const FileClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_close) {
        true => if (@hasDecl(Backend, "FileCloseData")) Backend.FileCloseData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,

    pub const Error = fs.FileCloseError || Cancelable;

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
        false => DelegatedWork,
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
        false => DelegatedWork,
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

pub const FileReadStreaming = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.file_read_streaming) {
        true => if (@hasDecl(Backend, "FileReadStreamingData")) Backend.FileReadStreamingData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    buffer: ReadBuf,
    /// Whether `handle` is pollable (non-seekable). `null` until classified by
    /// the loop on first submission; backends with a readiness path use the
    /// poll path when true and the thread pool when false. Callers may seed a
    /// cached value to skip re-classification, and may read it back afterwards.
    pollable: ?bool = null,

    pub const Error = fs.FileReadError || Cancelable;

    pub fn init(handle: fs.fd_t, buffer: ReadBuf) FileReadStreaming {
        return .{
            .c = .init(.file_read_streaming),
            .handle = handle,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const FileReadStreaming) Error!usize {
        return self.c.getResult(.file_read_streaming);
    }
};

pub const FileWriteStreaming = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.file_write_streaming) {
        true => if (@hasDecl(Backend, "FileWriteStreamingData")) Backend.FileWriteStreamingData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    buffer: WriteBuf,
    /// Whether `handle` is pollable (non-seekable). `null` until classified by
    /// the loop on first submission; backends with a readiness path use the
    /// poll path when true and the thread pool when false. Callers may seed a
    /// cached value to skip re-classification, and may read it back afterwards.
    pollable: ?bool = null,

    pub const Error = fs.FileWriteError || Cancelable;

    pub fn init(handle: fs.fd_t, buffer: WriteBuf) FileWriteStreaming {
        return .{
            .c = .init(.file_write_streaming),
            .handle = handle,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const FileWriteStreaming) Error!usize {
        return self.c.getResult(.file_write_streaming);
    }
};

pub const FileSync = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_sync) {
        true => if (@hasDecl(Backend, "FileSyncData")) Backend.FileSyncData else struct {},
        false => DelegatedWork,
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

pub const FileSetSize = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_set_size) {
        true => if (@hasDecl(Backend, "FileSetSizeData")) Backend.FileSetSizeData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    length: u64,

    pub const Error = fs.FileSetSizeError || Cancelable;

    pub fn init(handle: fs.fd_t, length: u64) FileSetSize {
        return .{
            .c = .init(.file_set_size),
            .handle = handle,
            .length = length,
        };
    }

    pub fn getResult(self: *const FileSetSize) Error!void {
        return self.c.getResult(.file_set_size);
    }
};

pub const FileSetPermissions = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_set_permissions) {
        true => if (@hasDecl(Backend, "FileSetPermissionsData")) Backend.FileSetPermissionsData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    mode: fs.mode_t,

    pub const Error = fs.FileSetPermissionsError || Cancelable;

    pub fn init(handle: fs.fd_t, mode: fs.mode_t) FileSetPermissions {
        return .{
            .c = .init(.file_set_permissions),
            .handle = handle,
            .mode = mode,
        };
    }

    pub fn getResult(self: *const FileSetPermissions) Error!void {
        return self.c.getResult(.file_set_permissions);
    }
};

pub const FileSetOwner = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_set_owner) {
        true => if (@hasDecl(Backend, "FileSetOwnerData")) Backend.FileSetOwnerData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    uid: ?fs.uid_t,
    gid: ?fs.gid_t,

    pub const Error = fs.FileSetOwnerError || Cancelable;

    pub fn init(handle: fs.fd_t, uid: ?fs.uid_t, gid: ?fs.gid_t) FileSetOwner {
        return .{
            .c = .init(.file_set_owner),
            .handle = handle,
            .uid = uid,
            .gid = gid,
        };
    }

    pub fn getResult(self: *const FileSetOwner) Error!void {
        return self.c.getResult(.file_set_owner);
    }
};

pub const FileSetTimestamps = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_set_timestamps) {
        true => if (@hasDecl(Backend, "FileSetTimestampsData")) Backend.FileSetTimestampsData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    timestamps: fs.FileTimestamps,

    pub const Error = fs.FileSetTimestampsError || Cancelable;

    pub fn init(handle: fs.fd_t, timestamps: fs.FileTimestamps) FileSetTimestamps {
        return .{
            .c = .init(.file_set_timestamps),
            .handle = handle,
            .timestamps = timestamps,
        };
    }

    pub fn getResult(self: *const FileSetTimestamps) Error!void {
        return self.c.getResult(.file_set_timestamps);
    }
};

pub const DirSetPermissions = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_set_permissions) {
        true => if (@hasDecl(Backend, "DirSetPermissionsData")) Backend.DirSetPermissionsData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    mode: fs.mode_t,

    pub const Error = fs.FileSetPermissionsError || Cancelable;

    pub fn init(handle: fs.fd_t, mode: fs.mode_t) DirSetPermissions {
        return .{
            .c = .init(.dir_set_permissions),
            .handle = handle,
            .mode = mode,
        };
    }

    pub fn getResult(self: *const DirSetPermissions) Error!void {
        return self.c.getResult(.dir_set_permissions);
    }
};

pub const DirSetOwner = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_set_owner) {
        true => if (@hasDecl(Backend, "DirSetOwnerData")) Backend.DirSetOwnerData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    uid: ?fs.uid_t,
    gid: ?fs.gid_t,

    pub const Error = fs.FileSetOwnerError || Cancelable;

    pub fn init(handle: fs.fd_t, uid: ?fs.uid_t, gid: ?fs.gid_t) DirSetOwner {
        return .{
            .c = .init(.dir_set_owner),
            .handle = handle,
            .uid = uid,
            .gid = gid,
        };
    }

    pub fn getResult(self: *const DirSetOwner) Error!void {
        return self.c.getResult(.dir_set_owner);
    }
};

pub const DirSetFilePermissions = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_set_file_permissions) {
        true => if (@hasDecl(Backend, "DirSetFilePermissionsData")) Backend.DirSetFilePermissionsData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    mode: fs.mode_t,
    flags: fs.PathSetFlags,

    pub const Error = fs.FileSetPermissionsError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, mode: fs.mode_t, flags: fs.PathSetFlags) DirSetFilePermissions {
        return .{
            .c = .init(.dir_set_file_permissions),
            .dir = dir,
            .path = path,
            .mode = mode,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirSetFilePermissions) Error!void {
        return self.c.getResult(.dir_set_file_permissions);
    }
};

pub const DirSetFileOwner = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_set_file_owner) {
        true => if (@hasDecl(Backend, "DirSetFileOwnerData")) Backend.DirSetFileOwnerData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    uid: ?fs.uid_t,
    gid: ?fs.gid_t,
    flags: fs.PathSetFlags,

    pub const Error = fs.FileSetOwnerError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, uid: ?fs.uid_t, gid: ?fs.gid_t, flags: fs.PathSetFlags) DirSetFileOwner {
        return .{
            .c = .init(.dir_set_file_owner),
            .dir = dir,
            .path = path,
            .uid = uid,
            .gid = gid,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirSetFileOwner) Error!void {
        return self.c.getResult(.dir_set_file_owner);
    }
};

pub const DirSetFileTimestamps = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_set_file_timestamps) {
        true => if (@hasDecl(Backend, "DirSetFileTimestampsData")) Backend.DirSetFileTimestampsData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    timestamps: fs.FileTimestamps,
    flags: fs.PathSetFlags,

    pub const Error = fs.FileSetTimestampsError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, timestamps: fs.FileTimestamps, flags: fs.PathSetFlags) DirSetFileTimestamps {
        return .{
            .c = .init(.dir_set_file_timestamps),
            .dir = dir,
            .path = path,
            .timestamps = timestamps,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirSetFileTimestamps) Error!void {
        return self.c.getResult(.dir_set_file_timestamps);
    }
};

pub const DirSymLink = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_sym_link) {
        true => if (@hasDecl(Backend, "DirSymLinkData")) Backend.DirSymLinkData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    target: []const u8,
    link_path: []const u8,
    flags: fs.SymLinkFlags,

    pub const Error = fs.SymLinkError || Cancelable;

    pub fn init(dir: fs.fd_t, target: []const u8, link_path: []const u8, flags: fs.SymLinkFlags) DirSymLink {
        return .{
            .c = .init(.dir_sym_link),
            .dir = dir,
            .target = target,
            .link_path = link_path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirSymLink) Error!void {
        return self.c.getResult(.dir_sym_link);
    }
};

pub const DirReadLink = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.dir_read_link) {
        true => if (@hasDecl(Backend, "DirReadLinkData")) Backend.DirReadLinkData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    buffer: []u8,

    pub const Error = fs.ReadLinkError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, buffer: []u8) DirReadLink {
        return .{
            .c = .init(.dir_read_link),
            .dir = dir,
            .path = path,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const DirReadLink) Error!usize {
        return self.c.getResult(.dir_read_link);
    }
};

pub const DirHardLink = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_hard_link) {
        true => if (@hasDecl(Backend, "DirHardLinkData")) Backend.DirHardLinkData else struct {},
        false => DelegatedWork,
    } = .{},
    old_dir: fs.fd_t,
    old_path: []const u8,
    new_dir: fs.fd_t,
    new_path: []const u8,
    flags: fs.HardLinkFlags,

    pub const Error = fs.HardLinkError || Cancelable;

    pub fn init(old_dir: fs.fd_t, old_path: []const u8, new_dir: fs.fd_t, new_path: []const u8, flags: fs.HardLinkFlags) DirHardLink {
        return .{
            .c = .init(.dir_hard_link),
            .old_dir = old_dir,
            .old_path = old_path,
            .new_dir = new_dir,
            .new_path = new_path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirHardLink) Error!void {
        return self.c.getResult(.dir_hard_link);
    }
};

pub const DirAccess = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_access) {
        true => if (@hasDecl(Backend, "DirAccessData")) Backend.DirAccessData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    flags: fs.AccessFlags,

    pub const Error = fs.DirAccessError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, flags: fs.AccessFlags) DirAccess {
        return .{
            .c = .init(.dir_access),
            .dir = dir,
            .path = path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirAccess) Error!void {
        return self.c.getResult(.dir_access);
    }
};

pub const DirRealPath = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.dir_real_path) {
        true => if (@hasDecl(Backend, "DirRealPathData")) Backend.DirRealPathData else struct {},
        false => DelegatedWork,
    } = .{},
    fd: fs.fd_t,
    buffer: []u8,

    pub const Error = fs.DirRealPathError || Cancelable;

    pub fn init(fd: fs.fd_t, buffer: []u8) DirRealPath {
        return .{
            .c = .init(.dir_real_path),
            .fd = fd,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const DirRealPath) Error!usize {
        return self.c.getResult(.dir_real_path);
    }
};

pub const DirRealPathFile = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.dir_real_path_file) {
        true => if (@hasDecl(Backend, "DirRealPathFileData")) Backend.DirRealPathFileData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    buffer: []u8,

    pub const Error = fs.DirRealPathFileError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, buffer: []u8) DirRealPathFile {
        return .{
            .c = .init(.dir_real_path_file),
            .dir = dir,
            .path = path,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const DirRealPathFile) Error!usize {
        return self.c.getResult(.dir_real_path_file);
    }
};

pub const FileRealPath = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.file_real_path) {
        true => if (@hasDecl(Backend, "FileRealPathData")) Backend.FileRealPathData else struct {},
        false => DelegatedWork,
    } = .{},
    fd: fs.fd_t,
    buffer: []u8,

    pub const Error = fs.DirRealPathError || Cancelable;

    pub fn init(fd: fs.fd_t, buffer: []u8) FileRealPath {
        return .{
            .c = .init(.file_real_path),
            .fd = fd,
            .buffer = buffer,
        };
    }

    pub fn getResult(self: *const FileRealPath) Error!usize {
        return self.c.getResult(.file_real_path);
    }
};

pub const FileHardLink = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.file_hard_link) {
        true => if (@hasDecl(Backend, "FileHardLinkData")) Backend.FileHardLinkData else struct {},
        false => DelegatedWork,
    } = .{},
    fd: fs.fd_t,
    new_dir: fs.fd_t,
    new_path: []const u8,
    flags: fs.HardLinkFlags,

    pub const Error = fs.FileHardLinkError || Cancelable;

    pub fn init(fd: fs.fd_t, new_dir: fs.fd_t, new_path: []const u8, flags: fs.HardLinkFlags) FileHardLink {
        return .{
            .c = .init(.file_hard_link),
            .fd = fd,
            .new_dir = new_dir,
            .new_path = new_path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const FileHardLink) Error!void {
        return self.c.getResult(.file_hard_link);
    }
};

pub const DirCreateDir = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_create_dir) {
        true => if (@hasDecl(Backend, "DirCreateDirData")) Backend.DirCreateDirData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    mode: fs.mode_t,

    pub const Error = fs.DirCreateDirError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, mode: fs.mode_t) DirCreateDir {
        return .{
            .c = .init(.dir_create_dir),
            .dir = dir,
            .path = path,
            .mode = mode,
        };
    }

    pub fn getResult(self: *const DirCreateDir) Error!void {
        return self.c.getResult(.dir_create_dir);
    }
};

pub const DirRename = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_rename) {
        true => if (@hasDecl(Backend, "DirRenameData")) Backend.DirRenameData else struct {},
        false => DelegatedWork,
    } = .{},
    old_dir: fs.fd_t,
    old_path: []const u8,
    new_dir: fs.fd_t,
    new_path: []const u8,

    pub const Error = fs.DirRenameError || Cancelable;

    pub fn init(old_dir: fs.fd_t, old_path: []const u8, new_dir: fs.fd_t, new_path: []const u8) DirRename {
        return .{
            .c = .init(.dir_rename),
            .old_dir = old_dir,
            .old_path = old_path,
            .new_dir = new_dir,
            .new_path = new_path,
        };
    }

    pub fn getResult(self: *const DirRename) Error!void {
        return self.c.getResult(.dir_rename);
    }
};

pub const DirRenamePreserve = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_rename_preserve) {
        true => if (@hasDecl(Backend, "DirRenamePreserveData")) Backend.DirRenamePreserveData else struct {},
        false => DelegatedWork,
    } = .{},
    old_dir: fs.fd_t,
    old_path: []const u8,
    new_dir: fs.fd_t,
    new_path: []const u8,

    pub const Error = fs.DirRenamePreserveError || Cancelable;

    pub fn init(old_dir: fs.fd_t, old_path: []const u8, new_dir: fs.fd_t, new_path: []const u8) DirRenamePreserve {
        return .{
            .c = .init(.dir_rename_preserve),
            .old_dir = old_dir,
            .old_path = old_path,
            .new_dir = new_dir,
            .new_path = new_path,
        };
    }

    pub fn getResult(self: *const DirRenamePreserve) Error!void {
        return self.c.getResult(.dir_rename_preserve);
    }
};

pub const DirDeleteFile = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_delete_file) {
        true => if (@hasDecl(Backend, "DirDeleteFileData")) Backend.DirDeleteFileData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,

    pub const Error = fs.DirDeleteFileError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8) DirDeleteFile {
        return .{
            .c = .init(.dir_delete_file),
            .dir = dir,
            .path = path,
        };
    }

    pub fn getResult(self: *const DirDeleteFile) Error!void {
        return self.c.getResult(.dir_delete_file);
    }
};

pub const DirDeleteDir = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_delete_dir) {
        true => if (@hasDecl(Backend, "DirDeleteDirData")) Backend.DirDeleteDirData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,

    pub const Error = fs.DirDeleteDirError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8) DirDeleteDir {
        return .{
            .c = .init(.dir_delete_dir),
            .dir = dir,
            .path = path,
        };
    }

    pub fn getResult(self: *const DirDeleteDir) Error!void {
        return self.c.getResult(.dir_delete_dir);
    }
};

pub const FileSize = struct {
    c: Completion,
    result_private_do_not_touch: u64 = undefined,
    internal: switch (Backend.capabilities.file_size) {
        true => if (@hasDecl(Backend, "FileSizeData")) Backend.FileSizeData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,

    pub const Error = fs.FileSizeError || Cancelable;

    pub fn init(handle: fs.fd_t) FileSize {
        return .{
            .c = .init(.file_size),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const FileSize) Error!u64 {
        return self.c.getResult(.file_size);
    }
};

pub const FileStat = struct {
    c: Completion,
    result_private_do_not_touch: fs.FileStatInfo = undefined,
    internal: switch (Backend.capabilities.file_stat) {
        true => if (@hasDecl(Backend, "FileStatData")) Backend.FileStatData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    path: ?[]const u8,
    flags: fs.FileStatFlags,

    pub const Error = fs.FileStatError || Cancelable;

    /// Initialize a file stat operation.
    /// If path is null, stats the file descriptor directly (fstat); `flags` is ignored.
    /// If path is provided, stats the file at path relative to handle (fstatat).
    pub fn init(handle: fs.fd_t, path: ?[]const u8, flags: fs.FileStatFlags) FileStat {
        return .{
            .c = .init(.file_stat),
            .handle = handle,
            .path = path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const FileStat) Error!fs.FileStatInfo {
        return self.c.getResult(.file_stat);
    }
};

pub const DirOpen = struct {
    c: Completion,
    result_private_do_not_touch: fs.fd_t = undefined,
    internal: switch (Backend.capabilities.dir_open) {
        true => if (@hasDecl(Backend, "DirOpenData")) Backend.DirOpenData else struct {},
        false => DelegatedWork,
    } = .{},
    dir: fs.fd_t,
    path: []const u8,
    flags: fs.DirOpenFlags,

    pub const Error = fs.DirOpenError || Cancelable;

    pub fn init(dir: fs.fd_t, path: []const u8, flags: fs.DirOpenFlags) DirOpen {
        return .{
            .c = .init(.dir_open),
            .dir = dir,
            .path = path,
            .flags = flags,
        };
    }

    pub fn getResult(self: *const DirOpen) Error!fs.fd_t {
        return self.c.getResult(.dir_open);
    }
};

pub const DirClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    internal: switch (Backend.capabilities.dir_close) {
        true => if (@hasDecl(Backend, "DirCloseData")) Backend.DirCloseData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,

    pub const Error = Cancelable;

    pub fn init(handle: fs.fd_t) DirClose {
        return .{
            .c = .init(.dir_close),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const DirClose) Error!void {
        return self.c.getResult(.dir_close);
    }
};

pub const DirRead = struct {
    c: Completion,
    result_private_do_not_touch: usize = undefined,
    internal: switch (Backend.capabilities.dir_read) {
        true => if (@hasDecl(Backend, "DirReadData")) Backend.DirReadData else struct {},
        false => DelegatedWork,
    } = .{},
    handle: fs.fd_t,
    buffer: []u8,
    restart: bool,

    pub const Error = fs.DirReadError || Cancelable;

    pub fn init(handle: fs.fd_t, buffer: []u8, restart: bool) DirRead {
        return .{
            .c = .init(.dir_read),
            .handle = handle,
            .buffer = buffer,
            .restart = restart,
        };
    }

    pub fn getResult(self: *const DirRead) Error!usize {
        return self.c.getResult(.dir_read);
    }
};

pub const NetPoll = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: Backend.NetHandle,
    event: Event,

    pub const Error = net.RecvError || Cancelable;

    /// Event to monitor for
    pub const Event = enum {
        recv,
        send,
    };

    pub fn init(handle: Backend.NetHandle, event: Event) NetPoll {
        return .{
            .c = .init(.net_poll),
            .handle = handle,
            .event = event,
        };
    }

    pub fn getResult(self: *const NetPoll) Error!void {
        return self.c.getResult(.net_poll);
    }
};

pub const PipePoll = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: fs.fd_t,
    event: Event,

    pub const Error = fs.FileReadError || fs.FileWriteError || Cancelable;

    /// Event to monitor for
    pub const Event = enum {
        read,
        write,
    };

    pub fn init(handle: fs.fd_t, event: Event) PipePoll {
        return .{
            .c = .init(.pipe_poll),
            .handle = handle,
            .event = event,
        };
    }

    pub fn getResult(self: *const PipePoll) Error!void {
        return self.c.getResult(.pipe_poll);
    }
};

pub const PipeCreate = struct {
    c: Completion,
    result_private_do_not_touch: [2]fs.fd_t = undefined,

    pub const Error = fs.PipeError || Cancelable;

    pub fn init() PipeCreate {
        return .{
            .c = .init(.pipe_create),
        };
    }

    pub fn getResult(self: *const PipeCreate) Error![2]fs.fd_t {
        return self.c.getResult(.pipe_create);
    }
};

pub const PipeClose = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: fs.fd_t,

    pub const Error = fs.FileCloseError || Cancelable;

    pub fn init(handle: fs.fd_t) PipeClose {
        return .{
            .c = .init(.pipe_close),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const PipeClose) Error!void {
        return self.c.getResult(.pipe_close);
    }
};

pub const DeviceIoControl = if (builtin.os.tag == .windows) struct {
    c: Completion,
    result_private_do_not_touch: std.os.windows.IO_STATUS_BLOCK = undefined,
    internal: struct { work: Work = undefined, linked_context: Loop.LinkedWorkContext = undefined } = .{},
    handle: fs.fd_t,
    code: std.os.windows.CTL_CODE,
    in: []const u8,
    out: []u8,

    pub const Result = std.os.windows.IO_STATUS_BLOCK;
    pub const Error = Cancelable;

    pub fn init(handle: fs.fd_t, code: std.os.windows.CTL_CODE, in: []const u8, out: []u8) DeviceIoControl {
        return .{
            .c = .init(.device_io_control),
            .handle = handle,
            .code = code,
            .in = in,
            .out = out,
        };
    }

    pub fn getResult(self: *const DeviceIoControl) Error!Result {
        return self.c.getResult(.device_io_control);
    }
} else struct {
    c: Completion,
    result_private_do_not_touch: i32 = undefined,
    internal: struct { work: Work = undefined, linked_context: Loop.LinkedWorkContext = undefined } = .{},
    handle: fs.fd_t,
    code: u32,
    arg: ?*anyopaque,

    pub const Result = i32;
    pub const Error = Cancelable;

    pub fn init(handle: fs.fd_t, code: u32, arg: ?*anyopaque) DeviceIoControl {
        return .{
            .c = .init(.device_io_control),
            .handle = handle,
            .code = code,
            .arg = arg,
        };
    }

    pub fn getResult(self: *const DeviceIoControl) Error!Result {
        return self.c.getResult(.device_io_control);
    }
};

pub const MachPort = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    port: u32,

    pub const Error = error{Unexpected} || Cancelable;

    pub fn init(port: u32) MachPort {
        return .{
            .c = .init(.mach_port),
            .port = port,
        };
    }

    pub fn getResult(self: *const MachPort) Error!void {
        return self.c.getResult(.mach_port);
    }
};

pub const ProcessWait = struct {
    c: Completion,
    result_private_do_not_touch: ExitStatus = undefined,
    handle: ProcessHandle,
    internal: switch (Backend.capabilities.process_wait) {
        true => if (@hasDecl(Backend, "ProcessWaitData")) Backend.ProcessWaitData else struct {},
        false => DelegatedWork,
    } = .{},

    pub const ProcessHandle = switch (builtin.os.tag) {
        .windows => std.os.windows.HANDLE,
        else => posix.sys.pid_t,
    };

    pub const ExitStatus = struct {
        code: u8,
        signal: ?u8 = null,
    };

    pub const Error = error{ ProcessNotFound, SystemResources, Unexpected } || Cancelable;

    pub fn init(handle: ProcessHandle) ProcessWait {
        return .{
            .c = .init(.process_wait),
            .handle = handle,
        };
    }

    pub fn getResult(self: *const ProcessWait) Error!ExitStatus {
        return self.c.getResult(.process_wait);
    }
};
