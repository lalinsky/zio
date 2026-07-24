const std = @import("std");
const os = @import("../../os/root.zig");
const windows = @import("../../os/windows.zig");
const net = @import("../../os/net.zig");
const fs = @import("../../os/fs.zig");
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const time = @import("../../os/time.zig");
const common = @import("common.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const NetOpen = @import("../completion.zig").NetOpen;
const NetConnect = @import("../completion.zig").NetConnect;
const NetAccept = @import("../completion.zig").NetAccept;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetRecvFrom = @import("../completion.zig").NetRecvFrom;
const NetSendTo = @import("../completion.zig").NetSendTo;
const NetRecvMsg = @import("../completion.zig").NetRecvMsg;
const NetSendMsg = @import("../completion.zig").NetSendMsg;
const NetPoll = @import("../completion.zig").NetPoll;
const NetSendFile = @import("../completion.zig").NetSendFile;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;
const FileSync = @import("../completion.zig").FileSync;
const PipeCreate = @import("../completion.zig").PipeCreate;
const FileReadStreaming = @import("../completion.zig").FileReadStreaming;
const FileWriteStreaming = @import("../completion.zig").FileWriteStreaming;
const PipeClose = @import("../completion.zig").PipeClose;
const ProcessWait = @import("../completion.zig").ProcessWait;

// WAIT_IO_COMPLETION is returned when an alertable wait is interrupted by an APC
const WAIT_IO_COMPLETION: windows.Win32Error = @enumFromInt(0xC0);

// Winsock extension function GUIDs
const WSAID_ACCEPTEX = windows.GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

const WSAID_WSARECVMSG = windows.GUID{
    .Data1 = 0xf689d7c8,
    .Data2 = 0x6f1f,
    .Data3 = 0x436b,
    .Data4 = .{ 0x8a, 0x53, 0xe5, 0x4f, 0xe3, 0x51, 0xc3, 0x22 },
};

const WSAID_WSASENDMSG = windows.GUID{
    .Data1 = 0xa441e712,
    .Data2 = 0x754f,
    .Data3 = 0x43ca,
    .Data4 = .{ 0x84, 0xa7, 0x0d, 0xee, 0x44, 0xcf, 0x60, 0x6d },
};

const WSAID_GETACCEPTEXSOCKADDRS = windows.GUID{
    .Data1 = 0xb5367df2,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_TRANSMITFILE = windows.GUID{
    .Data1 = 0xb5367df0,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

// Winsock extension function types
const LPFN_ACCEPTEX = *const fn (
    sListenSocket: windows.SOCKET,
    sAcceptSocket: windows.SOCKET,
    lpOutputBuffer: *anyopaque,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const LPFN_CONNECTEX = *const fn (
    s: windows.SOCKET,
    name: *const windows.sockaddr,
    namelen: c_int,
    lpSendBuffer: ?*const anyopaque,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const LPFN_GETACCEPTEXSOCKADDRS = *const fn (
    lpOutputBuffer: *anyopaque,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    LocalSockaddr: **windows.sockaddr,
    LocalSockaddrLength: *c_int,
    RemoteSockaddr: **windows.sockaddr,
    RemoteSockaddrLength: *c_int,
) callconv(.winapi) void;

const LPFN_WSARECVMSG = *const fn (
    s: windows.SOCKET,
    lpMsg: *windows.WSAMSG,
    lpdwNumberOfBytesRecvd: ?*windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRoutine: ?windows.LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) c_int;

const LPFN_WSASENDMSG = *const fn (
    s: windows.SOCKET,
    lpMsg: *const windows.WSAMSG_const,
    dwFlags: windows.DWORD,
    lpdwNumberOfBytesSent: ?*windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpCompletionRoutine: ?windows.LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) c_int;

const LPFN_TRANSMITFILE = *const fn (
    hSocket: windows.SOCKET,
    hFile: windows.HANDLE,
    nNumberOfBytesToWrite: windows.DWORD,
    nNumberOfBytesPerSend: windows.DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
    lpTransmitBuffers: ?*anyopaque,
    dwReserved: windows.DWORD,
) callconv(.winapi) windows.BOOL;

fn loadWinsockExtension(comptime T: type, sock: windows.SOCKET, guid: windows.GUID) !T {
    var func_ptr: T = undefined;
    var bytes: windows.DWORD = 0;

    const rc = windows.WSAIoctl(
        sock,
        windows.SIO_GET_EXTENSION_FUNCTION_POINTER,
        @constCast(&guid),
        @sizeOf(windows.GUID),
        @ptrCast(&func_ptr),
        @sizeOf(T),
        &bytes,
        null,
        null,
    );

    if (rc != 0) {
        return error.Unexpected;
    }

    return func_ptr;
}

pub const NetHandle = net.fd_t;

const BackendCapabilities = @import("../completion.zig").BackendCapabilities;

pub const capabilities: BackendCapabilities = .{
    .file_read = true,
    .file_write = true,
    // Streaming (positionless) read/write uses overlapped ReadFile/WriteFile
    // with a zero offset, but only for non-seekable handles (pipes/stdio).
    // Loop routes pollable fds here; seekable fds go to the thread pool.
    .file_read_streaming = false,
    .file_write_streaming = false,
    .process_wait = true,
    // Zero-copy file-to-socket transfer via the TransmitFile extension.
    .net_send_file = true,
    // Boot/real deadlines are armed via per-loop waitable timers whose
    // completion-routine APC fires during the alertable poll wait.
    .native_wall_timers = true,
};

// Backend-specific data stored in Completion.internal
pub const CompletionData = struct {
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    // Out-params for the overlapped call must live as long as the OVERLAPPED they
    // accompany: when an operation completes asynchronously the kernel may write
    // the transferred byte count (and, for a receive, the result flags) at
    // completion time — long after the submit function has returned. A stack
    // local would be a dangling write. The authoritative byte count is read from
    // WSAGetOverlappedResult at completion; `bytes` here is only backing storage
    // for the required out-param pointer. `flags` doubles as the in/out lpFlags
    // for WSARecv/WSARecvFrom (which cannot be NULL).
    bytes: windows.DWORD = 0,
    flags: windows.DWORD = 0,
};

// Backend-specific data stored in ProcessWait.internal
pub const ProcessWaitData = struct {
    wait_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    /// Atomic flag to ensure only one path (callback or cancel) posts to IOCP.
    posted: std.atomic.Value(bool) = .init(false),
};

// AcceptEx needs an extra buffer for address data
pub const NetAcceptData = struct {
    // AcceptEx requires a buffer for address data (local + remote addresses)
    // AcceptEx buffer layout: [receive_data][local_addr][remote_addr]
    // Each address slot needs: sizeof(sockaddr.storage) + 16
    // We use dwReceiveDataLength=0, so total = (sockaddr.storage + 16) * 2
    const addr_slot_size = @sizeOf(windows.sockaddr.storage) + 16;
    addr_buffer: [addr_slot_size * 2]u8 = undefined,
    family: u16 = 0, // Socket family, stored from submitAccept
};

pub const NetRecvMsgData = struct {
    msg: windows.WSAMSG = undefined,
    control_buf: windows.WSABUF_nullable = undefined,
};

pub const NetSendMsgData = struct {
    msg: windows.WSAMSG_const = undefined,
    control_buf: windows.WSABUF_nullable = undefined,
};

pub const NetSendFileData = struct {
    /// Total bytes sent so far across all per-call chunks (the op result).
    total: usize = 0,
    /// Bytes still to send for this op, after clamping to the file size and
    /// the caller's limit. Decremented as each chunk completes; the op is done
    /// once it reaches zero.
    left: usize = 0,
};

/// The maximum number of bytes a single TransmitFile call may transmit:
/// 2,147,483,646 (DWORD max minus one), per the Win32 documentation. Larger
/// transfers are split into multiple calls, advancing the file offset.
const transmit_file_max: usize = 2_147_483_646;

const ExtensionFunctions = struct {
    acceptex: LPFN_ACCEPTEX,
    connectex: LPFN_CONNECTEX,
    getacceptexsockaddrs: LPFN_GETACCEPTEXSOCKADDRS,
    wsarecvmsg: LPFN_WSARECVMSG,
    wsasendmsg: LPFN_WSASENDMSG,
    transmitfile: LPFN_TRANSMITFILE,
};

pub const SharedState = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    /// Backend-internal inflight count: ops accepted by submit() and not yet
    /// completed. Any loop of the group may dequeue any completion from the
    /// shared port, so the count is a group-shared atomic (any instance's
    /// decrInflight balances any instance's increment). Read by hasInflight()
    /// to skip the wait syscall when nothing can arrive.
    inflight_io: std.atomic.Value(u64) = .init(0),

    // Extension functions loaded once globally (family-independent)
    exts: ExtensionFunctions = undefined,

    pub fn acquire(self: *SharedState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.refcount == 0) {
            // First loop - create IOCP handle
            self.iocp = windows.CreateIoCompletionPort(
                windows.INVALID_HANDLE_VALUE,
                null,
                0,
                0, // Use default number of concurrent threads
            ) orelse return error.Unexpected;
            // If first-loop setup below fails, close the freshly created
            // handle so this SharedState stays reusable (refcount is still 0,
            // so the caller's errdefer release() does not run).
            errdefer {
                _ = windows.CloseHandle(self.iocp);
                self.iocp = windows.INVALID_HANDLE_VALUE;
            }

            // Reset shared accounting in case this SharedState is being
            // reused after a previous teardown that left stale counters.
            self.inflight_io.store(0, .release);

            // Load all extension functions using a temporary socket
            // Socket family/type doesn't matter - use AF_INET SOCK_STREAM
            const sock = try net.socket(.ipv4, .stream, .ip, .{ .nonblocking = false });
            defer net.close(sock);

            self.exts = ExtensionFunctions{
                .acceptex = try loadWinsockExtension(LPFN_ACCEPTEX, sock, WSAID_ACCEPTEX),
                .connectex = try loadWinsockExtension(LPFN_CONNECTEX, sock, WSAID_CONNECTEX),
                .getacceptexsockaddrs = try loadWinsockExtension(LPFN_GETACCEPTEXSOCKADDRS, sock, WSAID_GETACCEPTEXSOCKADDRS),
                .wsarecvmsg = try loadWinsockExtension(LPFN_WSARECVMSG, sock, WSAID_WSARECVMSG),
                .wsasendmsg = try loadWinsockExtension(LPFN_WSASENDMSG, sock, WSAID_WSASENDMSG),
                .transmitfile = try loadWinsockExtension(LPFN_TRANSMITFILE, sock, WSAID_TRANSMITFILE),
            };
        }
        self.refcount += 1;
    }

    pub fn release(self: *SharedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;

        if (self.refcount == 0) {
            // Last loop - close IOCP handle
            if (self.iocp != windows.INVALID_HANDLE_VALUE) {
                _ = windows.CloseHandle(self.iocp);
                self.iocp = windows.INVALID_HANDLE_VALUE;
            }
        }
    }
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const Self = @This();

const log = @import("../../common.zig").log;

allocator: std.mem.Allocator,
shared_state: *SharedState,
entries: []windows.OVERLAPPED_ENTRY,
queue_size: u16,
thread_handle: windows.HANDLE,

// Native real (wall-clock) timer. Windows has no boot clock distinct from the
// awake clock (both are QPC), so boot timers ride the awake poll timeout and
// only `.real` is armed natively. This one-shot waitable timer's completion
// routine sets `real_fired` via an APC delivered during the alertable poll;
// `real_armed` tracks the armed absolute deadline so syncWallTimer can skip
// redundant re-arms. Both are touched only on the loop thread (the APC also
// runs there), so no synchronization is needed.
real_timer: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
real_armed: ?u64 = null,
real_fired: bool = false,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    // Acquire reference to shared state (creates IOCP handle if first loop)
    try shared_state.acquire();
    errdefer shared_state.release();

    const entries = try allocator.alloc(windows.OVERLAPPED_ENTRY, queue_size);
    errdefer allocator.free(entries);

    // Duplicate current thread handle for wake support
    const pseudo_handle = windows.GetCurrentThread();
    var thread_handle: windows.HANDLE = undefined;
    const dup_result = windows.DuplicateHandle(
        windows.GetCurrentProcess(),
        pseudo_handle,
        windows.GetCurrentProcess(),
        &thread_handle,
        0,
        windows.FALSE,
        windows.DUPLICATE_SAME_ACCESS,
    );
    if (dup_result == .FALSE) {
        return error.Unexpected;
    }
    errdefer _ = windows.CloseHandle(thread_handle);

    self.* = .{
        .allocator = allocator,
        .shared_state = shared_state,
        .entries = entries,
        .queue_size = queue_size,
        .thread_handle = thread_handle,
    };

    // Create the per-loop real (wall-clock) waitable timer. Prefer the
    // high-resolution variant (Windows 10 1803+) and fall back to a coarse timer
    // when the flag is rejected on older systems.
    self.real_timer = windows.CreateWaitableTimerExW(null, null, windows.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, windows.TIMER_ALL_ACCESS) orelse
        windows.CreateWaitableTimerExW(null, null, 0, windows.TIMER_ALL_ACCESS) orelse
        return error.Unexpected;
}

pub fn deinit(self: *Self) void {
    // Cancel and close the real-clock waitable timer. Closing an armed timer
    // implicitly cancels it; CancelWaitableTimer first keeps it explicit.
    if (self.real_timer != windows.INVALID_HANDLE_VALUE) {
        _ = windows.CancelWaitableTimer(self.real_timer);
        _ = windows.CloseHandle(self.real_timer);
    }

    // Close thread handle
    _ = windows.CloseHandle(self.thread_handle);

    self.allocator.free(self.entries);
    // Release reference to shared state (closes IOCP handle if last loop)
    self.shared_state.release();
}

/// Post-process a file handle after it's been opened/created in the thread pool.
/// Associates the file handle with the IOCP port for async I/O operations.
pub fn postProcessFileHandle(self: *Self, handle: fs.fd_t) !void {
    const iocp_result = windows.CreateIoCompletionPort(
        handle,
        self.shared_state.iocp,
        0,
        0,
    ) orelse return error.Unexpected;

    if (iocp_result != self.shared_state.iocp) {
        return error.Unexpected;
    }
}

// Dummy APC procedure - we just need to interrupt the wait
fn wakeAPC(dwParam: windows.ULONG_PTR) callconv(.winapi) void {
    _ = dwParam;
    // No-op - just waking up the thread
}

// Completion routine for the real (wall-clock) waitable timer. Delivered as an
// APC on the loop thread during the alertable poll wait; the arg is a pointer to
// the `real_fired` flag, which poll consumes to report a timeout.
fn wallTimerAPC(arg: ?*anyopaque, low: windows.DWORD, high: windows.DWORD) callconv(.winapi) void {
    _ = low;
    _ = high;
    if (arg) |p| {
        const fired: *bool = @ptrCast(@alignCast(p));
        fired.* = true;
    }
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    // Queue an APC to wake the thread
    const result = windows.QueueUserAPC(wakeAPC, self.thread_handle, 0);
    if (result == 0) {
        log.err("QueueUserAPC failed: {}", .{windows.GetLastError()});
    } else {
        log.debug("QueueUserAPC succeeded", .{});
    }
}

/// Drop one inflight op. Called via LoopState.markCompletedFromBackend from
/// whichever loop dequeues the completion; the storage is group-shared, so
/// any instance's decrement balances any instance's increment.
pub fn decrInflight(self: *Self) void {
    _ = self.shared_state.inflight_io.fetchSub(1, .monotonic);
}

/// Whether poll() could produce completions. Used by the loop to skip the
/// wait syscall in no-wait ticks when nothing can arrive.
pub fn hasInflight(self: *const Self) bool {
    return self.shared_state.inflight_io.load(.monotonic) > 0;
}

pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    // Counted for every accepted op (sync completers decrement right back via
    // markCompletedFromBackend), mirroring the decrInflight in every completion
    // path so the balance needs no per-path reasoning.
    _ = self.shared_state.inflight_io.fetchAdd(1, .monotonic);

    switch (c.op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        // Synchronous operations - complete immediately
        .net_open => {
            const data = c.cast(NetOpen);
            if (net.socket(data.domain, data.socket_type, data.protocol, data.flags)) |handle| {
                // Associate socket with IOCP
                const iocp_result = windows.CreateIoCompletionPort(
                    @ptrCast(handle),
                    self.shared_state.iocp,
                    0, // CompletionKey (we use OVERLAPPED pointer to find completion)
                    0, // NumberOfConcurrentThreads (0 = use default)
                ) orelse {
                    // Failed to associate - close socket and fail
                    net.close(handle);
                    c.setError(error.Unexpected);
                    state.markCompletedFromBackend(c);
                    return;
                };

                // Verify we got the same IOCP handle back
                if (iocp_result == self.shared_state.iocp) {
                    c.setResult(.net_open, handle);
                } else {
                    // Failed to associate - close socket and fail
                    net.close(handle);
                    c.setError(error.Unexpected);
                }
            } else |err| {
                c.setError(err);
            }
            state.markCompletedFromBackend(c);
        },
        .net_bind => {
            common.handleNetBind(c);
            state.markCompletedFromBackend(c);
        },
        .net_listen => {
            common.handleNetListen(c);
            state.markCompletedFromBackend(c);
        },
        .net_close => {
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        .net_connect => {
            const data = c.cast(NetConnect);
            self.submitConnect(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_accept => {
            const data = c.cast(NetAccept);
            self.submitAccept(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_recv => {
            const data = c.cast(NetRecv);
            self.submitRecv(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_send => {
            const data = c.cast(NetSend);
            self.submitSend(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            self.submitRecvFrom(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_sendto => {
            const data = c.cast(NetSendTo);
            self.submitSendTo(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            self.submitRecvMsg(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            self.submitSendMsg(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .net_poll => {
            const data = c.cast(NetPoll);
            self.submitPoll(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .process_wait => {
            const data = c.cast(ProcessWait);
            self.submitProcessWait(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .file_open,
        .file_create,
        .file_close,
        .file_sync,
        .file_set_size,
        .file_set_permissions,
        .file_set_owner,
        .file_set_timestamps,
        .dir_create_dir,
        .dir_rename,
        .dir_rename_preserve,
        .dir_delete_file,
        .dir_delete_dir,
        .file_size,
        .file_stat,
        .dir_open,
        .dir_close,
        .dir_set_permissions,
        .dir_set_owner,
        .dir_set_file_permissions,
        .dir_set_file_owner,
        .dir_set_file_timestamps,
        .dir_sym_link,
        .dir_read_link,
        .dir_hard_link,
        .dir_access,
        .dir_read,
        .dir_real_path,
        .dir_real_path_file,
        .file_real_path,
        .file_hard_link,
        .device_io_control,
        => unreachable, // These are handled by thread pool (capabilities = false)

        .net_send_file => {
            const data = c.cast(NetSendFile);
            self.submitNetSendFile(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .pipe_poll => {
            // Windows IOCP doesn't support poll-style waiting on file handles
            c.setError(error.Unexpected);
            state.markCompletedFromBackend(c);
        },

        .pipe_create => {
            const data = c.cast(PipeCreate);
            self.submitPipeCreate(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        // Streaming (positionless) I/O — used for pipes and stdio. Only pollable
        // (non-seekable) fds reach here; seekable fds go to the thread pool.
        .file_read_streaming => {
            const data = c.cast(FileReadStreaming);
            self.submitFileReadStreaming(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .file_write_streaming => {
            const data = c.cast(FileWriteStreaming);
            self.submitFileWriteStreaming(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .pipe_close => {
            const data = c.cast(PipeClose);
            self.submitPipeClose(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .file_read => {
            const data = c.cast(FileRead);
            self.submitFileRead(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },

        .file_write => {
            const data = c.cast(FileWrite);
            self.submitFileWrite(state, data) catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
            };
        },
        .mach_port => unreachable,
    }
}

fn recvFlagsToMsg(flags: net.RecvFlags) windows.DWORD {
    var msg_flags: windows.DWORD = 0;
    if (flags.peek) msg_flags |= windows.MSG.PEEK;
    if (flags.waitall) msg_flags |= windows.MSG.WAITALL;
    if (flags.oob) msg_flags |= windows.MSG.OOB;
    // flags.trunc has no Windows equivalent — silently dropped.
    return msg_flags;
}

fn sendFlagsToMsg(flags: net.SendFlags) windows.DWORD {
    // Windows doesn't have MSG_NOSIGNAL (no signals on Windows)
    _ = flags;
    return 0;
}

fn submitAccept(self: *Self, state: *LoopState, data: *NetAccept) !void {
    // Get socket address to determine address family
    var addr_buf align(@alignOf(windows.sockaddr.in6)) = @as([128]u8, @splat(0));
    var addr_len: i32 = addr_buf.len;
    if (windows.getsockname(
        data.handle,
        @ptrCast(&addr_buf),
        &addr_len,
    ) != 0) {
        return error.Unexpected;
    }

    const family: u16 = @as(*const windows.sockaddr, @ptrCast(&addr_buf)).family;

    // Store family for later use in processCompletion
    data.internal.family = family;

    // Load AcceptEx extension function for this address family
    const exts = self.shared_state.exts;

    // Create new socket for the accepted connection (same family as listening socket)
    const accept_socket = try net.socket(@enumFromInt(family), .stream, .ip, data.flags);
    errdefer net.close(accept_socket);

    // Publish the accepted socket into the op BEFORE issuing AcceptEx (#530). The
    // IOCP port is shared across all executors, so AcceptEx can complete and be
    // dequeued by another thread the instant it is posted. If result_private were
    // still unset at that point, processCompletion would read an uninitialized
    // handle and close it — a double-close use-after-free. The AcceptEx call below
    // is a syscall (a full barrier), so writing the handle first guarantees the
    // completion handler — on any thread — observes a valid value.
    data.result_private_do_not_touch = accept_socket;

    // Associate the accept socket with IOCP
    const iocp_result = windows.CreateIoCompletionPort(
        @ptrCast(accept_socket),
        self.shared_state.iocp,
        0,
        0,
    ) orelse return error.Unexpected;

    if (iocp_result != self.shared_state.iocp) {
        return error.Unexpected;
    }

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Call AcceptEx
    const addr_size: windows.DWORD = NetAcceptData.addr_slot_size;

    const result = exts.acceptex(
        data.handle, // listening socket
        accept_socket, // accept socket
        &data.internal.addr_buffer,
        0, // dwReceiveDataLength - we don't want any data, just connection
        addr_size, // local address length
        addr_size, // remote address length
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
    );

    // (result_private_do_not_touch was published before AcceptEx above — see #530.)

    // When AcceptEx succeeds (result == TRUE) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == windows.FALSE) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            net.close(accept_socket);
            log.err("AcceptEx failed: {}", .{err});
            data.c.setError(net.errnoToAcceptError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitPoll(self: *Self, state: *LoopState, data: *NetPoll) !void {
    _ = self;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Use zero-length WSARecv/WSASend to detect readiness
    // Zero-length operations complete immediately if socket is ready
    // Use pointer to a local variable instead of undefined to avoid passing undefined value to kernel
    var dummy: u8 = 0;
    var zero_buf = windows.WSABUF{ .len = 0, .buf = @ptrCast(&dummy) };

    data.c.internal.flags = 0;

    // Choose WSARecv or WSASend based on which event is requested
    const result = switch (data.event) {
        .recv => windows.WSARecv(
            data.handle,
            @ptrCast(&zero_buf),
            1,
            &data.c.internal.bytes,
            &data.c.internal.flags,
            &data.c.internal.overlapped,
            null,
        ),
        .send => windows.WSASend(
            data.handle,
            @ptrCast(&zero_buf),
            1,
            &data.c.internal.bytes,
            data.c.internal.flags,
            &data.c.internal.overlapped,
            null,
        ),
    };

    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WSARecv/WSASend (poll) failed: {}", .{err});
            data.c.setError(net.errnoToRecvError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitRecv(self: *Self, state: *LoopState, data: *NetRecv) !void {
    _ = self;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // iovecs are already WSABUF on Windows
    const wsabufs = data.buffers.iovecs;

    data.c.internal.flags = recvFlagsToMsg(data.flags);

    const result = windows.WSARecv(
        data.handle,
        wsabufs.ptr,
        @intCast(wsabufs.len),
        &data.c.internal.bytes,
        &data.c.internal.flags,
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    // When WSARecv succeeds (result == 0) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port. We should NOT
    // complete it immediately here.
    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WSARecv failed: {}", .{err});
            data.c.setError(net.errnoToRecvError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitSend(self: *Self, state: *LoopState, data: *NetSend) !void {
    _ = self;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // iovecs are already WSABUF on Windows (need to cast away const)
    const wsabufs = data.buffer.iovecs;

    const flags: windows.DWORD = sendFlagsToMsg(data.flags);

    const result = windows.WSASend(
        data.handle,
        @constCast(wsabufs.ptr),
        @intCast(wsabufs.len),
        &data.c.internal.bytes,
        flags,
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    // When WSASend succeeds (result == 0) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WSASend failed: {}", .{err});
            data.c.setError(net.errnoToSendError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitRecvFrom(self: *Self, state: *LoopState, data: *NetRecvFrom) !void {
    _ = self;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // iovecs are already WSABUF on Windows
    const wsabufs = data.buffer.iovecs;

    data.c.internal.flags = recvFlagsToMsg(data.flags);

    const result = windows.WSARecvFrom(
        data.handle,
        wsabufs.ptr,
        @intCast(wsabufs.len),
        &data.c.internal.bytes,
        &data.c.internal.flags,
        if (data.addr) |addr| @ptrCast(addr) else null,
        if (data.addr_len) |len| len else null,
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    // When WSARecvFrom succeeds (result == 0) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WSARecvFrom failed: {}", .{err});
            data.c.setError(net.errnoToRecvError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitSendTo(self: *Self, state: *LoopState, data: *NetSendTo) !void {
    _ = self;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // iovecs are already WSABUF on Windows (need to cast away const)
    const wsabufs = data.buffer.iovecs;

    const flags: windows.DWORD = sendFlagsToMsg(data.flags);

    const result = windows.WSASendTo(
        data.handle,
        @constCast(wsabufs.ptr),
        @intCast(wsabufs.len),
        &data.c.internal.bytes,
        flags,
        @ptrCast(data.addr),
        @intCast(data.addr_len),
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    // When WSASendTo succeeds (result == 0) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WSASendTo failed: {}", .{err});
            data.c.setError(net.errnoToSendError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitRecvMsg(self: *Self, state: *LoopState, data: *NetRecvMsg) !void {
    // Load WSARecvMsg extension function
    const exts = self.shared_state.exts;

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Set up control buffer if provided
    if (data.control) |ctl| {
        data.internal.control_buf = .{
            .len = @intCast(ctl.len),
            .buf = ctl.ptr,
        };
    } else {
        data.internal.control_buf = .{
            .len = 0,
            .buf = null,
        };
    }

    // Initialize WSAMSG
    data.internal.msg = .{
        .name = if (data.addr) |addr| @ptrCast(addr) else null,
        .namelen = if (data.addr_len) |len| @intCast(len.*) else 0,
        .lpBuffers = data.data.iovecs.ptr,
        .dwBufferCount = @intCast(data.data.iovecs.len),
        .Control = data.internal.control_buf,
        .dwFlags = recvFlagsToMsg(data.flags),
    };

    const result = exts.wsarecvmsg(
        data.handle,
        &data.internal.msg,
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            log.err("WSARecvMsg failed: {}", .{err});
            data.c.setError(net.errnoToRecvError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitSendMsg(self: *Self, state: *LoopState, data: *NetSendMsg) !void {
    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Set up control buffer if provided
    if (data.control) |ctl| {
        data.internal.control_buf = .{
            .len = @intCast(ctl.len),
            .buf = @constCast(ctl.ptr),
        };
    } else {
        data.internal.control_buf = .{
            .len = 0,
            .buf = null,
        };
    }

    // Initialize WSAMSG_const
    data.internal.msg = .{
        .name = if (data.addr) |addr| @ptrCast(addr) else null,
        .namelen = if (data.addr != null) @intCast(data.addr_len) else 0,
        .lpBuffers = @constCast(data.data.iovecs.ptr),
        .dwBufferCount = @intCast(data.data.iovecs.len),
        .Control = data.internal.control_buf,
        .dwFlags = sendFlagsToMsg(data.flags),
    };

    // Load WSASendMsg extension function
    const exts = self.shared_state.exts;

    const result = exts.wsasendmsg(
        data.handle,
        &data.internal.msg,
        sendFlagsToMsg(data.flags),
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
        null, // No completion routine
    );

    if (result == windows.SOCKET_ERROR) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            log.err("WSASendMsg failed: {}", .{err});
            data.c.setError(net.errnoToSendError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitNetSendFile(self: *Self, state: *LoopState, data: *NetSendFile) !void {
    // Determine how much we can actually send. TransmitFile transmits exactly
    // the requested byte count (it has no short-write semantics), and fails if
    // the requested range runs past EOF, so we must clamp to the file size.
    // GetFileSizeEx is a fast metadata query (no file-pointer I/O), so running
    // it synchronously on the loop thread here is acceptable.
    const file_size = fs.fileSize(data.file) catch |err| switch (err) {
        // PermissionDenied is not part of NetSendFile's error set; fold it into
        // AccessDenied. The remaining FileSizeError values (AccessDenied,
        // Canceled, Unexpected) are all valid send-file errors.
        error.PermissionDenied => return error.AccessDenied,
        else => |e| return e,
    };

    const avail: u64 = if (data.offset >= file_size) 0 else file_size - data.offset;
    data.internal.total = 0;
    data.internal.left = @intCast(@min(@as(u64, data.remaining), avail));

    // Offset at/past EOF or a zero-byte limit: nothing to send. Report 0, which
    // the std sendFile path turns into EndOfStream.
    if (data.internal.left == 0) {
        data.c.setResult(.net_send_file, 0);
        state.markCompletedFromBackend(&data.c);
        return;
    }

    if (!try self.armNetSendFile(data)) {
        data.c.setResult(.net_send_file, data.internal.total);
        state.markCompletedFromBackend(&data.c);
    }
    // Otherwise the chunk is in flight and completes via IOCP.
}

/// Issue the next TransmitFile chunk for an in-progress send-file operation.
/// Returns true if a chunk was submitted (completion will arrive via IOCP),
/// false if there is nothing left to send.
fn armNetSendFile(self: *Self, data: *NetSendFile) !bool {
    if (data.internal.left == 0) return false;

    const chunk: windows.DWORD = @intCast(@min(data.internal.left, transmit_file_max));
    const file_offset = data.offset + data.internal.total;

    // Reset the OVERLAPPED and point it at the current file offset.
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(file_offset);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate(file_offset >> 32);

    const result = self.shared_state.exts.transmitfile(
        data.handle,
        data.file,
        chunk,
        0, // nNumberOfBytesPerSend - 0 selects the default send size
        &data.c.internal.overlapped,
        null, // no head/tail buffers
        0, // no flags
    );

    // Like the other overlapped socket ops: success (TRUE) or WSA_IO_PENDING
    // both deliver an IOCP completion; any other error is reported now.
    if (result == windows.FALSE) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            log.err("TransmitFile failed: {}", .{err});
            return net.errnoToSendError(err);
        }
    }
    return true;
}

fn submitConnect(self: *Self, state: *LoopState, data: *NetConnect) !void {
    // Get address family from the target address
    const family: u16 = @as(*const windows.sockaddr, @ptrCast(@alignCast(data.addr))).family;

    // Load ConnectEx extension function for this address family
    const exts = self.shared_state.exts;

    // ConnectEx requires the socket to be bound first (even to wildcard address)
    // Create a wildcard bind address
    var bind_addr_buf align(@alignOf(windows.sockaddr.in6)) = @as([128]u8, @splat(0));
    var bind_addr_len: net.socklen_t = 0;

    if (family == windows.AF.INET) {
        const addr: *windows.sockaddr.in = @ptrCast(&bind_addr_buf);
        addr.family = windows.AF.INET;
        addr.port = 0; // Let OS choose port
        addr.addr = 0; // INADDR_ANY
        bind_addr_len = @sizeOf(windows.sockaddr.in);
    } else if (family == windows.AF.INET6) {
        const addr: *windows.sockaddr.in6 = @ptrCast(&bind_addr_buf);
        addr.family = windows.AF.INET6;
        addr.port = 0;
        addr.addr = @splat(0); // IN6ADDR_ANY
        bind_addr_len = @sizeOf(windows.sockaddr.in6);
    } else if (family == windows.AF.UNIX) {
        const addr: *windows.sockaddr.un = @ptrCast(&bind_addr_buf);
        addr.family = windows.AF.UNIX;
        addr.path = @splat(0); // Empty path for wildcard bind
        bind_addr_len = @sizeOf(windows.sockaddr.un);
    } else {
        return error.Unexpected;
    }

    // Bind to wildcard address
    _ = net.bind(data.handle, @ptrCast(&bind_addr_buf), bind_addr_len) catch |err| {
        // If already bound, that's OK (user may have called bind explicitly)
        if (err != error.AddressInUse) return err;
    };

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Call ConnectEx
    const result = exts.connectex(
        data.handle,
        @ptrCast(data.addr), // Cast from os.net.sockaddr to windows.sockaddr
        @intCast(data.addr_len),
        null, // No send data
        0,
        null,
        &data.c.internal.overlapped,
    );

    // When ConnectEx succeeds (result == TRUE) OR returns WSA_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == windows.FALSE) {
        const err = windows.WSAGetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("ConnectEx failed: {}", .{err});
            data.c.setError(net.errnoToConnectError(err));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitFileRead(self: *Self, state: *LoopState, data: *FileRead) !void {
    _ = self;

    // Initialize OVERLAPPED with file offset
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(data.offset);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate(data.offset >> 32);

    // ReadFile only supports a single buffer, so we read into the first iovec
    // TODO: Handle multiple iovecs with multiple ReadFile calls
    const buffer = data.buffer.iovecs[0];

    const result = windows.ReadFile(
        data.handle,
        buffer.buf,
        @intCast(buffer.len),
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
    );

    // When ReadFile succeeds (result == TRUE) OR returns ERROR_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == .FALSE) {
        const err = windows.GetLastError();
        if (err == .HANDLE_EOF) {
            // Synchronous EOF - read 0 bytes. No completion packet is queued
            // in this case, so we must complete it here.
            data.c.setResult(.file_read, 0);
            state.markCompletedFromBackend(&data.c);
            return;
        } else if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("ReadFile failed: {}", .{err});
            data.c.setError(fs.errnoToFileReadError(@enumFromInt(@intFromEnum(err))));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitFileWrite(self: *Self, state: *LoopState, data: *FileWrite) !void {
    _ = self;

    // Initialize OVERLAPPED with file offset
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Offset = @truncate(data.offset);
    data.c.internal.overlapped.DUMMYUNIONNAME.DUMMYSTRUCTNAME.OffsetHigh = @truncate(data.offset >> 32);

    // WriteFile only supports a single buffer, so we write from the first iovec
    // TODO: Handle multiple iovecs with multiple WriteFile calls
    const buffer = data.buffer.iovecs[0];

    const result = windows.WriteFile(
        data.handle,
        buffer.buf,
        @intCast(buffer.len),
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
    );

    // When WriteFile succeeds (result == TRUE) OR returns ERROR_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == .FALSE) {
        const err = windows.GetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WriteFile failed: {}", .{err});
            data.c.setError(fs.errnoToFileWriteError(@enumFromInt(@intFromEnum(err))));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitPipeCreate(self: *Self, state: *LoopState, data: *PipeCreate) !void {
    // Create pipe with overlapped I/O support
    const fds = windows.pipe() catch |err| {
        data.c.setError(err);
        state.markCompletedFromBackend(&data.c);
        return;
    };

    // Associate both handles with IOCP
    const read_result = windows.CreateIoCompletionPort(
        fds[0],
        self.shared_state.iocp,
        0,
        0,
    );
    if (read_result == null) {
        _ = windows.CloseHandle(fds[0]);
        _ = windows.CloseHandle(fds[1]);
        data.c.setError(error.Unexpected);
        state.markCompletedFromBackend(&data.c);
        return;
    }

    const write_result = windows.CreateIoCompletionPort(
        fds[1],
        self.shared_state.iocp,
        0,
        0,
    );
    if (write_result == null) {
        _ = windows.CloseHandle(fds[0]);
        _ = windows.CloseHandle(fds[1]);
        data.c.setError(error.Unexpected);
        state.markCompletedFromBackend(&data.c);
        return;
    }

    // Store result and complete immediately
    data.c.setResult(.pipe_create, fds);
    state.markCompletedFromBackend(&data.c);
}

fn submitFileReadStreaming(self: *Self, state: *LoopState, data: *FileReadStreaming) !void {
    _ = self;

    if (data.buffer.iovecs.len == 0) {
        data.c.setResult(.file_read_streaming, 0);
        state.markCompletedFromBackend(&data.c);
        return;
    }

    // Initialize OVERLAPPED with zero offset (streaming has no offset)
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // ReadFile only supports a single buffer, so we read into the first iovec
    // TODO: Handle multiple iovecs with multiple ReadFile calls
    const buffer = data.buffer.iovecs[0];

    const result = windows.ReadFile(
        data.handle,
        buffer.buf,
        @intCast(buffer.len),
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
    );

    // When ReadFile succeeds (result == TRUE) OR returns ERROR_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == .FALSE) {
        const err = windows.GetLastError();
        if (err == .HANDLE_EOF or err == .BROKEN_PIPE) {
            // Write end closed (BROKEN_PIPE) or EOF reached (HANDLE_EOF) -
            // this is EOF, not an error. No completion packet is queued in this
            // case, so we must complete it here.
            data.c.setResult(.file_read_streaming, 0);
            state.markCompletedFromBackend(&data.c);
            return;
        } else if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("ReadFile (pipe) failed: {}", .{err});
            data.c.setError(fs.errnoToFileReadError(@enumFromInt(@intFromEnum(err))));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitFileWriteStreaming(self: *Self, state: *LoopState, data: *FileWriteStreaming) !void {
    _ = self;

    if (data.buffer.iovecs.len == 0) {
        data.c.setResult(.file_write_streaming, 0);
        state.markCompletedFromBackend(&data.c);
        return;
    }

    // Initialize OVERLAPPED with zero offset (streaming has no offset)
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // WriteFile only supports a single buffer, so we write from the first iovec
    // TODO: Handle multiple iovecs with multiple WriteFile calls
    const buffer = data.buffer.iovecs[0];

    const result = windows.WriteFile(
        data.handle,
        buffer.buf,
        @intCast(buffer.len),
        &data.c.internal.bytes,
        &data.c.internal.overlapped,
    );

    // When WriteFile succeeds (result == TRUE) OR returns ERROR_IO_PENDING,
    // the completion will be posted to the IOCP port.
    if (result == .FALSE) {
        const err = windows.GetLastError();
        if (err != .IO_PENDING) {
            // Real error - complete immediately with error
            log.err("WriteFile (pipe) failed: {}", .{err});
            data.c.setError(fs.errnoToFileWriteError(@enumFromInt(@intFromEnum(err))));
            state.markCompletedFromBackend(&data.c);
            return;
        }
    }
    // Operation will complete via IOCP (either immediate or async)
}

fn submitPipeClose(self: *Self, state: *LoopState, data: *PipeClose) !void {
    _ = self;

    const result = windows.CloseHandle(data.handle);
    if (result == windows.FALSE) {
        const err = windows.GetLastError();
        log.err("CloseHandle (pipe) failed: {}", .{err});
        data.c.setError(fs.errnoToFileCloseError(@enumFromInt(@intFromEnum(err))));
    } else {
        data.c.setResult(.pipe_close, {});
    }

    // Complete immediately (synchronous operation)
    state.markCompletedFromBackend(&data.c);
}

/// Thread-pool callback invoked by Windows when the process exits.
/// Posts an IOCP completion so the event loop can process the result.
fn processWaitCallback(lpParameter: windows.PVOID, TimerOrWaitFired: windows.BOOLEAN) callconv(.winapi) void {
    _ = TimerOrWaitFired;
    const pw_internal: *ProcessWaitData = @ptrCast(@alignCast(lpParameter));
    const pw: *ProcessWait = @fieldParentPtr("internal", pw_internal);
    // Use CAS to ensure only one path (callback or cancel) posts to IOCP
    if (pw_internal.posted.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        _ = windows.PostQueuedCompletionStatus(pw_internal.iocp, 0, 0, &pw.c.internal.overlapped);
    }
}

fn submitProcessWait(self: *Self, state: *LoopState, data: *ProcessWait) !void {
    _ = state;

    // Zero the overlapped structure so IOCP can use it
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Reset the posted flag for this submission
    data.internal.posted.store(false, .release);

    // Store the IOCP handle so the callback can post the completion
    data.internal.iocp = self.shared_state.iocp;

    // Register a wait: when the process handle is signaled (process exits),
    // the callback fires once and posts an IOCP completion packet.
    const ok = windows.RegisterWaitForSingleObject(
        &data.internal.wait_handle,
        data.handle,
        processWaitCallback,
        &data.internal,
        windows.INFINITE,
        windows.WT_EXECUTEONLYONCE,
    );
    if (ok == windows.FALSE) {
        return error.Unexpected;
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    _ = self;
    _ = state;

    switch (target.loadState().phase) {
        .new => {
            // UNREACHABLE: cancelLocal only forwards running completions.
            unreachable;
        },
        .running => {
            // Target is executing. Use CancelIoEx to cancel the async operation.
            // After cancellation, the operation will complete with ERROR_OPERATION_ABORTED
            // and we'll receive the completion via IOCP.

            const handle = switch (target.op) {
                .net_connect,
                .net_accept,
                .net_recv,
                .net_send,
                .net_recvfrom,
                .net_sendto,
                .net_recvmsg,
                .net_sendmsg,
                .net_poll,
                .net_send_file,
                => blk: {
                    // Get socket handle from the completion
                    const h = switch (target.op) {
                        .net_connect => target.cast(NetConnect).handle,
                        .net_accept => target.cast(NetAccept).handle,
                        .net_recv => target.cast(NetRecv).handle,
                        .net_send => target.cast(NetSend).handle,
                        .net_recvfrom => target.cast(NetRecvFrom).handle,
                        .net_sendto => target.cast(NetSendTo).handle,
                        .net_recvmsg => target.cast(NetRecvMsg).handle,
                        .net_sendmsg => target.cast(NetSendMsg).handle,
                        .net_poll => target.cast(NetPoll).handle,
                        .net_send_file => target.cast(NetSendFile).handle,
                        else => unreachable,
                    };
                    break :blk @as(windows.HANDLE, @ptrCast(h));
                },
                .file_read,
                .file_write,
                .file_sync,
                .file_read_streaming,
                .file_write_streaming,
                => blk: {
                    // Get file handle from the completion
                    const h = switch (target.op) {
                        .file_read => target.cast(FileRead).handle,
                        .file_write => target.cast(FileWrite).handle,
                        .file_sync => target.cast(FileSync).handle,
                        .file_read_streaming => target.cast(FileReadStreaming).handle,
                        .file_write_streaming => target.cast(FileWriteStreaming).handle,
                        else => unreachable,
                    };
                    break :blk h;
                },
                .process_wait => {
                    const data = target.cast(ProcessWait);
                    if (data.internal.wait_handle != windows.INVALID_HANDLE_VALUE) {
                        // Unregister and wait for any in-flight callback to finish.
                        // INVALID_HANDLE_VALUE means block until all running callbacks complete,
                        // preventing a race where the callback posts after we do.
                        _ = windows.UnregisterWaitEx(data.internal.wait_handle, windows.INVALID_HANDLE_VALUE);
                        data.internal.wait_handle = windows.INVALID_HANDLE_VALUE;
                        // If the callback didn't already post, post the completion ourselves
                        if (data.internal.posted.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                            _ = windows.PostQueuedCompletionStatus(data.internal.iocp, 0, 0, &target.internal.overlapped);
                        }
                    }
                    return;
                },
                else => {
                    // Operations that can't be canceled or are synchronous
                    // Just mark them as completed (they'll finish naturally)
                    return;
                },
            };

            // Cancel the I/O operation
            const result = windows.CancelIoEx(handle, &target.internal.overlapped);
            if (result == .FALSE) {
                const err = windows.GetLastError();
                // ERROR_NOT_FOUND means the operation already completed - that's fine
                if (err != .NOT_FOUND) {
                    log.warn("CancelIoEx failed: {}", .{err});
                }
            }
            // The completion will be posted to IOCP with ERROR_OPERATION_ABORTED
            // When we process it, we'll mark the target as completed
        },
        .completed, .dead => {
            // Already completed or dead - nothing to cancel
            return;
        },
    }
}

fn processCompletion(self: *Self, state: *LoopState, entry: *const windows.OVERLAPPED_ENTRY) void {
    // Get the OVERLAPPED pointer from the entry
    // Note: lpOverlapped can be null in error cases, despite Zig's type definition
    if (@intFromPtr(entry.lpOverlapped) == 0) {
        // NULL overlapped can occur when the IOCP port itself is closed
        // or in some error conditions - just ignore it
        log.warn("Received IOCP completion with NULL overlapped", .{});
        return;
    }
    const overlapped = entry.lpOverlapped.?;

    // Use @fieldParentPtr to get from OVERLAPPED to CompletionData
    const completion_data: *CompletionData = @fieldParentPtr("overlapped", overlapped);

    // Use @fieldParentPtr again to get from CompletionData to Completion
    const c: *Completion = @fieldParentPtr("internal", completion_data);

    // Process based on operation type
    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);

            // Use WSAGetOverlappedResult to get the proper error status
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToConnectError(err));
            } else {
                // Success - need to call setsockopt to update socket context
                const SO_UPDATE_CONNECT_CONTEXT = 0x7010;
                const setsockopt_result = windows.setsockopt(
                    data.handle,
                    windows.SOL.SOCKET,
                    SO_UPDATE_CONNECT_CONTEXT,
                    null,
                    0,
                );

                if (setsockopt_result == windows.SOCKET_ERROR) {
                    // setsockopt failed - close the socket and report error
                    const err = windows.WSAGetLastError();
                    net.close(data.handle);
                    c.setError(net.errnoToConnectError(err));
                } else {
                    c.setResult(.net_connect, {});
                }
            }

            state.markCompletedFromBackend(c);
        },

        .net_accept => {
            const data = c.cast(NetAccept);

            // Use WSAGetOverlappedResult to get the proper error status
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                // Error occurred - close the accept socket
                net.close(data.result_private_do_not_touch);
                c.setError(net.errnoToAcceptError(err));
            } else {
                // Success - need to call setsockopt to update socket context
                const SO_UPDATE_ACCEPT_CONTEXT = 0x700B;
                const setsockopt_result = windows.setsockopt(
                    data.result_private_do_not_touch,
                    windows.SOL.SOCKET,
                    SO_UPDATE_ACCEPT_CONTEXT,
                    @ptrCast(&data.handle),
                    @sizeOf(@TypeOf(data.handle)),
                );

                if (setsockopt_result == windows.SOCKET_ERROR) {
                    // setsockopt failed - close the socket and report error
                    const err = windows.WSAGetLastError();
                    net.close(data.result_private_do_not_touch);
                    c.setError(net.errnoToAcceptError(err));
                } else {
                    // Parse the address buffer to get the peer address
                    if (data.addr) |user_addr| {
                        // Load GetAcceptExSockaddrs extension function using the stored family
                        const exts = self.shared_state.exts;

                        const addr_size: u32 = NetAcceptData.addr_slot_size;
                        var local_addr: *windows.sockaddr = undefined;
                        var local_addr_len: i32 = undefined;
                        var remote_addr: *windows.sockaddr = undefined;
                        var remote_addr_len: i32 = undefined;

                        exts.getacceptexsockaddrs(
                            &data.internal.addr_buffer,
                            0, // dwReceiveDataLength
                            addr_size,
                            addr_size,
                            &local_addr,
                            &local_addr_len,
                            &remote_addr,
                            &remote_addr_len,
                        );

                        // Copy remote address to user buffer, handling truncation
                        if (data.addr_len) |user_len_ptr| {
                            const remote_len: u32 = @intCast(remote_addr_len);
                            const user_len: u32 = @intCast(user_len_ptr.*);
                            const copy_len: usize = @min(remote_len, user_len);
                            @memcpy(
                                @as([*]u8, @ptrCast(user_addr))[0..copy_len],
                                @as([*]const u8, @ptrCast(remote_addr))[0..copy_len],
                            );
                            user_len_ptr.* = @intCast(remote_len);
                        }
                    }

                    // Note: Socket was already associated with IOCP in submitAccept()
                    // No need to associate again here

                    c.setResult(.net_accept, data.result_private_do_not_touch);
                }
            }

            state.markCompletedFromBackend(c);
        },

        .net_recv => {
            const data = c.cast(NetRecv);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToRecvError(err));
            } else {
                c.setResult(.net_recv, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .net_send => {
            const data = c.cast(NetSend);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToSendError(err));
            } else {
                c.setResult(.net_send, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .net_send_file => {
            const data = c.cast(NetSendFile);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToSendError(err));
                state.markCompletedFromBackend(c);
            } else {
                data.internal.total += bytes_transferred;
                data.internal.left -= bytes_transferred;
                if (data.internal.left == 0) {
                    // Whole requested range sent.
                    c.setResult(.net_send_file, data.internal.total);
                    state.markCompletedFromBackend(c);
                } else if (c.loadState().cancel_requested) {
                    // Cancel was requested between this chunk completing and the
                    // re-arm. CancelIoEx already returned NOT_FOUND (the chunk
                    // had already completed), so we must check the flag here to
                    // avoid issuing a new TransmitFile that no cancel will reach.
                    c.setError(error.Canceled);
                    state.markCompletedFromBackend(c);
                } else if (self.armNetSendFile(data)) |armed| {
                    // File larger than the per-call cap: next chunk is in flight,
                    // so leave the op running (no completion/decrement yet). If
                    // there was unexpectedly nothing left, finish with the total.
                    if (!armed) {
                        c.setResult(.net_send_file, data.internal.total);
                        state.markCompletedFromBackend(c);
                    }
                } else |err| {
                    c.setError(err);
                    state.markCompletedFromBackend(c);
                }
            }
        },

        .net_recvfrom => {
            const data = c.cast(NetRecvFrom);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToRecvError(err));
            } else {
                // addr_len was updated by WSARecvFrom during the async operation
                c.setResult(.net_recvfrom, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .net_sendto => {
            const data = c.cast(NetSendTo);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToSendError(err));
            } else {
                c.setResult(.net_sendto, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .net_recvmsg => {
            const data = c.cast(NetRecvMsg);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToRecvError(err));
            } else {
                // Update addr_len if address was provided
                if (data.addr_len) |len| {
                    len.* = @intCast(data.internal.msg.namelen);
                }
                c.setResult(.net_recvmsg, .{
                    .len = @intCast(bytes_transferred),
                    .flags = data.internal.msg.dwFlags,
                    .controllen = @intCast(data.internal.msg.Control.len),
                });
            }

            state.markCompletedFromBackend(c);
        },

        .net_sendmsg => {
            const data = c.cast(NetSendMsg);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToSendError(err));
            } else {
                c.setResult(.net_sendmsg, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .net_poll => {
            const data = c.cast(NetPoll);
            var bytes_transferred: windows.DWORD = 0;
            var flags: windows.DWORD = 0;

            const result = windows.WSAGetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
                &flags,
            );

            if (result == windows.FALSE) {
                const err = windows.WSAGetLastError();
                c.setError(net.errnoToRecvError(err));
            } else {
                // Zero-length operation completed - socket is ready
                c.setResult(.net_poll, {});
            }

            state.markCompletedFromBackend(c);
        },

        .file_read => {
            const data = c.cast(FileRead);
            var bytes_transferred: windows.DWORD = 0;

            const result = windows.GetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
            );

            if (result == .FALSE) {
                const err = windows.GetLastError();
                // HANDLE_EOF is not an error - it means we successfully read 0 bytes (EOF)
                if (err == .HANDLE_EOF) {
                    c.setResult(.file_read, 0);
                } else {
                    c.setError(fs.errnoToFileReadError(err));
                }
            } else {
                c.setResult(.file_read, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .file_write => {
            const data = c.cast(FileWrite);
            var bytes_transferred: windows.DWORD = 0;

            const result = windows.GetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
            );

            if (result == .FALSE) {
                const err = windows.GetLastError();
                c.setError(fs.errnoToFileWriteError(@enumFromInt(@intFromEnum(err))));
            } else {
                c.setResult(.file_write, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .file_read_streaming => {
            const data = c.cast(FileReadStreaming);
            var bytes_transferred: windows.DWORD = 0;

            const result = windows.GetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
            );

            if (result == .FALSE) {
                const err = windows.GetLastError();
                // HANDLE_EOF and BROKEN_PIPE are not errors for streaming reads - they mean EOF (0 bytes)
                if (err == .HANDLE_EOF or err == .BROKEN_PIPE) {
                    c.setResult(.file_read_streaming, 0);
                } else {
                    c.setError(fs.errnoToFileReadError(err));
                }
            } else {
                c.setResult(.file_read_streaming, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .file_write_streaming => {
            const data = c.cast(FileWriteStreaming);
            var bytes_transferred: windows.DWORD = 0;

            const result = windows.GetOverlappedResult(
                data.handle,
                &data.c.internal.overlapped,
                &bytes_transferred,
                windows.FALSE,
            );

            if (result == .FALSE) {
                const err = windows.GetLastError();
                c.setError(fs.errnoToFileWriteError(@enumFromInt(@intFromEnum(err))));
            } else {
                c.setResult(.file_write_streaming, @intCast(bytes_transferred));
            }

            state.markCompletedFromBackend(c);
        },

        .process_wait => {
            const data = c.cast(ProcessWait);

            // Unregister the wait handle to clean up the thread-pool registration.
            // If cancel() already unregistered it, this is a no-op.
            if (data.internal.wait_handle != windows.INVALID_HANDLE_VALUE) {
                _ = windows.UnregisterWaitEx(data.internal.wait_handle, null);
                data.internal.wait_handle = windows.INVALID_HANDLE_VALUE;
            }

            if (c.loadState().cancel_requested) {
                c.setError(error.Canceled);
            } else {
                var exit_code: windows.DWORD = 0;
                if (windows.GetExitCodeProcess(data.handle, &exit_code) == windows.FALSE) {
                    c.setError(error.Unexpected);
                } else {
                    c.setResult(.process_wait, .{
                        .code = @truncate(exit_code),
                        .signal = null, // Windows doesn't have signals
                    });
                }
            }

            state.markCompletedFromBackend(c);
        },

        else => {
            log.err("Unexpected completion for operation: {}", .{c.op});
            c.setError(error.Unexpected);
            state.markCompletedFromBackend(c);
        },
    }
}

/// 100-ns ticks between the Windows epoch (1601-01-01) and the Unix epoch
/// (1970-01-01); used to map a `.real` deadline to an absolute FILETIME.
const filetime_epoch_diff_ticks: u64 = 11644473600 * (time.ns_per_s / 100);

/// Arm/update/disarm the real (wall-clock) waitable timer to an absolute
/// deadline (Unix ns; null = disarm). Returns false only if it couldn't arm a
/// pending deadline, so the loop folds real into the capped poll timeout.
/// SetWaitableTimer on an already-armed timer resets it, so a re-arm needs no
/// explicit cancel. Boot is never passed here — on Windows it shares the awake
/// heap (see `boot_distinct_from_awake`).
pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
    std.debug.assert(clock == .real);
    if (self.real_armed == deadline) return true; // unchanged (incl. both null)

    if (deadline) |d| {
        // A positive LARGE_INTEGER due time (100-ns units) is an absolute
        // FILETIME: map the Unix-ns deadline so the kernel re-evaluates it
        // across system-clock steps, matching the .real epoch.
        const due: windows.LARGE_INTEGER = @intCast(d / 100 + filetime_epoch_diff_ticks);
        if (windows.SetWaitableTimer(self.real_timer, &due, 0, wallTimerAPC, &self.real_fired, windows.FALSE) == windows.FALSE) {
            log.err("SetWaitableTimer failed: {}", .{windows.GetLastError()});
            // Couldn't arm: forget so the next scan retries, and report failure
            // so the loop folds real into the capped poll timeout.
            self.real_armed = null;
            return false;
        }
    } else {
        // Disarm. A failed cancel leaves the old one-shot armed; its APC would
        // wake one extra poll harmlessly, so we still report success.
        if (windows.CancelWaitableTimer(self.real_timer) == windows.FALSE) {
            log.err("CancelWaitableTimer failed: {}", .{windows.GetLastError()});
        }
    }
    self.real_armed = deadline;
    return true;
}

/// Drain the real-timer fire flag set by `wallTimerAPC`. Returns true if the
/// timer fired, which poll reports as a timeout so the loop re-runs checkTimers.
/// A fired one-shot is gone, so clear `real_armed` to force a re-arm for the
/// next deadline on the following scan.
fn consumeWallFired(self: *Self) bool {
    if (!self.real_fired) return false;
    self.real_fired = false;
    self.real_armed = null;
    return true;
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    const timeout_ms: u32 = std.math.cast(u32, timeout.toMilliseconds()) orelse std.math.maxInt(u32);

    var num_entries: u32 = 0;
    const result = windows.GetQueuedCompletionStatusEx(
        self.shared_state.iocp, // Safe to access without mutex - we hold a reference
        self.entries.ptr,
        @intCast(self.entries.len),
        &num_entries,
        timeout_ms,
        windows.TRUE, // Alertable - allows QueueUserAPC to wake us
    );

    if (result == windows.FALSE) {
        const err = windows.GetLastError();
        switch (err) {
            .WAIT_TIMEOUT => {
                log.debug("poll() timed out", .{});
                _ = self.consumeWallFired();
                return true; // Timed out
            },
            WAIT_IO_COMPLETION => {
                // Woken by an APC: either wake() or a wall-timer fire. Report a
                // timeout only when a boot/real timer actually fired so the loop
                // re-runs checkTimers; a bare wake() returns false.
                log.debug("poll() woken by APC", .{});
                return self.consumeWallFired();
            },
            else => {
                log.err("GetQueuedCompletionStatusEx failed: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    // Process completions
    for (self.entries[0..num_entries]) |entry| {
        self.processCompletion(state, &entry);
    }

    // Completions preempt APC delivery, so a pending wall-timer APC may not have
    // run yet; consume whatever did fire and report it as a timeout.
    return self.consumeWallFired();
}
