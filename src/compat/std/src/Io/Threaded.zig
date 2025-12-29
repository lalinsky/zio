const Threaded = @This();

const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_darwin = native_os.isDarwin();
const is_debug = builtin.mode == .Debug;

const std = @import("../std.zig");
const Io = std.Io;
const net = std.Io.net;
const File = std.Io.File;
const Dir = std.Io.Dir;
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const posix = std.posix;
const windows = std.os.windows;
const ws2_32 = std.os.windows.ws2_32;

/// Thread-safe.
allocator: Allocator,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
run_queue: std.SinglyLinkedList = .{},
join_requested: bool = false,
stack_size: usize,
/// All threads are spawned detached; this is how we wait until they all exit.
wait_group: std.Thread.WaitGroup = .{},
async_limit: Io.Limit,
concurrent_limit: Io.Limit = .unlimited,
/// Error from calling `std.Thread.getCpuCount` in `init`.
cpu_count_error: ?std.Thread.CpuCountError,
/// Number of threads that are unavailable to take tasks. To calculate
/// available count, subtract this from either `async_limit` or
/// `concurrent_limit`.
busy_count: usize = 0,
main_thread: Thread,
pid: Pid = .unknown,
robust_cancel: RobustCancel,

wsa: if (is_windows) Wsa else struct {} = .{},

have_signal_handler: bool,
old_sig_io: if (have_sig_io) posix.Sigaction else void,
old_sig_pipe: if (have_sig_pipe) posix.Sigaction else void,

use_sendfile: UseSendfile = .default,
use_copy_file_range: UseCopyFileRange = .default,
use_fcopyfile: UseFcopyfile = .default,
use_fchmodat2: UseFchmodat2 = .default,

stderr_writer: File.Writer = .{
    .io = undefined,
    .interface = Io.File.Writer.initInterface(&.{}),
    .file = if (is_windows) undefined else .stderr(),
    .mode = .streaming,
},
stderr_mode: Io.Terminal.Mode = .no_color,
stderr_writer_initialized: bool = false,

argv0: Argv0,
environ: Environ,

pub const Argv0 = switch (native_os) {
    .openbsd, .haiku => struct {
        value: ?[*:0]const u8 = null,
    },
    else => struct {},
};

pub const Environ = struct {
    /// Unmodified data directly from the OS.
    block: Block = &.{},
    /// Protected by `mutex`. Determines whether the other fields have been
    /// memoized based on `block`.
    initialized: bool = false,
    /// Protected by `mutex`. Memoized based on `block`. Tracks whether the
    /// environment variables are present, ignoring their value.
    exist: Exist = .{},
    /// Protected by `mutex`. Memoized based on `block`.
    string: String = .{},
    /// Protected by `mutex`. Tracks the problem, if any, that occurred when
    /// trying to scan environment variables.
    ///
    /// Errors are only possible on WASI.
    err: ?Error = null,

    pub const Error = Allocator.Error || Io.UnexpectedError;

    pub const Block = []const [*:0]const u8;

    pub const Exist = struct {
        NO_COLOR: bool = false,
        CLICOLOR_FORCE: bool = false,
    };

    pub const String = switch (native_os) {
        .openbsd, .haiku => struct {
            PATH: ?[:0]const u8 = null,
        },
        else => struct {},
    };
};

pub const RobustCancel = if (std.Thread.use_pthreads or native_os == .linux) enum {
    enabled,
    disabled,
} else enum {
    disabled,
};

pub const Pid = if (native_os == .linux) enum(posix.pid_t) {
    unknown = 0,
    _,
} else enum(u0) { unknown = 0 };

pub const UseSendfile = if (have_sendfile) enum {
    enabled,
    disabled,
    pub const default: UseSendfile = .enabled;
} else enum {
    disabled,
    pub const default: UseSendfile = .disabled;
};

pub const UseCopyFileRange = if (have_copy_file_range) enum {
    enabled,
    disabled,
    pub const default: UseCopyFileRange = .enabled;
} else enum {
    disabled,
    pub const default: UseCopyFileRange = .disabled;
};

pub const UseFcopyfile = if (have_fcopyfile) enum {
    enabled,
    disabled,
    pub const default: UseFcopyfile = .enabled;
} else enum {
    disabled,
    pub const default: UseFcopyfile = .disabled;
};

pub const UseFchmodat2 = if (have_fchmodat2 and !have_fchmodat_flags) enum {
    enabled,
    disabled,
    pub const default: UseFchmodat2 = .enabled;
} else enum {
    disabled,
    pub const default: UseFchmodat2 = .disabled;
};

const Thread = struct {
    /// The value that needs to be passed to pthread_kill or tgkill in order to
    /// send a signal.
    signal_id: SignaleeId,
    current_closure: ?*Closure,
    /// Only populated if `current_closure != null`. Indicates the current cancel protection mode.
    cancel_protection: Io.CancelProtection,

    const SignaleeId = if (std.Thread.use_pthreads) std.c.pthread_t else std.Thread.Id;

    threadlocal var current: ?*Thread = null;

    fn getCurrent(t: *Threaded) *Thread {
        return current orelse return &t.main_thread;
    }

    fn checkCancel(thread: *Thread) error{Canceled}!void {
        const closure = thread.current_closure orelse return;

        switch (thread.cancel_protection) {
            .unblocked => {},
            .blocked => return,
        }

        switch (@cmpxchgStrong(
            CancelStatus,
            &closure.cancel_status,
            .requested,
            .acknowledged,
            .acq_rel,
            .acquire,
        ) orelse return error.Canceled) {
            .requested => unreachable,
            .acknowledged => unreachable,
            .none, _ => {},
        }
    }

    fn beginSyscall(thread: *Thread) error{Canceled}!void {
        const closure = thread.current_closure orelse return;

        switch (thread.cancel_protection) {
            .unblocked => {},
            .blocked => return,
        }

        switch (@cmpxchgStrong(
            CancelStatus,
            &closure.cancel_status,
            .none,
            .fromSignaleeId(thread.signal_id),
            .acq_rel,
            .acquire,
        ) orelse return) {
            .none => unreachable,
            .requested => {
                @atomicStore(CancelStatus, &closure.cancel_status, .acknowledged, .release);
                return error.Canceled;
            },
            .acknowledged => return,
            _ => unreachable,
        }
    }

    fn endSyscall(thread: *Thread) void {
        const closure = thread.current_closure orelse return;

        switch (thread.cancel_protection) {
            .unblocked => {},
            .blocked => return,
        }

        _ = @cmpxchgStrong(
            CancelStatus,
            &closure.cancel_status,
            .fromSignaleeId(thread.signal_id),
            .none,
            .acq_rel,
            .acquire,
        ) orelse return;
    }

    fn endSyscallErrnoBug(thread: *Thread, err: posix.E) Io.UnexpectedError {
        @branchHint(.cold);
        thread.endSyscall();
        return errnoBug(err);
    }

    fn endSyscallUnexpectedErrno(thread: *Thread, err: posix.E) Io.UnexpectedError {
        @branchHint(.cold);
        thread.endSyscall();
        return posix.unexpectedErrno(err);
    }

    /// inline to make error return traces slightly shallower.
    inline fn endSyscallError(thread: *Thread, err: anytype) @TypeOf(err) {
        thread.endSyscall();
        return err;
    }

    fn currentSignalId() SignaleeId {
        return if (std.Thread.use_pthreads) std.c.pthread_self() else std.Thread.getCurrentId();
    }

    fn futexWaitUncancelable(ptr: *const u32, expect: u32) void {
        return Thread.futexWaitTimed(null, ptr, expect, null) catch unreachable;
    }

    fn futexWait(thread: *Thread, ptr: *const u32, expect: u32) Io.Cancelable!void {
        return Thread.futexWaitTimed(thread, ptr, expect, null) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => unreachable,
        };
    }

    fn futexWaitTimed(thread: ?*Thread, ptr: *const u32, expect: u32, timeout_ns: ?u64) Io.Cancelable!void {
        @branchHint(.cold);

        if (builtin.single_threaded) unreachable; // nobody would ever wake us

        if (builtin.cpu.arch.isWasm()) {
            comptime assert(builtin.cpu.has(.wasm, .atomics));
            if (thread) |t| try t.checkCancel();
            const to: i64 = if (timeout_ns) |ns| ns else -1;
            const signed_expect: i32 = @bitCast(expect);
            const result = asm volatile (
                \\local.get %[ptr]
                \\local.get %[expected]
                \\local.get %[timeout]
                \\memory.atomic.wait32 0
                \\local.set %[ret]
                : [ret] "=r" (-> u32),
                : [ptr] "r" (ptr),
                  [expected] "r" (signed_expect),
                  [timeout] "r" (to),
            );
            switch (result) {
                0 => {}, // ok
                1 => {}, // expected != loaded
                2 => {}, // timeout
                else => assert(!is_debug),
            }
        } else switch (native_os) {
            .linux => {
                const linux = std.os.linux;
                var ts_buffer: linux.timespec = undefined;
                const ts: ?*linux.timespec = if (timeout_ns) |ns| ts: {
                    ts_buffer = timestampToPosix(ns);
                    break :ts &ts_buffer;
                } else null;
                if (thread) |t| try t.beginSyscall();
                const rc = linux.futex_4arg(ptr, .{ .cmd = .WAIT, .private = true }, expect, ts);
                if (thread) |t| t.endSyscall();
                switch (linux.errno(rc)) {
                    .SUCCESS => {}, // notified by `wake()`
                    .INTR => {}, // caller's responsibility to retry
                    .AGAIN => {}, // ptr.* != expect
                    .INVAL => {}, // possibly timeout overflow
                    .TIMEDOUT => {},
                    .FAULT => recoverableOsBugDetected(), // ptr was invalid
                    else => recoverableOsBugDetected(),
                }
            },
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
                const c = std.c;
                const flags: c.UL = .{
                    .op = .COMPARE_AND_WAIT,
                    .NO_ERRNO = true,
                };
                if (thread) |t| try t.beginSyscall();
                const status = switch (darwin_supports_ulock_wait2) {
                    true => c.__ulock_wait2(flags, ptr, expect, ns: {
                        const ns = timeout_ns orelse break :ns 0;
                        if (ns == 0) break :ns 1;
                        break :ns ns;
                    }, 0),
                    false => c.__ulock_wait(flags, ptr, expect, us: {
                        const ns = timeout_ns orelse break :us 0;
                        const us = std.math.lossyCast(u32, ns / std.time.ns_per_us);
                        if (us == 0) break :us 1;
                        break :us us;
                    }),
                };
                if (thread) |t| t.endSyscall();
                if (status >= 0) return;
                switch (@as(c.E, @enumFromInt(-status))) {
                    .INTR => {}, // spurious wake
                    // Address of the futex was paged out. This is unlikely, but possible in theory, and
                    // pthread/libdispatch on darwin bother to handle it. In this case we'll return
                    // without waiting, but the caller should retry anyway.
                    .FAULT => {},
                    .TIMEDOUT => {}, // timeout
                    else => recoverableOsBugDetected(),
                }
            },
            .windows => {
                var timeout_value: windows.LARGE_INTEGER = undefined;
                var timeout_ptr: ?*const windows.LARGE_INTEGER = null;
                // NTDLL functions work with time in units of 100 nanoseconds.
                // Positive values are absolute deadlines while negative values are relative durations.
                if (timeout_ns) |delay| {
                    timeout_value = @as(windows.LARGE_INTEGER, @intCast(delay / 100));
                    timeout_value = -timeout_value;
                    timeout_ptr = &timeout_value;
                }
                if (thread) |t| try t.checkCancel();
                switch (windows.ntdll.RtlWaitOnAddress(ptr, &expect, @sizeOf(@TypeOf(expect)), timeout_ptr)) {
                    .SUCCESS => {},
                    .CANCELLED => {},
                    .TIMEOUT => {}, // timeout
                    else => recoverableOsBugDetected(),
                }
            },
            .freebsd => {
                const flags = @intFromEnum(std.c.UMTX_OP.WAIT_UINT_PRIVATE);
                var tm_size: usize = 0;
                var tm: std.c._umtx_time = undefined;
                var tm_ptr: ?*const std.c._umtx_time = null;
                if (timeout_ns) |ns| {
                    tm_ptr = &tm;
                    tm_size = @sizeOf(@TypeOf(tm));
                    tm.flags = 0; // use relative time not UMTX_ABSTIME
                    tm.clockid = .MONOTONIC;
                    tm.timeout = timestampToPosix(ns);
                }
                if (thread) |t| try t.beginSyscall();
                const rc = std.c._umtx_op(@intFromPtr(ptr), flags, @as(c_ulong, expect), tm_size, @intFromPtr(tm_ptr));
                if (thread) |t| t.endSyscall();
                if (is_debug) switch (posix.errno(rc)) {
                    .SUCCESS => {},
                    .FAULT => unreachable, // one of the args points to invalid memory
                    .INVAL => unreachable, // arguments should be correct
                    .TIMEDOUT => {}, // timeout
                    .INTR => {}, // spurious wake
                    else => unreachable,
                };
            },
            else => if (std.Thread.use_pthreads) {
                // TODO integrate the following function being called with robust cancelation.
                return pthreads_futex.wait(ptr, expect, timeout_ns) catch |err| switch (err) {
                    error.Timeout => {},
                };
            } else {
                @compileError("unimplemented: futexWait");
            },
        }
    }

    fn futexWake(ptr: *const u32, max_waiters: u32) void {
        @branchHint(.cold);
        assert(max_waiters != 0);

        if (builtin.single_threaded) return; // nothing to wake up

        if (builtin.cpu.arch.isWasm()) {
            comptime assert(builtin.cpu.has(.wasm, .atomics));
            const woken_count = asm volatile (
                \\local.get %[ptr]
                \\local.get %[waiters]
                \\memory.atomic.notify 0
                \\local.set %[ret]
                : [ret] "=r" (-> u32),
                : [ptr] "r" (ptr),
                  [waiters] "r" (max_waiters),
            );
            _ = woken_count; // can be 0 when linker flag 'shared-memory' is not enabled
        } else switch (native_os) {
            .linux => {
                const linux = std.os.linux;
                switch (linux.errno(linux.futex_3arg(
                    ptr,
                    .{ .cmd = .WAKE, .private = true },
                    @min(max_waiters, std.math.maxInt(i32)),
                ))) {
                    .SUCCESS => return, // successful wake up
                    .INVAL => return, // invalid futex_wait() on ptr done elsewhere
                    .FAULT => return, // pointer became invalid while doing the wake
                    else => return recoverableOsBugDetected(), // deadlock due to operating system bug
                }
            },
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
                const c = std.c;
                const flags: c.UL = .{
                    .op = .COMPARE_AND_WAIT,
                    .NO_ERRNO = true,
                    .WAKE_ALL = max_waiters > 1,
                };
                while (true) {
                    const status = c.__ulock_wake(flags, ptr, 0);
                    if (status >= 0) return;
                    switch (@as(c.E, @enumFromInt(-status))) {
                        .INTR, .CANCELED => continue, // spurious wake()
                        .FAULT => unreachable, // __ulock_wake doesn't generate EFAULT according to darwin pthread_cond_t
                        .NOENT => return, // nothing was woken up
                        .ALREADY => unreachable, // only for UL.Op.WAKE_THREAD
                        else => unreachable, // deadlock due to operating system bug
                    }
                }
            },
            .windows => {
                switch (max_waiters) {
                    1 => windows.ntdll.RtlWakeAddressSingle(ptr),
                    else => windows.ntdll.RtlWakeAddressAll(ptr),
                }
            },
            .freebsd => {
                const rc = std.c._umtx_op(
                    @intFromPtr(ptr),
                    @intFromEnum(std.c.UMTX_OP.WAKE_PRIVATE),
                    @as(c_ulong, max_waiters),
                    0, // there is no timeout struct
                    0, // there is no timeout struct pointer
                );
                switch (posix.errno(rc)) {
                    .SUCCESS => {},
                    .FAULT => {}, // it's ok if the ptr doesn't point to valid memory
                    .INVAL => unreachable, // arguments should be correct
                    else => unreachable, // deadlock due to operating system bug
                }
            },
            else => if (std.Thread.use_pthreads) {
                return pthreads_futex.wake(ptr, max_waiters);
            } else {
                @compileError("unimplemented: futexWake");
            },
        }
    }
};

const max_iovecs_len = 8;
const splat_buffer_size = 64;

comptime {
    if (@TypeOf(posix.IOV_MAX) != void) assert(max_iovecs_len <= posix.IOV_MAX);
}

const CancelStatus = enum(usize) {
    /// Cancellation has neither been requested, nor checked. The async
    /// operation will check status before entering a blocking syscall.
    /// This is also the status used for uninteruptible tasks.
    none = 0,
    /// Cancellation has been requested and the status will be checked before
    /// entering a blocking syscall.
    requested = std.math.maxInt(usize) - 1,
    /// Cancellation has been acknowledged and is in progress. Signals should
    /// not be sent.
    acknowledged = std.math.maxInt(usize),
    /// Stores a `Thread.SignaleeId` and indicates that sending a signal to this thread
    /// is needed in order to cancel. This state is set before going into
    /// a blocking operation that needs to get unblocked via signal.
    _,

    const Unpacked = union(enum) {
        none,
        requested,
        acknowledged,
        signal_id: Thread.SignaleeId,
    };

    fn unpack(cs: CancelStatus) Unpacked {
        return switch (cs) {
            .none => .none,
            .requested => .requested,
            .acknowledged => .acknowledged,
            _ => |signal_id| .{
                .signal_id = if (std.Thread.use_pthreads)
                    @ptrFromInt(@intFromEnum(signal_id))
                else
                    @truncate(@intFromEnum(signal_id)),
            },
        };
    }

    fn fromSignaleeId(signal_id: Thread.SignaleeId) CancelStatus {
        return if (std.Thread.use_pthreads)
            @enumFromInt(@intFromPtr(signal_id))
        else
            @enumFromInt(signal_id);
    }
};

const Closure = struct {
    start: Start,
    node: std.SinglyLinkedList.Node = .{},
    cancel_status: CancelStatus,

    const Start = *const fn (*Closure, *Threaded) void;

    fn requestCancel(closure: *Closure, t: *Threaded) void {
        var signal_id = switch (@atomicRmw(CancelStatus, &closure.cancel_status, .Xchg, .requested, .monotonic).unpack()) {
            .none, .acknowledged, .requested => return,
            .signal_id => |signal_id| signal_id,
        };
        // The task will enter a blocking syscall before checking for cancellation again.
        // We can send a signal to interrupt the syscall, but if it arrives before
        // the syscall instruction, it will be missed. Therefore, this code tries
        // again until the cancellation request is acknowledged.

        // 1 << 10 ns is about 1 microsecond, approximately syscall overhead.
        // 1 << 20 ns is about 1 millisecond.
        // 1 << 30 ns is about 1 second.
        //
        // On a heavily loaded Linux 6.17.5, I observed a maximum of 20
        // attempts not acknowledged before the timeout (including exponential
        // backoff) was sufficient, despite the heavy load.
        const max_attempts = 22;

        for (0..max_attempts) |attempt_index| {
            if (std.Thread.use_pthreads) {
                if (std.c.pthread_kill(signal_id, .IO) != 0) return;
            } else if (native_os == .linux) {
                const pid: posix.pid_t = p: {
                    const cached_pid = @atomicLoad(Pid, &t.pid, .monotonic);
                    if (cached_pid != .unknown) break :p @intFromEnum(cached_pid);
                    const pid = std.os.linux.getpid();
                    @atomicStore(Pid, &t.pid, @enumFromInt(pid), .monotonic);
                    break :p pid;
                };
                if (std.os.linux.tgkill(pid, @bitCast(signal_id), .IO) != 0) return;
            } else {
                return;
            }

            if (t.robust_cancel != .enabled) return;

            var timespec: posix.timespec = .{
                .sec = 0,
                .nsec = @as(isize, 1) << @intCast(attempt_index),
            };
            if (native_os == .linux) {
                _ = std.os.linux.clock_nanosleep(posix.CLOCK.MONOTONIC, .{ .ABSTIME = false }, &timespec, &timespec);
            } else {
                _ = posix.system.nanosleep(&timespec, &timespec);
            }

            switch (@atomicRmw(CancelStatus, &closure.cancel_status, .Xchg, .requested, .monotonic).unpack()) {
                .requested => continue, // Retry needed in case other thread hasn't yet entered the syscall.
                .none, .acknowledged => return,
                .signal_id => |new_signal_id| signal_id = new_signal_id,
            }
        }
    }
};

pub const InitOptions = struct {
    /// Affects how many bytes are memory-mapped for threads.
    stack_size: usize = std.Thread.SpawnConfig.default_stack_size,
    /// Maximum thread pool size (excluding main thread) when dispatching async
    /// tasks. Until this limit, calls to `Io.async` when all threads are busy will
    /// cause a new thread to be spawned and permanently added to the pool. After
    /// this limit, calls to `Io.async` when all threads are busy run the task
    /// immediately.
    ///
    /// Defaults to a number equal to logical CPU cores.
    ///
    /// Protected by `Threaded.mutex` once the I/O instance is already in use. See
    /// `setAsyncLimit`.
    async_limit: ?Io.Limit = null,
    /// Maximum thread pool size (excluding main thread) for dispatching concurrent
    /// tasks. Until this limit, calls to `Io.concurrent` will increase the thread
    /// pool size.
    ///
    /// concurrent tasks. After this number, calls to `Io.concurrent` return
    /// `error.ConcurrencyUnavailable`.
    concurrent_limit: Io.Limit = .unlimited,
    /// When a cancel request is made, blocking syscalls can be unblocked by
    /// issuing a signal. However, if the signal arrives after the check and before
    /// the syscall instruction, it is missed.
    ///
    /// This option solves the race condition by retrying the signal delivery
    /// until it is acknowledged, with an exponential backoff.
    ///
    /// Unfortunately, trying again until the cancellation request is acknowledged
    /// has been observed to be relatively slow, and usually strong cancellation
    /// guarantees are not needed, so this defaults to off.
    robust_cancel: RobustCancel = .disabled,
    /// Affects the following operations:
    /// * `processExecutablePath` on OpenBSD and Haiku.
    argv0: Argv0 = .{},
    /// Affects the following operations:
    /// * `fileIsTty`
    /// * `processExecutablePath` on OpenBSD and Haiku (observes "PATH").
    environ: Environ = .{},
};

/// Related:
/// * `init_single_threaded`
pub fn init(
    /// Must be threadsafe. Only used for the following functions:
    /// * `Io.VTable.async`
    /// * `Io.VTable.concurrent`
    /// * `Io.VTable.groupAsync`
    /// * `Io.VTable.groupConcurrent`
    /// If these functions are avoided, then `Allocator.failing` may be passed
    /// here.
    gpa: Allocator,
    options: InitOptions,
) Threaded {
    if (builtin.single_threaded) return .init_single_threaded;

    const cpu_count = std.Thread.getCpuCount();

    var t: Threaded = .{
        .allocator = gpa,
        .stack_size = options.stack_size,
        .async_limit = options.async_limit orelse if (cpu_count) |n| .limited(n - 1) else |_| .nothing,
        .concurrent_limit = options.concurrent_limit,
        .cpu_count_error = if (cpu_count) |_| null else |e| e,
        .old_sig_io = undefined,
        .old_sig_pipe = undefined,
        .have_signal_handler = false,
        .main_thread = .{
            .signal_id = Thread.currentSignalId(),
            .current_closure = null,
            .cancel_protection = .unblocked,
        },
        .argv0 = options.argv0,
        .environ = options.environ,
        .robust_cancel = options.robust_cancel,
    };

    if (posix.Sigaction != void) {
        // This causes sending `posix.SIG.IO` to thread to interrupt blocking
        // syscalls, returning `posix.E.INTR`.
        const act: posix.Sigaction = .{
            .handler = .{ .handler = doNothingSignalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        if (have_sig_io) posix.sigaction(.IO, &act, &t.old_sig_io);
        if (have_sig_pipe) posix.sigaction(.PIPE, &act, &t.old_sig_pipe);
        t.have_signal_handler = true;
    }

    return t;
}

/// Statically initialize such that calls to `Io.VTable.concurrent` will fail
/// with `error.ConcurrencyUnavailable`.
///
/// When initialized this way:
/// * cancel requests have no effect.
/// * `deinit` is safe, but unnecessary to call.
pub const init_single_threaded: Threaded = .{
    .allocator = .failing,
    .stack_size = std.Thread.SpawnConfig.default_stack_size,
    .async_limit = .nothing,
    .cpu_count_error = null,
    .concurrent_limit = .nothing,
    .old_sig_io = undefined,
    .old_sig_pipe = undefined,
    .have_signal_handler = false,
    .main_thread = .{
        .signal_id = undefined,
        .current_closure = null,
        .cancel_protection = .unblocked,
    },
    .robust_cancel = .disabled,
    .argv0 = .{},
    .environ = .{},
};

var global_single_threaded_instance: Threaded = .init_single_threaded;

/// In general, the application is responsible for choosing the `Io`
/// implementation and library code should accept an `Io` parameter rather than
/// accessing this declaration. Most code should avoid referencing this
/// declaration entirely.
///
/// However, in some cases such as debugging, it is desirable to hardcode a
/// reference to this `Io` implementation.
///
/// This instance does not support concurrency or cancelation.
pub const global_single_threaded: *Threaded = &global_single_threaded_instance;

pub fn setAsyncLimit(t: *Threaded, new_limit: Io.Limit) void {
    t.mutex.lock();
    defer t.mutex.unlock();
    t.async_limit = new_limit;
}

pub fn deinit(t: *Threaded) void {
    t.join();
    if (is_windows and t.wsa.status == .initialized) {
        if (ws2_32.WSACleanup() != 0) recoverableOsBugDetected();
    }
    if (posix.Sigaction != void and t.have_signal_handler) {
        if (have_sig_io) posix.sigaction(.IO, &t.old_sig_io, null);
        if (have_sig_pipe) posix.sigaction(.PIPE, &t.old_sig_pipe, null);
    }
    t.* = undefined;
}

fn join(t: *Threaded) void {
    if (builtin.single_threaded) return;
    {
        t.mutex.lock();
        defer t.mutex.unlock();
        t.join_requested = true;
    }
    t.cond.broadcast();
    t.wait_group.wait();
}

fn worker(t: *Threaded) void {
    var thread: Thread = .{
        .signal_id = Thread.currentSignalId(),
        .current_closure = null,
        .cancel_protection = .unblocked,
    };
    Thread.current = &thread;

    defer t.wait_group.finish();

    t.mutex.lock();
    defer t.mutex.unlock();

    while (true) {
        while (t.run_queue.popFirst()) |closure_node| {
            t.mutex.unlock();
            const closure: *Closure = @fieldParentPtr("node", closure_node);
            closure.start(closure, t);
            t.mutex.lock();
            t.busy_count -= 1;
        }
        if (t.join_requested) break;
        t.cond.wait(&t.mutex);
    }
}

pub fn io(t: *Threaded) Io {
    return .{
        .userdata = t,
        .vtable = &.{
            .async = async,
            .concurrent = concurrent,
            .await = await,
            .cancel = cancel,
            .select = select,

            .groupAsync = groupAsync,
            .groupConcurrent = groupConcurrent,
            .groupWait = groupWait,
            .groupCancel = groupCancel,

            .recancel = recancel,
            .swapCancelProtection = swapCancelProtection,
            .checkCancel = checkCancel,

            .futexWait = futexWait,
            .futexWaitUncancelable = futexWaitUncancelable,
            .futexWake = futexWake,

            .dirCreateDir = dirCreateDir,
            .dirCreateDirPath = dirCreateDirPath,
            .dirCreateDirPathOpen = dirCreateDirPathOpen,
            .dirStat = dirStat,
            .dirStatFile = dirStatFile,
            .dirAccess = dirAccess,
            .dirCreateFile = dirCreateFile,
            .dirOpenFile = dirOpenFile,
            .dirOpenDir = dirOpenDir,
            .dirClose = dirClose,
            .dirRead = dirRead,
            .dirRealPath = dirRealPath,
            .dirRealPathFile = dirRealPathFile,
            .dirDeleteFile = dirDeleteFile,
            .dirDeleteDir = dirDeleteDir,
            .dirRename = dirRename,
            .dirSymLink = dirSymLink,
            .dirReadLink = dirReadLink,
            .dirSetOwner = dirSetOwner,
            .dirSetFileOwner = dirSetFileOwner,
            .dirSetPermissions = dirSetPermissions,
            .dirSetFilePermissions = dirSetFilePermissions,
            .dirSetTimestamps = dirSetTimestamps,
            .dirHardLink = dirHardLink,

            .fileStat = fileStat,
            .fileLength = fileLength,
            .fileClose = fileClose,
            .fileWriteStreaming = fileWriteStreaming,
            .fileWritePositional = fileWritePositional,
            .fileWriteFileStreaming = fileWriteFileStreaming,
            .fileWriteFilePositional = fileWriteFilePositional,
            .fileReadStreaming = fileReadStreaming,
            .fileReadPositional = fileReadPositional,
            .fileSeekBy = fileSeekBy,
            .fileSeekTo = fileSeekTo,
            .fileSync = fileSync,
            .fileIsTty = fileIsTty,
            .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes,
            .fileSetLength = fileSetLength,
            .fileSetOwner = fileSetOwner,
            .fileSetPermissions = fileSetPermissions,
            .fileSetTimestamps = fileSetTimestamps,
            .fileLock = fileLock,
            .fileTryLock = fileTryLock,
            .fileUnlock = fileUnlock,
            .fileDowngradeLock = fileDowngradeLock,
            .fileRealPath = fileRealPath,

            .processExecutableOpen = processExecutableOpen,
            .processExecutablePath = processExecutablePath,
            .lockStderr = lockStderr,
            .tryLockStderr = tryLockStderr,
            .unlockStderr = unlockStderr,
            .processSetCurrentDir = processSetCurrentDir,

            .now = now,
            .sleep = sleep,

            .netListenIp = switch (native_os) {
                .windows => netListenIpWindows,
                else => netListenIpPosix,
            },
            .netListenUnix = switch (native_os) {
                .windows => netListenUnixWindows,
                else => netListenUnixPosix,
            },
            .netAccept = switch (native_os) {
                .windows => netAcceptWindows,
                else => netAcceptPosix,
            },
            .netBindIp = switch (native_os) {
                .windows => netBindIpWindows,
                else => netBindIpPosix,
            },
            .netConnectIp = switch (native_os) {
                .windows => netConnectIpWindows,
                else => netConnectIpPosix,
            },
            .netConnectUnix = switch (native_os) {
                .windows => netConnectUnixWindows,
                else => netConnectUnixPosix,
            },
            .netClose = netClose,
            .netShutdown = switch (native_os) {
                .windows => netShutdownWindows,
                else => netShutdownPosix,
            },
            .netRead = switch (native_os) {
                .windows => netReadWindows,
                else => netReadPosix,
            },
            .netWrite = switch (native_os) {
                .windows => netWriteWindows,
                else => netWritePosix,
            },
            .netWriteFile = netWriteFile,
            .netSend = switch (native_os) {
                .windows => netSendWindows,
                else => netSendPosix,
            },
            .netReceive = switch (native_os) {
                .windows => netReceiveWindows,
                else => netReceivePosix,
            },
            .netInterfaceNameResolve = netInterfaceNameResolve,
            .netInterfaceName = netInterfaceName,
            .netLookup = netLookup,
        },
    };
}

/// Same as `io` but disables all networking functionality, which has
/// an additional dependency on Windows (ws2_32).
pub fn ioBasic(t: *Threaded) Io {
    return .{
        .userdata = t,
        .vtable = &.{
            .async = async,
            .concurrent = concurrent,
            .await = await,
            .cancel = cancel,
            .select = select,

            .groupAsync = groupAsync,
            .groupConcurrent = groupConcurrent,
            .groupWait = groupWait,
            .groupCancel = groupCancel,

            .recancel = recancel,
            .swapCancelProtection = swapCancelProtection,
            .checkCancel = checkCancel,

            .futexWait = futexWait,
            .futexWaitUncancelable = futexWaitUncancelable,
            .futexWake = futexWake,

            .dirCreateDir = dirCreateDir,
            .dirCreateDirPath = dirCreateDirPath,
            .dirCreateDirPathOpen = dirCreateDirPathOpen,
            .dirStat = dirStat,
            .dirStatFile = dirStatFile,
            .dirAccess = dirAccess,
            .dirCreateFile = dirCreateFile,
            .dirOpenFile = dirOpenFile,
            .dirOpenDir = dirOpenDir,
            .dirClose = dirClose,
            .dirRead = dirRead,
            .dirRealPath = dirRealPath,
            .dirRealPathFile = dirRealPathFile,
            .dirDeleteFile = dirDeleteFile,
            .dirDeleteDir = dirDeleteDir,
            .dirRename = dirRename,
            .dirSymLink = dirSymLink,
            .dirReadLink = dirReadLink,
            .dirSetOwner = dirSetOwner,
            .dirSetFileOwner = dirSetFileOwner,
            .dirSetPermissions = dirSetPermissions,
            .dirSetFilePermissions = dirSetFilePermissions,
            .dirSetTimestamps = dirSetTimestamps,
            .dirHardLink = dirHardLink,

            .fileStat = fileStat,
            .fileLength = fileLength,
            .fileClose = fileClose,
            .fileWriteStreaming = fileWriteStreaming,
            .fileWritePositional = fileWritePositional,
            .fileWriteFileStreaming = fileWriteFileStreaming,
            .fileWriteFilePositional = fileWriteFilePositional,
            .fileReadStreaming = fileReadStreaming,
            .fileReadPositional = fileReadPositional,
            .fileSeekBy = fileSeekBy,
            .fileSeekTo = fileSeekTo,
            .fileSync = fileSync,
            .fileIsTty = fileIsTty,
            .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes,
            .fileSetLength = fileSetLength,
            .fileSetOwner = fileSetOwner,
            .fileSetPermissions = fileSetPermissions,
            .fileSetTimestamps = fileSetTimestamps,
            .fileLock = fileLock,
            .fileTryLock = fileTryLock,
            .fileUnlock = fileUnlock,
            .fileDowngradeLock = fileDowngradeLock,
            .fileRealPath = fileRealPath,

            .processExecutableOpen = processExecutableOpen,
            .processExecutablePath = processExecutablePath,
            .lockStderr = lockStderr,
            .tryLockStderr = tryLockStderr,
            .unlockStderr = unlockStderr,
            .processSetCurrentDir = processSetCurrentDir,

            .now = now,
            .sleep = sleep,

            .netListenIp = netListenIpUnavailable,
            .netListenUnix = netListenUnixUnavailable,
            .netAccept = netAcceptUnavailable,
            .netBindIp = netBindIpUnavailable,
            .netConnectIp = netConnectIpUnavailable,
            .netConnectUnix = netConnectUnixUnavailable,
            .netClose = netCloseUnavailable,
            .netShutdown = netShutdownUnavailable,
            .netRead = netReadUnavailable,
            .netWrite = netWriteUnavailable,
            .netWriteFile = netWriteFileUnavailable,
            .netSend = netSendUnavailable,
            .netReceive = netReceiveUnavailable,
            .netInterfaceNameResolve = netInterfaceNameResolveUnavailable,
            .netInterfaceName = netInterfaceNameUnavailable,
            .netLookup = netLookupUnavailable,
        },
    };
}

pub const socket_flags_unsupported = is_darwin or native_os == .haiku;
const have_accept4 = !socket_flags_unsupported;
const have_flock_open_flags = @hasField(posix.O, "EXLOCK");
const have_networking = native_os != .wasi;
const have_flock = @TypeOf(posix.system.flock) != void;
const have_sendmmsg = native_os == .linux;
const have_futex = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => builtin.cpu.has(.wasm, .atomics),
    else => true,
};
const have_preadv = switch (native_os) {
    .windows, .haiku => false,
    else => true,
};
const have_sig_io = posix.SIG != void and @hasField(posix.SIG, "IO");
const have_sig_pipe = posix.SIG != void and @hasField(posix.SIG, "PIPE");
const have_sendfile = if (builtin.link_libc) @TypeOf(std.c.sendfile) != void else native_os == .linux;
const have_copy_file_range = switch (native_os) {
    .linux, .freebsd => true,
    else => false,
};
const have_fcopyfile = is_darwin;
const have_fchmodat2 = native_os == .linux and
    (builtin.os.isAtLeast(.linux, .{ .major = 6, .minor = 6, .patch = 0 }) orelse true) and
    (builtin.abi.isAndroid() or !std.c.versionCheck(.{ .major = 2, .minor = 32, .patch = 0 }));
const have_fchmodat_flags = native_os != .linux or
    (!builtin.abi.isAndroid() and std.c.versionCheck(.{ .major = 2, .minor = 32, .patch = 0 }));

const have_fchown = switch (native_os) {
    .wasi, .windows => false,
    else => true,
};

const have_fchmod = switch (native_os) {
    .windows => false,
    .wasi => builtin.link_libc,
    else => true,
};

const openat_sym = if (posix.lfs64_abi) posix.system.openat64 else posix.system.openat;
const fstat_sym = if (posix.lfs64_abi) posix.system.fstat64 else posix.system.fstat;
const fstatat_sym = if (posix.lfs64_abi) posix.system.fstatat64 else posix.system.fstatat;
const lseek_sym = if (posix.lfs64_abi) posix.system.lseek64 else posix.system.lseek;
const preadv_sym = if (posix.lfs64_abi) posix.system.preadv64 else posix.system.preadv;
const ftruncate_sym = if (posix.lfs64_abi) posix.system.ftruncate64 else posix.system.ftruncate;
const pwritev_sym = if (posix.lfs64_abi) posix.system.pwritev64 else posix.system.pwritev;
const sendfile_sym = if (posix.lfs64_abi) posix.system.sendfile64 else posix.system.sendfile;
const linux_copy_file_range_use_c = std.c.versionCheck(if (builtin.abi.isAndroid()) .{
    .major = 34,
    .minor = 0,
    .patch = 0,
} else .{
    .major = 2,
    .minor = 27,
    .patch = 0,
});
const linux_copy_file_range_sys = if (linux_copy_file_range_use_c) std.c else std.os.linux;

/// Trailing data:
/// 1. context
/// 2. result
const AsyncClosure = struct {
    closure: Closure,
    func: *const fn (context: *anyopaque, result: *anyopaque) void,
    event: Io.Event,
    select_condition: ?*Io.Event,
    context_alignment: Alignment,
    result_offset: usize,
    alloc_len: usize,

    const done_event: *Io.Event = @ptrFromInt(@alignOf(Io.Event));

    fn start(closure: *Closure, t: *Threaded) void {
        const ac: *AsyncClosure = @alignCast(@fieldParentPtr("closure", closure));
        const current_thread = Thread.getCurrent(t);

        current_thread.current_closure = closure;
        current_thread.cancel_protection = .unblocked;

        ac.func(ac.contextPointer(), ac.resultPointer());

        current_thread.current_closure = null;
        current_thread.cancel_protection = undefined;

        if (@atomicRmw(?*Io.Event, &ac.select_condition, .Xchg, done_event, .release)) |select_event| {
            assert(select_event != done_event);
            select_event.set(ioBasic(t));
        }
        ac.event.set(ioBasic(t));
    }

    fn resultPointer(ac: *AsyncClosure) [*]u8 {
        const base: [*]u8 = @ptrCast(ac);
        return base + ac.result_offset;
    }

    fn contextPointer(ac: *AsyncClosure) [*]u8 {
        const base: [*]u8 = @ptrCast(ac);
        const context_offset = ac.context_alignment.forward(@intFromPtr(ac) + @sizeOf(AsyncClosure)) - @intFromPtr(ac);
        return base + context_offset;
    }

    fn init(
        gpa: Allocator,
        result_len: usize,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        func: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Allocator.Error!*AsyncClosure {
        const max_context_misalignment = context_alignment.toByteUnits() -| @alignOf(AsyncClosure);
        const worst_case_context_offset = context_alignment.forward(@sizeOf(AsyncClosure) + max_context_misalignment);
        const worst_case_result_offset = result_alignment.forward(worst_case_context_offset + context.len);
        const alloc_len = worst_case_result_offset + result_len;

        const ac: *AsyncClosure = @ptrCast(@alignCast(try gpa.alignedAlloc(u8, .of(AsyncClosure), alloc_len)));
        errdefer comptime unreachable;

        const actual_context_addr = context_alignment.forward(@intFromPtr(ac) + @sizeOf(AsyncClosure));
        const actual_result_addr = result_alignment.forward(actual_context_addr + context.len);
        const actual_result_offset = actual_result_addr - @intFromPtr(ac);
        ac.* = .{
            .closure = .{
                .cancel_status = .none,
                .start = start,
            },
            .func = func,
            .context_alignment = context_alignment,
            .result_offset = actual_result_offset,
            .alloc_len = alloc_len,
            .event = .unset,
            .select_condition = null,
        };
        @memcpy(ac.contextPointer()[0..context.len], context);
        return ac;
    }

    fn waitAndDeinit(ac: *AsyncClosure, t: *Threaded, result: []u8) void {
        ac.event.wait(ioBasic(t)) catch |err| switch (err) {
            error.Canceled => {
                ac.closure.requestCancel(t);
                ac.event.waitUncancelable(ioBasic(t));
            },
        };
        @memcpy(result, ac.resultPointer()[0..result.len]);
        ac.deinit(t.allocator);
    }

    fn deinit(ac: *AsyncClosure, gpa: Allocator) void {
        const base: [*]align(@alignOf(AsyncClosure)) u8 = @ptrCast(ac);
        gpa.free(base[0..ac.alloc_len]);
    }
};

fn async(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*Io.AnyFuture {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    if (builtin.single_threaded) {
        start(context.ptr, result.ptr);
        return null;
    }
    const gpa = t.allocator;
    const ac = AsyncClosure.init(gpa, result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, result.ptr);
        return null;
    };

    t.mutex.lock();

    const busy_count = t.busy_count;

    if (busy_count >= @intFromEnum(t.async_limit)) {
        t.mutex.unlock();
        ac.deinit(gpa);
        start(context.ptr, result.ptr);
        return null;
    }

    t.busy_count = busy_count + 1;

    const pool_size = t.wait_group.value();
    if (pool_size - busy_count == 0) {
        t.wait_group.start();
        const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {
            t.wait_group.finish();
            t.busy_count = busy_count;
            t.mutex.unlock();
            ac.deinit(gpa);
            start(context.ptr, result.ptr);
            return null;
        };
        thread.detach();
    }

    t.run_queue.prepend(&ac.closure.node);
    t.mutex.unlock();
    t.cond.signal();
    return @ptrCast(ac);
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    if (builtin.single_threaded) return error.ConcurrencyUnavailable;

    const t: *Threaded = @ptrCast(@alignCast(userdata));

    const gpa = t.allocator;
    const ac = AsyncClosure.init(gpa, result_len, result_alignment, context, context_alignment, start) catch
        return error.ConcurrencyUnavailable;
    errdefer ac.deinit(gpa);

    t.mutex.lock();
    defer t.mutex.unlock();

    const busy_count = t.busy_count;

    if (busy_count >= @intFromEnum(t.concurrent_limit))
        return error.ConcurrencyUnavailable;

    t.busy_count = busy_count + 1;
    errdefer t.busy_count = busy_count;

    const pool_size = t.wait_group.value();
    if (pool_size - busy_count == 0) {
        t.wait_group.start();
        errdefer t.wait_group.finish();

        const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch
            return error.ConcurrencyUnavailable;
        thread.detach();
    }

    t.run_queue.prepend(&ac.closure.node);
    t.cond.signal();
    return @ptrCast(ac);
}

const GroupClosure = struct {
    closure: Closure,
    group: *Io.Group,
    /// Points to sibling `GroupClosure`. Used for walking the group to cancel all.
    node: std.SinglyLinkedList.Node,
    func: *const fn (*Io.Group, context: *anyopaque) void,
    context_alignment: Alignment,
    alloc_len: usize,

    fn start(closure: *Closure, t: *Threaded) void {
        const gc: *GroupClosure = @alignCast(@fieldParentPtr("closure", closure));
        const current_thread = Thread.getCurrent(t);
        const group = gc.group;
        const group_state: *std.atomic.Value(usize) = @ptrCast(&group.state);
        const event: *Io.Event = @ptrCast(&group.context);
        current_thread.current_closure = closure;
        current_thread.cancel_protection = .unblocked;

        gc.func(group, gc.contextPointer());

        current_thread.current_closure = null;
        current_thread.cancel_protection = undefined;

        const prev_state = group_state.fetchSub(sync_one_pending, .acq_rel);
        assert((prev_state / sync_one_pending) > 0);
        if (prev_state == (sync_one_pending | sync_is_waiting)) event.set(ioBasic(t));
    }

    fn contextPointer(gc: *GroupClosure) [*]u8 {
        const base: [*]u8 = @ptrCast(gc);
        const context_offset = gc.context_alignment.forward(@intFromPtr(gc) + @sizeOf(GroupClosure)) - @intFromPtr(gc);
        return base + context_offset;
    }

    /// Does not initialize the `node` field.
    fn init(
        gpa: Allocator,
        group: *Io.Group,
        context: []const u8,
        context_alignment: Alignment,
        func: *const fn (*Io.Group, context: *const anyopaque) void,
    ) Allocator.Error!*GroupClosure {
        const max_context_misalignment = context_alignment.toByteUnits() -| @alignOf(GroupClosure);
        const worst_case_context_offset = context_alignment.forward(@sizeOf(GroupClosure) + max_context_misalignment);
        const alloc_len = worst_case_context_offset + context.len;

        const gc: *GroupClosure = @ptrCast(@alignCast(try gpa.alignedAlloc(u8, .of(GroupClosure), alloc_len)));
        errdefer comptime unreachable;

        gc.* = .{
            .closure = .{
                .cancel_status = .none,
                .start = start,
            },
            .group = group,
            .node = undefined,
            .func = func,
            .context_alignment = context_alignment,
            .alloc_len = alloc_len,
        };
        @memcpy(gc.contextPointer()[0..context.len], context);
        return gc;
    }

    fn deinit(gc: *GroupClosure, gpa: Allocator) void {
        const base: [*]align(@alignOf(GroupClosure)) u8 = @ptrCast(gc);
        gpa.free(base[0..gc.alloc_len]);
    }

    const sync_is_waiting: usize = 1 << 0;
    const sync_one_pending: usize = 1 << 1;
};

fn groupAsync(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (*Io.Group, context: *const anyopaque) void,
) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    if (builtin.single_threaded) return start(group, context.ptr);

    const gpa = t.allocator;
    const gc = GroupClosure.init(gpa, group, context, context_alignment, start) catch
        return start(group, context.ptr);

    t.mutex.lock();

    const busy_count = t.busy_count;

    if (busy_count >= @intFromEnum(t.async_limit)) {
        t.mutex.unlock();
        gc.deinit(gpa);
        return start(group, context.ptr);
    }

    t.busy_count = busy_count + 1;

    const pool_size = t.wait_group.value();
    if (pool_size - busy_count == 0) {
        t.wait_group.start();
        const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {
            t.wait_group.finish();
            t.busy_count = busy_count;
            t.mutex.unlock();
            gc.deinit(gpa);
            return start(group, context.ptr);
        };
        thread.detach();
    }

    // Append to the group linked list inside the mutex to make `Io.Group.async` thread-safe.
    gc.node = .{ .next = @ptrCast(@alignCast(group.token.load(.monotonic))) };
    group.token.store(&gc.node, .monotonic);

    t.run_queue.prepend(&gc.closure.node);

    // This needs to be done before unlocking the mutex to avoid a race with
    // the associated task finishing.
    const group_state: *std.atomic.Value(usize) = @ptrCast(&group.state);
    const prev_state = group_state.fetchAdd(GroupClosure.sync_one_pending, .monotonic);
    assert((prev_state / GroupClosure.sync_one_pending) < (std.math.maxInt(usize) / GroupClosure.sync_one_pending));

    t.mutex.unlock();
    t.cond.signal();
}

fn groupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (*Io.Group, context: *const anyopaque) void,
) Io.ConcurrentError!void {
    if (builtin.single_threaded) return error.ConcurrencyUnavailable;

    const t: *Threaded = @ptrCast(@alignCast(userdata));

    const gpa = t.allocator;
    const gc = GroupClosure.init(gpa, group, context, context_alignment, start) catch
        return error.ConcurrencyUnavailable;

    t.mutex.lock();
    defer t.mutex.unlock();

    const busy_count = t.busy_count;

    if (busy_count >= @intFromEnum(t.concurrent_limit))
        return error.ConcurrencyUnavailable;

    t.busy_count = busy_count + 1;
    errdefer t.busy_count = busy_count;

    const pool_size = t.wait_group.value();
    if (pool_size - busy_count == 0) {
        t.wait_group.start();
        errdefer t.wait_group.finish();

        const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch
            return error.ConcurrencyUnavailable;
        thread.detach();
    }

    // Append to the group linked list inside the mutex to make `Io.Group.concurrent` thread-safe.
    gc.node = .{ .next = @ptrCast(@alignCast(group.token.load(.monotonic))) };
    group.token.store(&gc.node, .monotonic);

    t.run_queue.prepend(&gc.closure.node);

    // This needs to be done before unlocking the mutex to avoid a race with
    // the associated task finishing.
    const group_state: *std.atomic.Value(usize) = @ptrCast(&group.state);
    const prev_state = group_state.fetchAdd(GroupClosure.sync_one_pending, .monotonic);
    assert((prev_state / GroupClosure.sync_one_pending) < (std.math.maxInt(usize) / GroupClosure.sync_one_pending));

    t.cond.signal();
}

fn groupWait(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const gpa = t.allocator;

    _ = initial_token; // we need to load `token` *after* the group finishes

    if (builtin.single_threaded) unreachable; // we never set `group.token` to non-`null`

    const group_state: *std.atomic.Value(usize) = @ptrCast(&group.state);
    const event: *Io.Event = @ptrCast(&group.context);
    const prev_state = group_state.fetchAdd(GroupClosure.sync_is_waiting, .acquire);
    assert(prev_state & GroupClosure.sync_is_waiting == 0);
    if ((prev_state / GroupClosure.sync_one_pending) > 0) event.wait(ioBasic(t)) catch |err| switch (err) {
        error.Canceled => {
            var it: ?*std.SinglyLinkedList.Node = @ptrCast(@alignCast(group.token.load(.monotonic)));
            while (it) |node| : (it = node.next) {
                const gc: *GroupClosure = @fieldParentPtr("node", node);
                gc.closure.requestCancel(t);
            }
            event.waitUncancelable(ioBasic(t));
        },
    };

    // Since the group has now finished, it's illegal to add more tasks to it until we return. It's
    // also illegal for us to race with another `await` or `cancel`. Therefore, we must be the only
    // thread who can access `group` right now.
    var it: ?*std.SinglyLinkedList.Node = @ptrCast(@alignCast(group.token.raw));
    group.token.raw = null;
    while (it) |node| {
        it = node.next; // update `it` now, because `deinit` will invalidate `node`
        const gc: *GroupClosure = @fieldParentPtr("node", node);
        gc.deinit(gpa);
    }
}

fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, initial_token: *anyopaque) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const gpa = t.allocator;

    _ = initial_token; // we need to load `token` *after* the group finishes

    if (builtin.single_threaded) unreachable; // we never set `group.token` to non-`null`

    {
        var it: ?*std.SinglyLinkedList.Node = @ptrCast(@alignCast(group.token.load(.monotonic)));
        while (it) |node| : (it = node.next) {
            const gc: *GroupClosure = @fieldParentPtr("node", node);
            gc.closure.requestCancel(t);
        }
    }

    const group_state: *std.atomic.Value(usize) = @ptrCast(&group.state);
    const event: *Io.Event = @ptrCast(&group.context);
    const prev_state = group_state.fetchAdd(GroupClosure.sync_is_waiting, .acquire);
    assert(prev_state & GroupClosure.sync_is_waiting == 0);
    if ((prev_state / GroupClosure.sync_one_pending) > 0) event.waitUncancelable(ioBasic(t));

    // Since the group has now finished, it's illegal to add more tasks to it until we return. It's
    // also illegal for us to race with another `await` or `cancel`. Therefore, we must be the only
    // thread who can access `group` right now.
    var it: ?*std.SinglyLinkedList.Node = @ptrCast(@alignCast(group.token.raw));
    group.token.raw = null;
    while (it) |node| {
        it = node.next; // update `it` now, because `deinit` will invalidate `node`
        const gc: *GroupClosure = @fieldParentPtr("node", node);
        gc.deinit(gpa);
    }
}

fn recancel(userdata: ?*anyopaque) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread: *Thread = .getCurrent(t);
    const cancel_status = &current_thread.current_closure.?.cancel_status;
    switch (@atomicLoad(CancelStatus, cancel_status, .monotonic)) {
        .none => unreachable, // called `recancel` when not canceled
        .requested => unreachable, // called `recancel` when cancelation was already outstanding
        .acknowledged => {},
        _ => unreachable, // invalid state: not in a syscall
    }
    @atomicStore(CancelStatus, cancel_status, .requested, .monotonic);
}

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread: *Thread = .getCurrent(t);
    const old = current_thread.cancel_protection;
    current_thread.cancel_protection = new;
    return old;
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    return Thread.getCurrent(t).checkCancel();
}

fn await(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: Alignment,
) void {
    _ = result_alignment;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const closure: *AsyncClosure = @ptrCast(@alignCast(any_future));
    closure.waitAndDeinit(t, result);
}

fn cancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: Alignment,
) void {
    _ = result_alignment;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const ac: *AsyncClosure = @ptrCast(@alignCast(any_future));
    ac.closure.requestCancel(t);
    ac.waitAndDeinit(t, result);
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    if (builtin.single_threaded) unreachable; // Deadlock.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const t_io = ioBasic(t);
    const timeout_ns: ?u64 = ns: {
        const d = (timeout.toDurationFromNow(t_io) catch break :ns 10) orelse break :ns null;
        break :ns std.math.lossyCast(u64, d.raw.toNanoseconds());
    };
    return Thread.futexWaitTimed(current_thread, ptr, expected, timeout_ns);
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    if (builtin.single_threaded) unreachable; // Deadlock.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    Thread.futexWaitUncancelable(ptr, expected);
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    if (builtin.single_threaded) unreachable; // Nothing to wake up.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    Thread.futexWake(ptr, max_waiters);
}

const dirCreateDir = switch (native_os) {
    .windows => dirCreateDirWindows,
    .wasi => dirCreateDirWasi,
    else => dirCreateDirPosix,
};

fn dirCreateDirPosix(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.mkdirat(dir.handle, sub_path_posix, permissions.toMode()))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .PERM => return error.PermissionDenied,
                    .DQUOT => return error.DiskQuota,
                    .EXIST => return error.PathAlreadyExists,
                    .FAULT => |err| return errnoBug(err),
                    .LOOP => return error.SymLinkLoop,
                    .MLINK => return error.LinkQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    // dragonfly: when dir_fd is unlinked from filesystem
                    .NOTCONN => return error.FileNotFound,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirCreateDirWasi(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    if (builtin.link_libc) return dirCreateDirPosix(userdata, dir, sub_path, permissions);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.wasi.path_create_directory(dir.handle, sub_path.ptr, sub_path.len)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .PERM => return error.PermissionDenied,
                    .DQUOT => return error.DiskQuota,
                    .EXIST => return error.PathAlreadyExists,
                    .FAULT => |err| return errnoBug(err),
                    .LOOP => return error.SymLinkLoop,
                    .MLINK => return error.LinkQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirCreateDirWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.checkCancel();

    const sub_path_w = try windows.sliceToPrefixedFileW(dir.handle, sub_path);
    _ = permissions; // TODO use this value
    const sub_dir_handle = windows.OpenFile(sub_path_w.span(), .{
        .dir = dir.handle,
        .access_mask = .{
            .GENERIC = .{ .READ = true },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        .creation = .CREATE,
        .filter = .dir_only,
    }) catch |err| switch (err) {
        error.IsDir => return error.Unexpected,
        error.PipeBusy => return error.Unexpected,
        error.NoDevice => return error.Unexpected,
        error.WouldBlock => return error.Unexpected,
        error.AntivirusInterference => return error.Unexpected,
        else => |e| return e,
    };
    windows.CloseHandle(sub_dir_handle);
}

fn dirCreateDirPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirPathError!Dir.CreatePathStatus {
    const t: *Threaded = @ptrCast(@alignCast(userdata));

    var it = std.fs.path.componentIterator(sub_path);
    var status: Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        if (dirCreateDir(t, dir, component.path, permissions)) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                // stat the file and return an error if it's not a directory
                // this is important because otherwise a dangling symlink
                // could cause an infinite loop
                const fstat = try dirStatFile(t, dir, component.path, .{});
                if (fstat.kind != .directory) return error.NotDir;
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        }
        component = it.next() orelse return status;
    }
}

const dirCreateDirPathOpen = switch (native_os) {
    .windows => dirCreateDirPathOpenWindows,
    .wasi => dirCreateDirPathOpenWasi,
    else => dirCreateDirPathOpenPosix,
};

fn dirCreateDirPathOpenPosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const t_io = ioBasic(t);
    return dirOpenDirPosix(t, dir, sub_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try dir.createDirPathStatus(t_io, sub_path, permissions);
            return dirOpenDirPosix(t, dir, sub_path, options);
        },
        else => |e| return e,
    };
}

fn dirCreateDirPathOpenWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    _ = permissions; // TODO apply these permissions

    var it = std.fs.path.componentIterator(sub_path);
    // If there are no components in the path, then create a dummy component with the full path.
    var component: std.fs.path.NativeComponentIterator.Component = it.last() orelse .{
        .name = "",
        .path = sub_path,
    };

    while (true) {
        try current_thread.checkCancel();

        const sub_path_w_array = try w.sliceToPrefixedFileW(dir.handle, component.path);
        const sub_path_w = sub_path_w_array.span();
        const is_last = it.peekNext() == null;
        const create_disposition: w.FILE.CREATE_DISPOSITION = if (is_last) .OPEN_IF else .CREATE;

        var result: Dir = .{ .handle = undefined };

        const path_len_bytes: u16 = @intCast(sub_path_w.len * 2);
        var nt_name: w.UNICODE_STRING = .{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(sub_path_w.ptr),
        };
        var io_status_block: w.IO_STATUS_BLOCK = undefined;
        const rc = w.ntdll.NtCreateFile(
            &result.handle,
            .{
                .SPECIFIC = .{ .FILE_DIRECTORY = .{
                    .LIST = options.iterate,
                    .READ_EA = true,
                    .READ_ATTRIBUTES = true,
                    .TRAVERSE = true,
                } },
                .STANDARD = .{
                    .RIGHTS = .READ,
                    .SYNCHRONIZE = true,
                },
            },
            &.{
                .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
                .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else dir.handle,
                .Attributes = .{},
                .ObjectName = &nt_name,
                .SecurityDescriptor = null,
                .SecurityQualityOfService = null,
            },
            &io_status_block,
            null,
            .{ .NORMAL = true },
            .VALID_FLAGS,
            create_disposition,
            .{
                .DIRECTORY_FILE = true,
                .IO = .SYNCHRONOUS_NONALERT,
                .OPEN_FOR_BACKUP_INTENT = true,
                .OPEN_REPARSE_POINT = !options.follow_symlinks,
            },
            null,
            0,
        );

        switch (rc) {
            .SUCCESS => {
                component = it.next() orelse return result;
                w.CloseHandle(result.handle);
                continue;
            },
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_COLLISION => {
                assert(!is_last);
                // stat the file and return an error if it's not a directory
                // this is important because otherwise a dangling symlink
                // could cause an infinite loop
                const fstat = try dirStatFileWindows(t, dir, component.path, .{
                    .follow_symlinks = options.follow_symlinks,
                });
                if (fstat.kind != .directory) return error.NotDir;

                component = it.next().?;
                continue;
            },

            .OBJECT_NAME_NOT_FOUND,
            .OBJECT_PATH_NOT_FOUND,
            => {
                component = it.previous() orelse return error.FileNotFound;
                continue;
            },

            .NOT_A_DIRECTORY => return error.NotDir,
            // This can happen if the directory has 'List folder contents' permission set to 'Deny'
            // and the directory is trying to be opened for iteration.
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_PARAMETER => |err| return w.statusBug(err),
            else => return w.unexpectedStatus(rc),
        }
    }
}

fn dirCreateDirPathOpenWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const t_io = ioBasic(t);
    return dirOpenDirWasi(t, dir, sub_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try dir.createDirPathStatus(t_io, sub_path, permissions);
            return dirOpenDirWasi(t, dir, sub_path, options);
        },
        else => |e| return e,
    };
}

fn dirStat(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const file: File = .{ .handle = dir.handle };
    return fileStat(t, file);
}

const dirStatFile = switch (native_os) {
    .linux => dirStatFileLinux,
    .windows => dirStatFileWindows,
    .wasi => dirStatFileWasi,
    else => dirStatFilePosix,
};

fn dirStatFileLinux(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const linux = std.os.linux;
    const use_c = std.c.versionCheck(if (builtin.abi.isAndroid())
        .{ .major = 30, .minor = 0, .patch = 0 }
    else
        .{ .major = 2, .minor = 28, .patch = 0 });
    const sys = if (use_c) std.c else std.os.linux;

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const flags: u32 = linux.AT.NO_AUTOMOUNT |
        @as(u32, if (!options.follow_symlinks) linux.AT.SYMLINK_NOFOLLOW else 0);

    try current_thread.beginSyscall();
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        switch (sys.errno(sys.statx(dir.handle, sub_path_posix, flags, linux_statx_request, &statx))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromLinux(&statx);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => |err| return errnoBug(err), // Handled by pathToPosix() above.
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirStatFilePosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const flags: u32 = if (!options.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    return posixStatFile(current_thread, dir.handle, sub_path_posix, flags);
}

fn posixStatFile(current_thread: *Thread, dir_fd: posix.fd_t, sub_path: [:0]const u8, flags: u32) Dir.StatFileError!File.Stat {
    try current_thread.beginSyscall();
    while (true) {
        var stat = std.mem.zeroes(posix.Stat);
        switch (posix.errno(fstatat_sym(dir_fd, sub_path, &stat, flags))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromPosix(&stat);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOMEM => return error.SystemResources,
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .FAULT => |err| return errnoBug(err),
                    .NAMETOOLONG => return error.NameTooLong,
                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.FileNotFound,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirStatFileWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const file = try dirOpenFileWindows(t, dir, sub_path, .{
        .follow_symlinks = options.follow_symlinks,
    });
    defer windows.CloseHandle(file.handle);
    return fileStatWindows(t, file);
}

fn dirStatFileWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    if (builtin.link_libc) return dirStatFilePosix(userdata, dir, sub_path, options);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const wasi = std.os.wasi;
    const flags: wasi.lookupflags_t = .{
        .SYMLINK_FOLLOW = options.follow_symlinks,
    };
    var stat: wasi.filestat_t = undefined;
    try current_thread.beginSyscall();
    while (true) {
        switch (wasi.path_filestat_get(dir.handle, flags, sub_path.ptr, sub_path.len, &stat)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromWasi(&stat);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOMEM => return error.SystemResources,
                    .ACCES => return error.AccessDenied,
                    .FAULT => |err| return errnoBug(err),
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.FileNotFound,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileLength(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    const t: *Threaded = @ptrCast(@alignCast(userdata));

    if (native_os == .linux) {
        const current_thread = Thread.getCurrent(t);
        const linux = std.os.linux;

        try current_thread.beginSyscall();
        while (true) {
            var statx = std.mem.zeroes(linux.Statx);
            switch (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &statx))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    if (!statx.mask.SIZE) return error.Unexpected;
                    return statx.size;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .ACCES => |err| return errnoBug(err),
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .FAULT => |err| return errnoBug(err),
                        .INVAL => |err| return errnoBug(err),
                        .LOOP => |err| return errnoBug(err),
                        .NAMETOOLONG => |err| return errnoBug(err),
                        .NOENT => |err| return errnoBug(err),
                        .NOMEM => return error.SystemResources,
                        .NOTDIR => |err| return errnoBug(err),
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    } else if (is_windows) {
        // TODO call NtQueryInformationFile and ask for only the size instead of "all"
    }

    const stat = try fileStat(t, file);
    return stat.size;
}

const fileStat = switch (native_os) {
    .linux => fileStatLinux,
    .windows => fileStatWindows,
    .wasi => fileStatWasi,
    else => fileStatPosix,
};

fn fileStatPosix(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (posix.Stat == void) return error.Streaming;

    try current_thread.beginSyscall();
    while (true) {
        var stat = std.mem.zeroes(posix.Stat);
        switch (posix.errno(fstat_sym(file.handle, &stat))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromPosix(&stat);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOMEM => return error.SystemResources,
                    .ACCES => return error.AccessDenied,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileStatLinux(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const linux = std.os.linux;
    const use_c = std.c.versionCheck(if (builtin.abi.isAndroid())
        .{ .major = 30, .minor = 0, .patch = 0 }
    else
        .{ .major = 2, .minor = 28, .patch = 0 });
    const sys = if (use_c) std.c else std.os.linux;

    try current_thread.beginSyscall();
    while (true) {
        var statx = std.mem.zeroes(linux.Statx);
        switch (sys.errno(sys.statx(file.handle, "", linux.AT.EMPTY_PATH, linux_statx_request, &statx))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromLinux(&statx);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .LOOP => |err| return errnoBug(err),
                    .NAMETOOLONG => |err| return errnoBug(err),
                    .NOENT => |err| return errnoBug(err),
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => |err| return errnoBug(err),
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileStatWindows(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.checkCancel();

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var info: windows.FILE.ALL_INFORMATION = undefined;
    const rc = windows.ntdll.NtQueryInformationFile(file.handle, &io_status_block, &info, @sizeOf(windows.FILE.ALL_INFORMATION), .All);
    switch (rc) {
        .SUCCESS => {},
        // Buffer overflow here indicates that there is more information available than was able to be stored in the buffer
        // size provided. This is treated as success because the type of variable-length information that this would be relevant for
        // (name, volume name, etc) we don't care about.
        .BUFFER_OVERFLOW => {},
        .INVALID_PARAMETER => |err| return windows.statusBug(err),
        .ACCESS_DENIED => return error.AccessDenied,
        else => return windows.unexpectedStatus(rc),
    }
    return .{
        .inode = info.InternalInformation.IndexNumber,
        .size = @as(u64, @bitCast(info.StandardInformation.EndOfFile)),
        .permissions = .default_file,
        .kind = if (info.BasicInformation.FileAttributes.REPARSE_POINT) reparse_point: {
            var tag_info: windows.FILE.ATTRIBUTE_TAG_INFO = undefined;
            const tag_rc = windows.ntdll.NtQueryInformationFile(file.handle, &io_status_block, &tag_info, @sizeOf(windows.FILE.ATTRIBUTE_TAG_INFO), .AttributeTag);
            switch (tag_rc) {
                .SUCCESS => {},
                // INFO_LENGTH_MISMATCH and ACCESS_DENIED are the only documented possible errors
                // https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/d295752f-ce89-4b98-8553-266d37c84f0e
                .INFO_LENGTH_MISMATCH => |err| return windows.statusBug(err),
                .ACCESS_DENIED => return error.AccessDenied,
                else => return windows.unexpectedStatus(rc),
            }
            if (tag_info.ReparseTag.IsSurrogate) break :reparse_point .sym_link;
            // Unknown reparse point
            break :reparse_point .unknown;
        } else if (info.BasicInformation.FileAttributes.DIRECTORY)
            .directory
        else
            .file,
        .atime = windows.fromSysTime(info.BasicInformation.LastAccessTime),
        .mtime = windows.fromSysTime(info.BasicInformation.LastWriteTime),
        .ctime = windows.fromSysTime(info.BasicInformation.ChangeTime),
        .nlink = 0,
    };
}

fn fileStatWasi(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    if (builtin.link_libc) return fileStatPosix(userdata, file);

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.beginSyscall();
    while (true) {
        var stat: std.os.wasi.filestat_t = undefined;
        switch (std.os.wasi.fd_filestat_get(file.handle, &stat)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return statFromWasi(&stat);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOMEM => return error.SystemResources,
                    .ACCES => return error.AccessDenied,
                    .NOTCAPABLE => return error.AccessDenied,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirAccess = switch (native_os) {
    .windows => dirAccessWindows,
    .wasi => dirAccessWasi,
    else => dirAccessPosix,
};

fn dirAccessPosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.AccessOptions,
) Dir.AccessError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const flags: u32 = @as(u32, if (!options.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0);

    const mode: u32 =
        @as(u32, if (options.read) posix.R_OK else 0) |
        @as(u32, if (options.write) posix.W_OK else 0) |
        @as(u32, if (options.execute) posix.X_OK else 0);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.faccessat(dir.handle, sub_path_posix, mode, flags))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .TXTBSY => return error.FileBusy,
                    .NOTDIR => return error.FileNotFound,
                    .NOENT => return error.FileNotFound,
                    .NAMETOOLONG => return error.NameTooLong,
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.InputOutput,
                    .NOMEM => return error.SystemResources,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirAccessWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.AccessOptions,
) Dir.AccessError!void {
    if (builtin.link_libc) return dirAccessPosix(userdata, dir, sub_path, options);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const wasi = std.os.wasi;
    const flags: wasi.lookupflags_t = .{
        .SYMLINK_FOLLOW = options.follow_symlinks,
    };
    var stat: wasi.filestat_t = undefined;

    try current_thread.beginSyscall();
    while (true) {
        switch (wasi.path_filestat_get(dir.handle, flags, sub_path.ptr, sub_path.len, &stat)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOMEM => return error.SystemResources,
                    .ACCES => return error.AccessDenied,
                    .FAULT => |err| return errnoBug(err),
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.FileNotFound,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }

    if (!options.read and !options.write and !options.execute)
        return;

    var directory: wasi.fdstat_t = undefined;
    if (wasi.fd_fdstat_get(dir.handle, &directory) != .SUCCESS)
        return error.AccessDenied;

    var rights: wasi.rights_t = .{};
    if (options.read) {
        if (stat.filetype == .DIRECTORY) {
            rights.FD_READDIR = true;
        } else {
            rights.FD_READ = true;
        }
    }
    if (options.write)
        rights.FD_WRITE = true;

    // No validation for execution.

    // https://github.com/ziglang/zig/issues/18882
    const rights_int: u64 = @bitCast(rights);
    const inheriting_int: u64 = @bitCast(directory.fs_rights_inheriting);
    if ((rights_int & inheriting_int) != rights_int)
        return error.AccessDenied;
}

fn dirAccessWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.AccessOptions,
) Dir.AccessError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.checkCancel();

    _ = options; // TODO

    const sub_path_w_array = try windows.sliceToPrefixedFileW(dir.handle, sub_path);
    const sub_path_w = sub_path_w_array.span();

    if (sub_path_w[0] == '.' and sub_path_w[1] == 0) return;
    if (sub_path_w[0] == '.' and sub_path_w[1] == '.' and sub_path_w[2] == 0) return;

    const path_len_bytes = std.math.cast(u16, std.mem.sliceTo(sub_path_w, 0).len * 2) orelse
        return error.NameTooLong;
    var nt_name: windows.UNICODE_STRING = .{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(sub_path_w.ptr),
    };
    var attr: windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else dir.handle,
        .Attributes = .{},
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var basic_info: windows.FILE.BASIC_INFORMATION = undefined;
    switch (windows.ntdll.NtQueryAttributesFile(&attr, &basic_info)) {
        .SUCCESS => return,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .OBJECT_NAME_INVALID => |err| return windows.statusBug(err),
        .INVALID_PARAMETER => |err| return windows.statusBug(err),
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_PATH_SYNTAX_BAD => |err| return windows.statusBug(err),
        else => |rc| return windows.unexpectedStatus(rc),
    }
}

const dirCreateFile = switch (native_os) {
    .windows => dirCreateFileWindows,
    .wasi => dirCreateFileWasi,
    else => dirCreateFilePosix,
};

fn dirCreateFilePosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.CreateFlags,
) File.OpenError!File {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    var os_flags: posix.O = .{
        .ACCMODE = if (flags.read) .RDWR else .WRONLY,
        .CREAT = true,
        .TRUNC = flags.truncate,
        .EXCL = flags.exclusive,
    };
    if (@hasField(posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;

    // Use the O locking flags if the os supports them to acquire the lock
    // atomically. Note that the NONBLOCK flag is removed after the openat()
    // call is successful.
    if (have_flock_open_flags) switch (flags.lock) {
        .none => {},
        .shared => {
            os_flags.SHLOCK = true;
            os_flags.NONBLOCK = flags.lock_nonblocking;
        },
        .exclusive => {
            os_flags.EXLOCK = true;
            os_flags.NONBLOCK = flags.lock_nonblocking;
        },
    };

    try current_thread.beginSyscall();
    const fd: posix.fd_t = while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, os_flags, flags.permissions.toMode());
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .FBIG => return error.FileTooBig,
                    .OVERFLOW => return error.FileTooBig,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .SRCH => return error.FileNotFound, // Linux when accessing procfs.
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .EXIST => return error.PathAlreadyExists,
                    .BUSY => return error.DeviceBusy,
                    .OPNOTSUPP => return error.FileLocksUnsupported,
                    .AGAIN => return error.WouldBlock,
                    .TXTBSY => return error.FileBusy,
                    .NXIO => return error.NoDevice,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    errdefer posix.close(fd);

    if (have_flock and !have_flock_open_flags and flags.lock != .none) {
        const lock_nonblocking: i32 = if (flags.lock_nonblocking) posix.LOCK.NB else 0;
        const lock_flags = switch (flags.lock) {
            .none => unreachable,
            .shared => posix.LOCK.SH | lock_nonblocking,
            .exclusive => posix.LOCK.EX | lock_nonblocking,
        };

        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.flock(fd, lock_flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => |err| return errnoBug(err), // invalid parameters
                        .NOLCK => return error.SystemResources,
                        .AGAIN => return error.WouldBlock,
                        .OPNOTSUPP => return error.FileLocksUnsupported,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (have_flock_open_flags and flags.lock_nonblocking) {
        try current_thread.beginSyscall();
        var fl_flags: usize = while (true) {
            const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break @intCast(rc);
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |err| {
                    current_thread.endSyscall();
                    return posix.unexpectedErrno(err);
                },
            }
        };

        fl_flags |= @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));

        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, fl_flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |err| {
                    current_thread.endSyscall();
                    return posix.unexpectedErrno(err);
                },
            }
        }
    }

    return .{ .handle = fd };
}

fn dirCreateFileWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.CreateFlags,
) File.OpenError!File {
    const w = windows;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.checkCancel();

    const sub_path_w_array = try w.sliceToPrefixedFileW(dir.handle, sub_path);
    const sub_path_w = sub_path_w_array.span();

    const handle = try w.OpenFile(sub_path_w, .{
        .dir = dir.handle,
        .access_mask = .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .GENERIC = .{
                .WRITE = true,
                .READ = flags.read,
            },
        },
        .creation = if (flags.exclusive)
            .CREATE
        else if (flags.truncate)
            .OVERWRITE_IF
        else
            .OPEN_IF,
    });
    errdefer w.CloseHandle(handle);

    var io_status_block: w.IO_STATUS_BLOCK = undefined;
    const exclusive = switch (flags.lock) {
        .none => return .{ .handle = handle },
        .shared => false,
        .exclusive => true,
    };
    const status = w.ntdll.NtLockFile(
        handle,
        null,
        null,
        null,
        &io_status_block,
        &windows_lock_range_off,
        &windows_lock_range_len,
        null,
        @intFromBool(flags.lock_nonblocking),
        @intFromBool(exclusive),
    );
    switch (status) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .LOCK_NOT_GRANTED => return error.WouldBlock,
        .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
        else => return windows.unexpectedStatus(status),
    }

    return .{ .handle = handle };
}

fn dirCreateFileWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.CreateFlags,
) File.OpenError!File {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const wasi = std.os.wasi;
    const lookup_flags: wasi.lookupflags_t = .{};
    const oflags: wasi.oflags_t = .{
        .CREAT = true,
        .TRUNC = flags.truncate,
        .EXCL = flags.exclusive,
    };
    const fdflags: wasi.fdflags_t = .{};
    const base: wasi.rights_t = .{
        .FD_READ = flags.read,
        .FD_WRITE = true,
        .FD_DATASYNC = true,
        .FD_SEEK = true,
        .FD_TELL = true,
        .FD_FDSTAT_SET_FLAGS = true,
        .FD_SYNC = true,
        .FD_ALLOCATE = true,
        .FD_ADVISE = true,
        .FD_FILESTAT_SET_TIMES = true,
        .FD_FILESTAT_SET_SIZE = true,
        .FD_FILESTAT_GET = true,
        // POLL_FD_READWRITE only grants extra rights if the corresponding FD_READ and/or
        // FD_WRITE is also set.
        .POLL_FD_READWRITE = true,
    };
    const inheriting: wasi.rights_t = .{};
    var fd: posix.fd_t = undefined;
    try current_thread.beginSyscall();
    while (true) {
        switch (wasi.path_open(dir.handle, lookup_flags, sub_path.ptr, sub_path.len, oflags, base, inheriting, fdflags, &fd)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return .{ .handle = fd };
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .FBIG => return error.FileTooBig,
                    .OVERFLOW => return error.FileTooBig,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .EXIST => return error.PathAlreadyExists,
                    .BUSY => return error.DeviceBusy,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirOpenFile = switch (native_os) {
    .windows => dirOpenFileWindows,
    .wasi => dirOpenFileWasi,
    else => dirOpenFilePosix,
};

fn dirOpenFilePosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.OpenFlags,
) File.OpenError!File {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    var os_flags: posix.O = switch (native_os) {
        .wasi => .{
            .read = flags.mode != .write_only,
            .write = flags.mode != .read_only,
            .NOFOLLOW = !flags.follow_symlinks,
        },
        else => .{
            .ACCMODE = switch (flags.mode) {
                .read_only => .RDONLY,
                .write_only => .WRONLY,
                .read_write => .RDWR,
            },
            .NOFOLLOW = !flags.follow_symlinks,
        },
    };
    if (@hasField(posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;
    if (@hasField(posix.O, "PATH") and flags.path_only) os_flags.PATH = true;

    // Use the O locking flags if the os supports them to acquire the lock
    // atomically. Note that the NONBLOCK flag is removed after the openat()
    // call is successful.
    if (have_flock_open_flags) switch (flags.lock) {
        .none => {},
        .shared => {
            os_flags.SHLOCK = true;
            os_flags.NONBLOCK = flags.lock_nonblocking;
        },
        .exclusive => {
            os_flags.EXLOCK = true;
            os_flags.NONBLOCK = flags.lock_nonblocking;
        },
    };

    try current_thread.beginSyscall();
    const fd: posix.fd_t = while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, os_flags, @as(posix.mode_t, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .FBIG => return error.FileTooBig,
                    .OVERFLOW => return error.FileTooBig,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .SRCH => return error.FileNotFound, // Linux when opening procfs files.
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .EXIST => return error.PathAlreadyExists,
                    .BUSY => return error.DeviceBusy,
                    .OPNOTSUPP => return error.FileLocksUnsupported,
                    .AGAIN => return error.WouldBlock,
                    .TXTBSY => return error.FileBusy,
                    .NXIO => return error.NoDevice,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    errdefer posix.close(fd);

    if (!flags.allow_directory) {
        const is_dir = is_dir: {
            const stat = fileStat(t, .{ .handle = fd }) catch |err| switch (err) {
                // The directory-ness is either unknown or unknowable
                error.Streaming => break :is_dir false,
                else => |e| return e,
            };
            break :is_dir stat.kind == .directory;
        };
        if (is_dir) return error.IsDir;
    }

    if (have_flock and !have_flock_open_flags and flags.lock != .none) {
        const lock_nonblocking: i32 = if (flags.lock_nonblocking) posix.LOCK.NB else 0;
        const lock_flags = switch (flags.lock) {
            .none => unreachable,
            .shared => posix.LOCK.SH | lock_nonblocking,
            .exclusive => posix.LOCK.EX | lock_nonblocking,
        };
        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.flock(fd, lock_flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => |err| return errnoBug(err), // invalid parameters
                        .NOLCK => return error.SystemResources,
                        .AGAIN => return error.WouldBlock,
                        .OPNOTSUPP => return error.FileLocksUnsupported,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (have_flock_open_flags and flags.lock_nonblocking) {
        try current_thread.beginSyscall();
        var fl_flags: usize = while (true) {
            const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break @intCast(rc);
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |err| {
                    current_thread.endSyscall();
                    return posix.unexpectedErrno(err);
                },
            }
        };

        fl_flags |= @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));

        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, fl_flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |err| {
                    current_thread.endSyscall();
                    return posix.unexpectedErrno(err);
                },
            }
        }
    }

    return .{ .handle = fd };
}

fn dirOpenFileWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.OpenFlags,
) File.OpenError!File {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const sub_path_w_array = try windows.sliceToPrefixedFileW(dir.handle, sub_path);
    const sub_path_w = sub_path_w_array.span();
    const dir_handle = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else dir.handle;
    return dirOpenFileWtf16(t, dir_handle, sub_path_w, flags);
}

pub fn dirOpenFileWtf16(
    t: *Threaded,
    dir_handle: ?windows.HANDLE,
    sub_path_w: [:0]const u16,
    flags: File.OpenFlags,
) File.OpenError!File {
    const allow_directory = flags.allow_directory and !flags.isWrite();
    if (!allow_directory and std.mem.eql(u16, sub_path_w, &.{'.'})) return error.IsDir;
    if (!allow_directory and std.mem.eql(u16, sub_path_w, &.{ '.', '.' })) return error.IsDir;
    const path_len_bytes = std.math.cast(u16, sub_path_w.len * 2) orelse return error.NameTooLong;
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    var nt_name: w.UNICODE_STRING = .{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(sub_path_w.ptr),
    };
    var attr: w.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
        .RootDirectory = dir_handle,
        .Attributes = .{},
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io_status_block: w.IO_STATUS_BLOCK = undefined;

    // There are multiple kernel bugs being worked around with retries.
    const max_attempts = 13;
    var attempt: u5 = 0;

    const handle = while (true) {
        try current_thread.checkCancel();

        var result: w.HANDLE = undefined;
        const rc = w.ntdll.NtCreateFile(
            &result,
            .{
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{
                    .READ = flags.isRead(),
                    .WRITE = flags.isWrite(),
                },
            },
            &attr,
            &io_status_block,
            null,
            .{ .NORMAL = true },
            .VALID_FLAGS,
            .OPEN,
            .{
                .IO = if (flags.follow_symlinks) .SYNCHRONOUS_NONALERT else .ASYNCHRONOUS,
                .NON_DIRECTORY_FILE = !allow_directory,
                .OPEN_REPARSE_POINT = !flags.follow_symlinks,
            },
            null,
            0,
        );
        switch (rc) {
            .SUCCESS => break result,
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .BAD_NETWORK_PATH => return error.NetworkNotFound, // \\server was not found
            .BAD_NETWORK_NAME => return error.NetworkNotFound, // \\server was found but \\server\share wasn't
            .NO_MEDIA_IN_DEVICE => return error.NoDevice,
            .INVALID_PARAMETER => |err| return w.statusBug(err),
            .SHARING_VIOLATION => {
                // This occurs if the file attempting to be opened is a running
                // executable. However, there's a kernel bug: the error may be
                // incorrectly returned for an indeterminate amount of time
                // after an executable file is closed. Here we work around the
                // kernel bug with retry attempts.
                if (max_attempts - attempt == 0) return error.SharingViolation;
                _ = w.kernel32.SleepEx((@as(u32, 1) << attempt) >> 1, w.TRUE);
                attempt += 1;
                continue;
            },
            .ACCESS_DENIED => return error.AccessDenied,
            .PIPE_BUSY => return error.PipeBusy,
            .PIPE_NOT_AVAILABLE => return error.NoDevice,
            .OBJECT_PATH_SYNTAX_BAD => |err| return w.statusBug(err),
            .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
            .FILE_IS_A_DIRECTORY => return error.IsDir,
            .NOT_A_DIRECTORY => return error.NotDir,
            .USER_MAPPED_FILE => return error.AccessDenied,
            .INVALID_HANDLE => |err| return w.statusBug(err),
            .DELETE_PENDING => {
                // This error means that there *was* a file in this location on
                // the file system, but it was deleted. However, the OS is not
                // finished with the deletion operation, and so this CreateFile
                // call has failed. Here, we simulate the kernel bug being
                // fixed by sleeping and retrying until the error goes away.
                if (max_attempts - attempt == 0) return error.SharingViolation;
                _ = w.kernel32.SleepEx((@as(u32, 1) << attempt) >> 1, w.TRUE);
                attempt += 1;
                continue;
            },
            .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
            else => return w.unexpectedStatus(rc),
        }
    };
    errdefer w.CloseHandle(handle);

    const exclusive = switch (flags.lock) {
        .none => return .{ .handle = handle },
        .shared => false,
        .exclusive => true,
    };
    const status = w.ntdll.NtLockFile(
        handle,
        null,
        null,
        null,
        &io_status_block,
        &windows_lock_range_off,
        &windows_lock_range_len,
        null,
        @intFromBool(flags.lock_nonblocking),
        @intFromBool(exclusive),
    );
    switch (status) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .LOCK_NOT_GRANTED => return error.WouldBlock,
        .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
        else => return windows.unexpectedStatus(status),
    }
    return .{ .handle = handle };
}

fn dirOpenFileWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: File.OpenFlags,
) File.OpenError!File {
    if (builtin.link_libc) return dirOpenFilePosix(userdata, dir, sub_path, flags);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const wasi = std.os.wasi;
    var base: std.os.wasi.rights_t = .{};
    // POLL_FD_READWRITE only grants extra rights if the corresponding FD_READ and/or FD_WRITE
    // is also set.
    if (flags.isRead()) {
        base.FD_READ = true;
        base.FD_TELL = true;
        base.FD_SEEK = true;
        base.FD_FILESTAT_GET = true;
        base.POLL_FD_READWRITE = true;
    }
    if (flags.isWrite()) {
        base.FD_WRITE = true;
        base.FD_TELL = true;
        base.FD_SEEK = true;
        base.FD_DATASYNC = true;
        base.FD_FDSTAT_SET_FLAGS = true;
        base.FD_SYNC = true;
        base.FD_ALLOCATE = true;
        base.FD_ADVISE = true;
        base.FD_FILESTAT_SET_TIMES = true;
        base.FD_FILESTAT_SET_SIZE = true;
        base.POLL_FD_READWRITE = true;
    }
    const lookup_flags: wasi.lookupflags_t = .{};
    const oflags: wasi.oflags_t = .{};
    const inheriting: wasi.rights_t = .{};
    const fdflags: wasi.fdflags_t = .{};
    var fd: posix.fd_t = undefined;
    try current_thread.beginSyscall();
    while (true) {
        switch (wasi.path_open(dir.handle, lookup_flags, sub_path.ptr, sub_path.len, oflags, base, inheriting, fdflags, &fd)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .FBIG => return error.FileTooBig,
                    .OVERFLOW => return error.FileTooBig,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.DeviceBusy,
                    .NOTCAPABLE => return error.AccessDenied,
                    .NAMETOOLONG => return error.NameTooLong,
                    .INVAL => return error.BadPathName,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
    errdefer posix.close(fd);

    if (!flags.allow_directory) {
        const is_dir = is_dir: {
            const stat = fileStat(t, .{ .handle = fd }) catch |err| switch (err) {
                // The directory-ness is either unknown or unknowable
                error.Streaming => break :is_dir false,
                else => |e| return e,
            };
            break :is_dir stat.kind == .directory;
        };
        if (is_dir) return error.IsDir;
    }

    return .{ .handle = fd };
}

const dirOpenDir = switch (native_os) {
    .wasi => dirOpenDirWasi,
    .haiku => dirOpenDirHaiku,
    else => dirOpenDirPosix,
};

/// This function is also used for WASI when libc is linked.
fn dirOpenDirPosix(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    const t: *Threaded = @ptrCast(@alignCast(userdata));

    if (is_windows) {
        const sub_path_w = try windows.sliceToPrefixedFileW(dir.handle, sub_path);
        return dirOpenDirWindows(t, dir, sub_path_w.span(), options);
    }

    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    var flags: posix.O = switch (native_os) {
        .wasi => .{
            .read = true,
            .NOFOLLOW = !options.follow_symlinks,
            .DIRECTORY = true,
        },
        else => .{
            .ACCMODE = .RDONLY,
            .NOFOLLOW = !options.follow_symlinks,
            .DIRECTORY = true,
            .CLOEXEC = true,
        },
    };

    if (@hasField(posix.O, "PATH") and !options.iterate)
        flags.PATH = true;

    try current_thread.beginSyscall();
    while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, flags, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return .{ .handle = @intCast(rc) };
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.DeviceBusy,
                    .NXIO => return error.NoDevice,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirOpenDirHaiku(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    _ = options;

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system._kern_open_dir(dir.handle, sub_path_posix);
        if (rc >= 0) {
            current_thread.endSyscall();
            return .{ .handle = rc };
        }
        switch (@as(posix.E, @enumFromInt(rc))) {
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.DeviceBusy,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

pub fn dirOpenDirWindows(
    t: *Io.Threaded,
    dir: Dir,
    sub_path_w: [:0]const u16,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    const path_len_bytes: u16 = @intCast(sub_path_w.len * 2);
    var nt_name: w.UNICODE_STRING = .{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(sub_path_w.ptr),
    };
    var io_status_block: w.IO_STATUS_BLOCK = undefined;
    var result: Dir = .{ .handle = undefined };
    try current_thread.checkCancel();
    const rc = w.ntdll.NtCreateFile(
        &result.handle,
        // TODO remove some of these flags if options.access_sub_paths is false
        .{
            .SPECIFIC = .{ .FILE_DIRECTORY = .{
                .LIST = options.iterate,
                .READ_EA = true,
                .TRAVERSE = true,
                .READ_ATTRIBUTES = true,
            } },
            .STANDARD = .{
                .RIGHTS = .READ,
                .SYNCHRONIZE = true,
            },
        },
        &.{
            .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else dir.handle,
            .Attributes = .{},
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        },
        &io_status_block,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{
            .DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
            .OPEN_FOR_BACKUP_INTENT = true,
            .OPEN_REPARSE_POINT = !options.follow_symlinks,
        },
        null,
        0,
    );

    switch (rc) {
        .SUCCESS => return result,
        .OBJECT_NAME_INVALID => return error.BadPathName,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_NAME_COLLISION => |err| return w.statusBug(err),
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_A_DIRECTORY => return error.NotDir,
        // This can happen if the directory has 'List folder contents' permission set to 'Deny'
        // and the directory is trying to be opened for iteration.
        .ACCESS_DENIED => return error.AccessDenied,
        .INVALID_PARAMETER => |err| return w.statusBug(err),
        else => return w.unexpectedStatus(rc),
    }
}

fn dirClose(userdata: ?*anyopaque, dirs: []const Dir) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    for (dirs) |dir| posix.close(dir.handle);
}

const dirRead = switch (native_os) {
    .linux => dirReadLinux,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => dirReadDarwin,
    .freebsd, .netbsd, .dragonfly, .openbsd => dirReadBsd,
    .illumos => dirReadIllumos,
    .haiku => dirReadHaiku,
    .windows => dirReadWindows,
    .wasi => dirReadWasi,
    else => dirReadUnimplemented,
};

fn dirReadLinux(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const linux = std.os.linux;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;
            if (dr.state == .reset) {
                posixSeekTo(current_thread, dr.dir.handle, 0) catch |err| switch (err) {
                    error.Unseekable => return error.Unexpected,
                    else => |e| return e,
                };
                dr.state = .reading;
            }
            try current_thread.beginSyscall();
            const n = while (true) {
                const rc = linux.getdents64(dr.dir.handle, dr.buffer.ptr, dr.buffer.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break rc;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability.
                            .FAULT => |err| return errnoBug(err),
                            .NOTDIR => |err| return errnoBug(err),
                            // To be consistent across platforms, iteration
                            // ends if the directory being iterated is deleted
                            // during iteration. This matches the behavior of
                            // non-Linux, non-WASI UNIX platforms.
                            .NOENT => {
                                dr.state = .finished;
                                return 0;
                            },
                            // This can occur when reading /proc/$PID/net, or
                            // if the provided buffer is too small. Neither
                            // scenario is intended to be handled by this API.
                            .INVAL => return error.Unexpected,
                            .ACCES => return error.AccessDenied, // Lacking permission to iterate this directory.
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            };
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = 0;
            dr.end = n;
        }
        // Linux aligns the header by padding after the null byte of the name
        // to align the next entry. This means we can find the end of the name
        // by looking at only the 8 bytes before the next record. However since
        // file names are usually short it's better to keep the machine code
        // simpler.
        //
        // Furthermore, I observed qemu user mode to not align this struct, so
        // this code makes the conservative choice to not assume alignment.
        const linux_entry: *align(1) linux.dirent64 = @ptrCast(&dr.buffer[dr.index]);
        const next_index = dr.index + linux_entry.reclen;
        dr.index = next_index;
        const name_ptr: [*]u8 = &linux_entry.name;
        const padded_name = name_ptr[0 .. linux_entry.reclen - @offsetOf(linux.dirent64, "name")];
        const name_len = std.mem.findScalar(u8, padded_name, 0).?;
        const name = name_ptr[0..name_len :0];

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const entry_kind: File.Kind = switch (linux_entry.type) {
            linux.DT.BLK => .block_device,
            linux.DT.CHR => .character_device,
            linux.DT.DIR => .directory,
            linux.DT.FIFO => .named_pipe,
            linux.DT.LNK => .sym_link,
            linux.DT.REG => .file,
            linux.DT.SOCK => .unix_domain_socket,
            else => .unknown,
        };
        buffer[buffer_index] = .{
            .name = name,
            .kind = entry_kind,
            .inode = linux_entry.ino,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirReadDarwin(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const Header = extern struct {
        seek: i64,
    };
    const header: *Header = @ptrCast(dr.buffer.ptr);
    const header_end: usize = @sizeOf(Header);
    if (dr.index < header_end) {
        // Initialize header.
        dr.index = header_end;
        dr.end = header_end;
        header.* = .{ .seek = 0 };
    }
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;
            if (dr.state == .reset) {
                posixSeekTo(current_thread, dr.dir.handle, 0) catch |err| switch (err) {
                    error.Unseekable => return error.Unexpected,
                    else => |e| return e,
                };
                dr.state = .reading;
            }
            const dents_buffer = dr.buffer[header_end..];
            try current_thread.beginSyscall();
            const n: usize = while (true) {
                const rc = posix.system.getdirentries(dr.dir.handle, dents_buffer.ptr, dents_buffer.len, &header.seek);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break @intCast(rc);
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability.
                            .FAULT => |err| return errnoBug(err),
                            .NOTDIR => |err| return errnoBug(err),
                            .INVAL => |err| return errnoBug(err),
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            };
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = header_end;
            dr.end = header_end + n;
        }
        const darwin_entry = @as(*align(1) posix.system.dirent, @ptrCast(&dr.buffer[dr.index]));
        const next_index = dr.index + darwin_entry.reclen;
        dr.index = next_index;

        const name = @as([*]u8, @ptrCast(&darwin_entry.name))[0..darwin_entry.namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or (darwin_entry.ino == 0))
            continue;

        const entry_kind: File.Kind = switch (darwin_entry.type) {
            posix.DT.BLK => .block_device,
            posix.DT.CHR => .character_device,
            posix.DT.DIR => .directory,
            posix.DT.FIFO => .named_pipe,
            posix.DT.LNK => .sym_link,
            posix.DT.REG => .file,
            posix.DT.SOCK => .unix_domain_socket,
            posix.DT.WHT => .whiteout,
            else => .unknown,
        };
        buffer[buffer_index] = .{
            .name = name,
            .kind = entry_kind,
            .inode = darwin_entry.ino,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirReadBsd(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;
            if (dr.state == .reset) {
                posixSeekTo(current_thread, dr.dir.handle, 0) catch |err| switch (err) {
                    error.Unseekable => return error.Unexpected,
                    else => |e| return e,
                };
                dr.state = .reading;
            }
            try current_thread.beginSyscall();
            const n: usize = while (true) {
                const rc = posix.system.getdents(dr.dir.handle, dr.buffer.ptr, dr.buffer.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break @intCast(rc);
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability
                            .FAULT => |err| return errnoBug(err),
                            .NOTDIR => |err| return errnoBug(err),
                            .INVAL => |err| return errnoBug(err),
                            // Introduced in freebsd 13.2: directory unlinked
                            // but still open. To be consistent, iteration ends
                            // if the directory being iterated is deleted
                            // during iteration.
                            .NOENT => {
                                dr.state = .finished;
                                return 0;
                            },
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            };
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = 0;
            dr.end = n;
        }
        const bsd_entry = @as(*align(1) posix.system.dirent, @ptrCast(&dr.buffer[dr.index]));
        const next_index = dr.index +
            if (@hasField(posix.system.dirent, "reclen")) bsd_entry.reclen else bsd_entry.reclen();
        dr.index = next_index;

        const name = @as([*]u8, @ptrCast(&bsd_entry.name))[0..bsd_entry.namlen];

        const skip_zero_fileno = switch (native_os) {
            // fileno=0 is used to mark invalid entries or deleted files.
            .openbsd, .netbsd => true,
            else => false,
        };
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            (skip_zero_fileno and bsd_entry.fileno == 0))
        {
            continue;
        }

        const entry_kind: File.Kind = switch (bsd_entry.type) {
            posix.DT.BLK => .block_device,
            posix.DT.CHR => .character_device,
            posix.DT.DIR => .directory,
            posix.DT.FIFO => .named_pipe,
            posix.DT.LNK => .sym_link,
            posix.DT.REG => .file,
            posix.DT.SOCK => .unix_domain_socket,
            posix.DT.WHT => .whiteout,
            else => .unknown,
        };
        buffer[buffer_index] = .{
            .name = name,
            .kind = entry_kind,
            .inode = bsd_entry.fileno,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirReadIllumos(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;
            if (dr.state == .reset) {
                posixSeekTo(current_thread, dr.dir.handle, 0) catch |err| switch (err) {
                    error.Unseekable => return error.Unexpected,
                    else => |e| return e,
                };
                dr.state = .reading;
            }
            try current_thread.beginSyscall();
            const n: usize = while (true) {
                const rc = posix.system.getdents(dr.dir.handle, dr.buffer.ptr, dr.buffer.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break rc;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability
                            .FAULT => |err| return errnoBug(err),
                            .NOTDIR => |err| return errnoBug(err),
                            .INVAL => |err| return errnoBug(err),
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            };
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = 0;
            dr.end = n;
        }
        const entry = @as(*align(1) posix.system.dirent, @ptrCast(&dr.buffer[dr.index]));
        const next_index = dr.index + entry.reclen;
        dr.index = next_index;

        const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&entry.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        // illumos dirent doesn't expose type, so we have to call stat to get it.
        const stat = try posixStatFile(current_thread, dr.dir.handle, name, posix.AT.SYMLINK_NOFOLLOW);

        buffer[buffer_index] = .{
            .name = name,
            .kind = stat.kind,
            .inode = entry.ino,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirReadHaiku(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    _ = userdata;
    _ = dr;
    _ = buffer;
    @panic("TODO implement dirReadHaiku");
}

fn dirReadWindows(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    // We want to be able to use the `dr.buffer` for both the NtQueryDirectoryFile call (which
    // returns WTF-16 names) *and* as a buffer for storing those WTF-16 names as WTF-8 to be able
    // to return them in `Dir.Entry.name`. However, the problem that needs to be overcome in order to do
    // that is that each WTF-16 code unit can be encoded as a maximum of 3 WTF-8 bytes, which means
    // that it's not guaranteed that the memory used for the WTF-16 name will be sufficient
    // for the WTF-8 encoding of the same name (for example, € is encoded as one WTF-16 code unit,
    // [2 bytes] but encoded in WTF-8 as 3 bytes).
    //
    // The approach taken here is to "reserve" enough space in the `dr.buffer` to ensure that
    // at least one entry with the maximum possible WTF-8 name length can be stored without clobbering
    // any entries that follow it. That is, we determine how much space is needed to allow that,
    // and then only provide the remaining portion of `dr.buffer` to the NtQueryDirectoryFile
    // call. The WTF-16 names can then be safely converted using the full `dr.buffer` slice, making
    // sure that each name can only potentially overwrite the data of its own entry.
    //
    // The worst case, where an entry's name is both the maximum length of a component and
    // made up entirely of code points that are encoded as one WTF-16 code unit/three WTF-8 bytes,
    // would therefore look like the diagram below, and only one entry would be able to be returned:
    //
    //     |   reserved  | remaining unreserved buffer |
    //                   | entry 1 | entry 2 |   ...   |
    //     | wtf-8 name of entry 1 |
    //
    // However, in the average case we will be able to store more than one WTF-8 name at a time in the
    // available buffer and therefore we will be able to populate more than one `Dir.Entry` at a time.
    // That might look something like this (where name 1, name 2, etc are the converted WTF-8 names):
    //
    //     |   reserved  | remaining unreserved buffer |
    //                   | entry 1 | entry 2 |   ...   |
    //     | name 1 | name 2 | name 3 | name 4 |  ...  |
    //
    // Note: More than the minimum amount of space could be reserved to make the "worst case"
    // less likely, but since the worst-case also requires a maximum length component to matter,
    // it's unlikely for it to become a problem in normal scenarios even if all names on the filesystem
    // are made up of non-ASCII characters that have the "one WTF-16 code unit <-> three WTF-8 bytes"
    // property (e.g. code points >= U+0800 and <= U+FFFF), as it's unlikely for a significant
    // number of components to be maximum length.

    // We need `3 * NAME_MAX` bytes to store a max-length component as WTF-8 safely.
    // Because needing to store a max-length component depends on a `FileName` *with* the maximum
    // component length, we know that the corresponding populated `FILE_BOTH_DIR_INFORMATION` will
    // be of size `@sizeOf(w.FILE_BOTH_DIR_INFORMATION) + 2 * NAME_MAX` bytes, so we only need to
    // reserve enough to get us to up to having `3 * NAME_MAX` bytes available when taking into account
    // that we have the ability to write over top of the reserved memory + the full footprint of that
    // particular `FILE_BOTH_DIR_INFORMATION`.
    const max_info_len = @sizeOf(w.FILE_BOTH_DIR_INFORMATION) + w.NAME_MAX * 2;
    const info_align = @alignOf(w.FILE_BOTH_DIR_INFORMATION);
    const reserve_needed = std.mem.alignForward(usize, Dir.max_name_bytes, info_align) - max_info_len;
    const unreserved_start = std.mem.alignForward(usize, reserve_needed, info_align);
    const unreserved_buffer = dr.buffer[unreserved_start..];
    // This is enforced by `Dir.Reader`
    assert(unreserved_buffer.len >= max_info_len);

    var name_index: usize = 0;
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;

            try current_thread.checkCancel();
            var io_status_block: w.IO_STATUS_BLOCK = undefined;
            const rc = w.ntdll.NtQueryDirectoryFile(
                dr.dir.handle,
                null,
                null,
                null,
                &io_status_block,
                unreserved_buffer.ptr,
                std.math.lossyCast(w.ULONG, unreserved_buffer.len),
                .BothDirectory,
                w.FALSE,
                null,
                @intFromBool(dr.state == .reset),
            );
            dr.state = .reading;
            if (io_status_block.Information == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = 0;
            dr.end = io_status_block.Information;
            switch (rc) {
                .SUCCESS => {},
                .ACCESS_DENIED => return error.AccessDenied, // Double-check that the Dir was opened with iteration ability
                else => return w.unexpectedStatus(rc),
            }
        }

        // While the official API docs guarantee FILE_BOTH_DIR_INFORMATION to be aligned properly
        // this may not always be the case (e.g. due to faulty VM/sandboxing tools)
        const dir_info: *align(2) w.FILE_BOTH_DIR_INFORMATION = @ptrCast(@alignCast(&unreserved_buffer[dr.index]));
        const backtrack_index = dr.index;
        if (dir_info.NextEntryOffset != 0) {
            dr.index += dir_info.NextEntryOffset;
        } else {
            dr.index = dr.end;
        }

        const name_wtf16le = @as([*]u16, @ptrCast(&dir_info.FileName))[0 .. dir_info.FileNameLength / 2];

        if (std.mem.eql(u16, name_wtf16le, &[_]u16{'.'}) or std.mem.eql(u16, name_wtf16le, &[_]u16{ '.', '.' })) {
            continue;
        }

        // Read any relevant information from the `dir_info` now since it's possible the WTF-8
        // name will overwrite it.
        const kind: File.Kind = blk: {
            const attrs = dir_info.FileAttributes;
            if (attrs.REPARSE_POINT) break :blk .sym_link;
            if (attrs.DIRECTORY) break :blk .directory;
            break :blk .file;
        };
        const inode: File.INode = dir_info.FileIndex;

        // If there's no more space for WTF-8 names without bleeding over into
        // the remaining unprocessed entries, then backtrack and return what we have so far.
        if (name_index + std.unicode.calcWtf8Len(name_wtf16le) > unreserved_start + dr.index) {
            // We should always be able to fit at least one entry into the buffer no matter what
            assert(buffer_index != 0);
            dr.index = backtrack_index;
            break;
        }

        const name_buf = dr.buffer[name_index..];
        const name_wtf8_len = std.unicode.wtf16LeToWtf8(name_buf, name_wtf16le);
        const name_wtf8 = name_buf[0..name_wtf8_len];
        name_index += name_wtf8_len;

        buffer[buffer_index] = .{
            .name = name_wtf8,
            .kind = kind,
            .inode = inode,
        };
        buffer_index += 1;
    }

    return buffer_index;
}

fn dirReadWasi(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    // We intentinally use fd_readdir even when linked with libc, since its
    // implementation is exactly the same as below, and we avoid the code
    // complexity here.
    const wasi = std.os.wasi;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const Header = extern struct {
        cookie: u64,
    };
    const header: *align(@alignOf(usize)) Header = @ptrCast(dr.buffer.ptr);
    const header_end: usize = @sizeOf(Header);
    if (dr.index < header_end) {
        // Initialize header.
        dr.index = header_end;
        dr.end = header_end;
        header.* = .{ .cookie = wasi.DIRCOOKIE_START };
    }
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        // According to the WASI spec, the last entry might be truncated, so we
        // need to check if the remaining buffer contains the whole dirent.
        if (dr.end - dr.index < @sizeOf(wasi.dirent_t)) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;
            if (dr.state == .reset) {
                header.* = .{ .cookie = wasi.DIRCOOKIE_START };
                dr.state = .reading;
            }
            const dents_buffer = dr.buffer[header_end..];
            var n: usize = undefined;
            try current_thread.beginSyscall();
            while (true) {
                switch (wasi.fd_readdir(dr.dir.handle, dents_buffer.ptr, dents_buffer.len, header.cookie, &n)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability.
                            .FAULT => |err| return errnoBug(err),
                            .NOTDIR => |err| return errnoBug(err),
                            .INVAL => |err| return errnoBug(err),
                            // To be consistent across platforms, iteration
                            // ends if the directory being iterated is deleted
                            // during iteration. This matches the behavior of
                            // non-Linux, non-WASI UNIX platforms.
                            .NOENT => {
                                dr.state = .finished;
                                return 0;
                            },
                            .NOTCAPABLE => return error.AccessDenied,
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            }
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = header_end;
            dr.end = header_end + n;
        }
        const entry: *align(1) wasi.dirent_t = @ptrCast(&dr.buffer[dr.index]);
        const entry_size = @sizeOf(wasi.dirent_t);
        const name_index = dr.index + entry_size;
        if (name_index + entry.namlen > dr.end) {
            // This case, the name is truncated, so we need to call readdir to store the entire name.
            dr.end = dr.index; // Force fd_readdir in the next loop.
            continue;
        }
        const name = dr.buffer[name_index..][0..entry.namlen];
        const next_index = name_index + entry.namlen;
        dr.index = next_index;
        header.cookie = entry.next;

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
            continue;

        const entry_kind: File.Kind = switch (entry.type) {
            .BLOCK_DEVICE => .block_device,
            .CHARACTER_DEVICE => .character_device,
            .DIRECTORY => .directory,
            .SYMBOLIC_LINK => .sym_link,
            .REGULAR_FILE => .file,
            .SOCKET_STREAM, .SOCKET_DGRAM => .unix_domain_socket,
            else => .unknown,
        };
        buffer[buffer_index] = .{
            .name = name,
            .kind = entry_kind,
            .inode = entry.ino,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirReadUnimplemented(userdata: ?*anyopaque, dir_reader: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    _ = userdata;
    _ = dir_reader;
    _ = buffer;
    return error.Unimplemented;
}

const dirRealPathFile = switch (native_os) {
    .windows => dirRealPathFileWindows,
    else => dirRealPathFilePosix,
};

fn dirRealPathFileWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.checkCancel();

    var path_name_w = try windows.sliceToPrefixedFileW(dir.handle, sub_path);

    const h_file = blk: {
        const res = windows.OpenFile(path_name_w.span(), .{
            .dir = dir.handle,
            .access_mask = .{
                .GENERIC = .{ .READ = true },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            .creation = .OPEN,
            .filter = .any,
        }) catch |err| switch (err) {
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
        break :blk res;
    };
    defer windows.CloseHandle(h_file);
    return realPathWindows(current_thread, h_file, out_buffer);
}

fn realPathWindows(current_thread: *Thread, h_file: windows.HANDLE, out_buffer: []u8) File.RealPathError!usize {
    _ = current_thread; // TODO move GetFinalPathNameByHandle logic into std.Io.Threaded and add cancel checks
    var wide_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const wide_slice = try windows.GetFinalPathNameByHandle(h_file, .{}, &wide_buf);

    const len = std.unicode.calcWtf8Len(wide_slice);
    if (len > out_buffer.len)
        return error.NameTooLong;

    return std.unicode.wtf16LeToWtf8(out_buffer, wide_slice);
}

fn dirRealPathFilePosix(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, out_buffer: []u8) Dir.RealPathFileError!usize {
    if (native_os == .wasi) return error.OperationUnsupported;

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    if (builtin.link_libc and dir.handle == posix.AT.FDCWD) {
        if (out_buffer.len < posix.PATH_MAX) return error.NameTooLong;
        try current_thread.beginSyscall();
        while (true) {
            if (std.c.realpath(sub_path_posix, out_buffer.ptr)) |redundant_pointer| {
                current_thread.endSyscall();
                assert(redundant_pointer == out_buffer.ptr);
                return std.mem.indexOfScalar(u8, out_buffer, 0) orelse out_buffer.len;
            }
            const err: posix.E = @enumFromInt(std.c._errno().*);
            if (err == .INTR) {
                try current_thread.checkCancel();
                continue;
            }
            current_thread.endSyscall();
            switch (err) {
                .INVAL => return errnoBug(err),
                .BADF => return errnoBug(err),
                .FAULT => return errnoBug(err),
                .ACCES => return error.AccessDenied,
                .NOENT => return error.FileNotFound,
                .OPNOTSUPP => return error.OperationUnsupported,
                .NOTDIR => return error.NotDir,
                .NAMETOOLONG => return error.NameTooLong,
                .LOOP => return error.SymLinkLoop,
                .IO => return error.InputOutput,
                else => return posix.unexpectedErrno(err),
            }
        }
    }

    var flags: posix.O = .{};
    if (@hasField(posix.O, "NONBLOCK")) flags.NONBLOCK = true;
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "PATH")) flags.PATH = true;

    const mode: posix.mode_t = 0;

    try current_thread.beginSyscall();
    const fd: posix.fd_t = while (true) {
        const rc = openat_sym(dir.handle, sub_path_posix, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .FBIG => return error.FileTooBig,
                    .OVERFLOW => return error.FileTooBig,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .SRCH => return error.FileNotFound, // Linux when accessing procfs.
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .EXIST => return error.PathAlreadyExists,
                    .BUSY => return error.DeviceBusy,
                    .NXIO => return error.NoDevice,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    defer posix.close(fd);
    return realPathPosix(current_thread, fd, out_buffer);
}

const dirRealPath = switch (native_os) {
    .windows => dirRealPathWindows,
    else => dirRealPathPosix,
};

fn dirRealPathPosix(userdata: ?*anyopaque, dir: Dir, out_buffer: []u8) Dir.RealPathError!usize {
    if (native_os == .wasi) return error.OperationUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return realPathPosix(current_thread, dir.handle, out_buffer);
}

fn dirRealPathWindows(userdata: ?*anyopaque, dir: Dir, out_buffer: []u8) Dir.RealPathError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return realPathWindows(current_thread, dir.handle, out_buffer);
}

const fileRealPath = switch (native_os) {
    .windows => fileRealPathWindows,
    else => fileRealPathPosix,
};

fn fileRealPathWindows(userdata: ?*anyopaque, file: File, out_buffer: []u8) File.RealPathError!usize {
    if (native_os == .wasi) return error.OperationUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return realPathWindows(current_thread, file.handle, out_buffer);
}

fn fileRealPathPosix(userdata: ?*anyopaque, file: File, out_buffer: []u8) File.RealPathError!usize {
    if (native_os == .wasi) return error.OperationUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return realPathPosix(current_thread, file.handle, out_buffer);
}

fn realPathPosix(current_thread: *Thread, fd: posix.fd_t, out_buffer: []u8) File.RealPathError!usize {
    switch (native_os) {
        .netbsd, .dragonfly, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            var sufficient_buffer: [posix.PATH_MAX]u8 = undefined;
            @memset(&sufficient_buffer, 0);
            try current_thread.beginSyscall();
            while (true) {
                switch (posix.errno(posix.system.fcntl(fd, posix.F.GETPATH, &sufficient_buffer))) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .ACCES => return error.AccessDenied,
                            .BADF => return error.FileNotFound,
                            .NOENT => return error.FileNotFound,
                            .NOMEM => return error.SystemResources,
                            .NOSPC => return error.NameTooLong,
                            .RANGE => return error.NameTooLong,
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            }
            const n = std.mem.indexOfScalar(u8, &sufficient_buffer, 0) orelse sufficient_buffer.len;
            if (n > out_buffer.len) return error.NameTooLong;
            @memcpy(out_buffer[0..n], sufficient_buffer[0..n]);
            return n;
        },
        .linux, .serenity, .illumos => {
            var procfs_buf: ["/proc/self/path/-2147483648\x00".len]u8 = undefined;
            const template = if (native_os == .illumos) "/proc/self/path/{d}" else "/proc/self/fd/{d}";
            const proc_path = std.fmt.bufPrintSentinel(&procfs_buf, template, .{fd}, 0) catch unreachable;
            try current_thread.beginSyscall();
            while (true) {
                const rc = posix.system.readlink(proc_path, out_buffer.ptr, out_buffer.len);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        const len: usize = @bitCast(rc);
                        return len;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .ACCES => return error.AccessDenied,
                            .FAULT => |err| return errnoBug(err),
                            .IO => return error.FileSystem,
                            .LOOP => return error.SymLinkLoop,
                            .NAMETOOLONG => return error.NameTooLong,
                            .NOENT => return error.FileNotFound,
                            .NOMEM => return error.SystemResources,
                            .NOTDIR => return error.NotDir,
                            .ILSEQ => |err| return errnoBug(err),
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            }
        },
        .freebsd => {
            var k_file: std.c.kinfo_file = undefined;
            k_file.structsize = std.c.KINFO_FILE_SIZE;
            try current_thread.beginSyscall();
            while (true) {
                switch (posix.errno(std.c.fcntl(fd, std.c.F.KINFO, @intFromPtr(&k_file)))) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        break;
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    .BADF => {
                        current_thread.endSyscall();
                        return error.FileNotFound;
                    },
                    else => |err| {
                        current_thread.endSyscall();
                        return posix.unexpectedErrno(err);
                    },
                }
            }
            const len = std.mem.findScalar(u8, &k_file.path, 0) orelse k_file.path.len;
            if (len == 0) return error.NameTooLong;
            @memcpy(out_buffer[0..len], k_file.path[0..len]);
            return len;
        },
        else => return error.OperationUnsupported,
    }
    comptime unreachable;
}

const dirDeleteFile = switch (native_os) {
    .windows => dirDeleteFileWindows,
    .wasi => dirDeleteFileWasi,
    else => dirDeleteFilePosix,
};

fn dirDeleteFileWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    return dirDeleteWindows(userdata, dir, sub_path, false) catch |err| switch (err) {
        error.DirNotEmpty => unreachable,
        else => |e| return e,
    };
}

fn dirDeleteFileWasi(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    if (builtin.link_libc) return dirDeleteFilePosix(userdata, dir, sub_path);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.beginSyscall();
    while (true) {
        const res = std.os.wasi.path_unlink_file(dir.handle, sub_path.ptr, sub_path.len);
        switch (res) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.FileBusy,
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.FileSystem,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirDeleteFilePosix(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.unlinkat(dir.handle, sub_path_posix, 0))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            // Some systems return permission errors when trying to delete a
            // directory, so we need to handle that case specifically and
            // translate the error.
            .PERM => switch (native_os) {
                .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd, .illumos => {

                    // Don't follow symlinks to match unlinkat (which acts on symlinks rather than follows them).
                    var st = std.mem.zeroes(posix.Stat);
                    while (true) {
                        try current_thread.checkCancel();
                        switch (posix.errno(fstatat_sym(dir.handle, sub_path_posix, &st, posix.AT.SYMLINK_NOFOLLOW))) {
                            .SUCCESS => {
                                current_thread.endSyscall();
                                break;
                            },
                            .INTR => continue,
                            else => {
                                current_thread.endSyscall();
                                return error.PermissionDenied;
                            },
                        }
                    }
                    const is_dir = st.mode & posix.S.IFMT == posix.S.IFDIR;
                    if (is_dir)
                        return error.IsDir
                    else
                        return error.PermissionDenied;
                },
                else => {
                    current_thread.endSyscall();
                    return error.PermissionDenied;
                },
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .BUSY => return error.FileBusy,
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.FileSystem,
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .EXIST => |err| return errnoBug(err),
                    .NOTEMPTY => |err| return errnoBug(err), // Not passing AT.REMOVEDIR
                    .ILSEQ => return error.BadPathName,
                    .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirDeleteDir = switch (native_os) {
    .windows => dirDeleteDirWindows,
    .wasi => dirDeleteDirWasi,
    else => dirDeleteDirPosix,
};

fn dirDeleteDirWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    return dirDeleteWindows(userdata, dir, sub_path, true) catch |err| switch (err) {
        error.IsDir => unreachable,
        else => |e| return e,
    };
}

fn dirDeleteWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, remove_dir: bool) (Dir.DeleteDirError || Dir.DeleteFileError)!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    try current_thread.checkCancel();

    const sub_path_w_buf = try w.sliceToPrefixedFileW(dir.handle, sub_path);
    const sub_path_w = sub_path_w_buf.span();

    const path_len_bytes = @as(u16, @intCast(sub_path_w.len * 2));
    var nt_name: w.UNICODE_STRING = .{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        // The Windows API makes this mutable, but it will not mutate here.
        .Buffer = @constCast(sub_path_w.ptr),
    };

    if (sub_path_w[0] == '.' and sub_path_w[1] == 0) {
        // Windows does not recognize this, but it does work with empty string.
        nt_name.Length = 0;
    }
    if (sub_path_w[0] == '.' and sub_path_w[1] == '.' and sub_path_w[2] == 0) {
        // Can't remove the parent directory with an open handle.
        return error.FileBusy;
    }

    var io_status_block: w.IO_STATUS_BLOCK = undefined;
    var tmp_handle: w.HANDLE = undefined;
    var rc = w.ntdll.NtCreateFile(
        &tmp_handle,
        .{ .STANDARD = .{
            .RIGHTS = .{ .DELETE = true },
            .SYNCHRONIZE = true,
        } },
        &.{
            .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sub_path_w)) null else dir.handle,
            .Attributes = .{},
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        },
        &io_status_block,
        null,
        .{},
        .VALID_FLAGS,
        .OPEN,
        .{
            .DIRECTORY_FILE = remove_dir,
            .NON_DIRECTORY_FILE = !remove_dir,
            .OPEN_REPARSE_POINT = true, // would we ever want to delete the target instead?
        },
        null,
        0,
    );
    switch (rc) {
        .SUCCESS => {},
        .OBJECT_NAME_INVALID => |err| return w.statusBug(err),
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .BAD_NETWORK_PATH => return error.NetworkNotFound, // \\server was not found
        .BAD_NETWORK_NAME => return error.NetworkNotFound, // \\server was found but \\server\share wasn't
        .INVALID_PARAMETER => |err| return w.statusBug(err),
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        .SHARING_VIOLATION => return error.FileBusy,
        .ACCESS_DENIED => return error.AccessDenied,
        .DELETE_PENDING => return,
        else => return w.unexpectedStatus(rc),
    }
    defer w.CloseHandle(tmp_handle);

    // FileDispositionInformationEx has varying levels of support:
    // - FILE_DISPOSITION_INFORMATION_EX requires >= win10_rs1
    //   (INVALID_INFO_CLASS is returned if not supported)
    // - Requires the NTFS filesystem
    //   (on filesystems like FAT32, INVALID_PARAMETER is returned)
    // - FILE_DISPOSITION_POSIX_SEMANTICS requires >= win10_rs1
    // - FILE_DISPOSITION_IGNORE_READONLY_ATTRIBUTE requires >= win10_rs5
    //   (NOT_SUPPORTED is returned if a flag is unsupported)
    //
    // The strategy here is just to try using FileDispositionInformationEx and fall back to
    // FileDispositionInformation if the return value lets us know that some aspect of it is not supported.
    const need_fallback = need_fallback: {
        try current_thread.checkCancel();

        // Deletion with posix semantics if the filesystem supports it.
        const info: w.FILE.DISPOSITION.INFORMATION.EX = .{ .Flags = .{
            .DELETE = true,
            .POSIX_SEMANTICS = true,
            .IGNORE_READONLY_ATTRIBUTE = true,
        } };

        rc = w.ntdll.NtSetInformationFile(
            tmp_handle,
            &io_status_block,
            &info,
            @sizeOf(w.FILE.DISPOSITION.INFORMATION.EX),
            .DispositionEx,
        );
        switch (rc) {
            .SUCCESS => return,
            // The filesystem does not support FileDispositionInformationEx
            .INVALID_PARAMETER,
            // The operating system does not support FileDispositionInformationEx
            .INVALID_INFO_CLASS,
            // The operating system does not support one of the flags
            .NOT_SUPPORTED,
            => break :need_fallback true,
            // For all other statuses, fall down to the switch below to handle them.
            else => break :need_fallback false,
        }
    };

    if (need_fallback) {
        try current_thread.checkCancel();

        // Deletion with file pending semantics, which requires waiting or moving
        // files to get them removed (from here).
        const file_dispo: w.FILE.DISPOSITION.INFORMATION = .{
            .DeleteFile = w.TRUE,
        };

        rc = w.ntdll.NtSetInformationFile(
            tmp_handle,
            &io_status_block,
            &file_dispo,
            @sizeOf(w.FILE.DISPOSITION.INFORMATION),
            .Disposition,
        );
    }
    switch (rc) {
        .SUCCESS => {},
        .DIRECTORY_NOT_EMPTY => return error.DirNotEmpty,
        .INVALID_PARAMETER => |err| return w.statusBug(err),
        .CANNOT_DELETE => return error.AccessDenied,
        .MEDIA_WRITE_PROTECTED => return error.AccessDenied,
        .ACCESS_DENIED => return error.AccessDenied,
        else => return w.unexpectedStatus(rc),
    }
}

fn dirDeleteDirWasi(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    if (builtin.link_libc) return dirDeleteDirPosix(userdata, dir, sub_path);

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.beginSyscall();
    while (true) {
        const res = std.os.wasi.path_remove_directory(dir.handle, sub_path.ptr, sub_path.len);
        switch (res) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.FileBusy,
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .NOTEMPTY => return error.DirNotEmpty,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirDeleteDirPosix(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.unlinkat(dir.handle, sub_path_posix, posix.AT.REMOVEDIR))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.FileBusy,
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.FileSystem,
                    .ISDIR => |err| return errnoBug(err),
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .EXIST => |err| return errnoBug(err),
                    .NOTEMPTY => return error.DirNotEmpty,
                    .ILSEQ => return error.BadPathName,
                    .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirRename = switch (native_os) {
    .windows => dirRenameWindows,
    .wasi => dirRenameWasi,
    else => dirRenamePosix,
};

fn dirRenameWindows(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    const w = windows;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const old_path_w_buf = try windows.sliceToPrefixedFileW(old_dir.handle, old_sub_path);
    const old_path_w = old_path_w_buf.span();
    const new_path_w_buf = try windows.sliceToPrefixedFileW(new_dir.handle, new_sub_path);
    const new_path_w = new_path_w_buf.span();
    const replace_if_exists = true;

    try current_thread.checkCancel();

    const src_fd = w.OpenFile(old_path_w, .{
        .dir = old_dir.handle,
        .access_mask = .{
            .GENERIC = .{ .WRITE = true },
            .STANDARD = .{
                .RIGHTS = .{ .DELETE = true },
                .SYNCHRONIZE = true,
            },
        },
        .creation = .OPEN,
        .filter = .any, // This function is supposed to rename both files and directories.
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.WouldBlock => unreachable, // Not possible without `.share_access_nonblocking = true`.
        else => |e| return e,
    };
    defer w.CloseHandle(src_fd);

    var rc: w.NTSTATUS = undefined;
    // FileRenameInformationEx has varying levels of support:
    // - FILE_RENAME_INFORMATION_EX requires >= win10_rs1
    //   (INVALID_INFO_CLASS is returned if not supported)
    // - Requires the NTFS filesystem
    //   (on filesystems like FAT32, INVALID_PARAMETER is returned)
    // - FILE_RENAME_POSIX_SEMANTICS requires >= win10_rs1
    // - FILE_RENAME_IGNORE_READONLY_ATTRIBUTE requires >= win10_rs5
    //   (NOT_SUPPORTED is returned if a flag is unsupported)
    //
    // The strategy here is just to try using FileRenameInformationEx and fall back to
    // FileRenameInformation if the return value lets us know that some aspect of it is not supported.
    const need_fallback = need_fallback: {
        const rename_info: w.FILE.RENAME_INFORMATION = .init(.{
            .Flags = .{
                .REPLACE_IF_EXISTS = replace_if_exists,
                .POSIX_SEMANTICS = true,
                .IGNORE_READONLY_ATTRIBUTE = true,
            },
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(new_path_w)) null else new_dir.handle,
            .FileName = new_path_w,
        });
        var io_status_block: w.IO_STATUS_BLOCK = undefined;
        const rename_info_buf = rename_info.toBuffer();
        rc = w.ntdll.NtSetInformationFile(
            src_fd,
            &io_status_block,
            rename_info_buf.ptr,
            @intCast(rename_info_buf.len),
            .RenameEx,
        );
        switch (rc) {
            .SUCCESS => return,
            // The filesystem does not support FileDispositionInformationEx
            .INVALID_PARAMETER,
            // The operating system does not support FileDispositionInformationEx
            .INVALID_INFO_CLASS,
            // The operating system does not support one of the flags
            .NOT_SUPPORTED,
            => break :need_fallback true,
            // For all other statuses, fall down to the switch below to handle them.
            else => break :need_fallback false,
        }
    };

    if (need_fallback) {
        const rename_info: w.FILE.RENAME_INFORMATION = .init(.{
            .Flags = .{ .REPLACE_IF_EXISTS = replace_if_exists },
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(new_path_w)) null else new_dir.handle,
            .FileName = new_path_w,
        });
        var io_status_block: w.IO_STATUS_BLOCK = undefined;
        const rename_info_buf = rename_info.toBuffer();
        rc = w.ntdll.NtSetInformationFile(
            src_fd,
            &io_status_block,
            rename_info_buf.ptr,
            @intCast(rename_info_buf.len),
            .Rename,
        );
    }

    switch (rc) {
        .SUCCESS => {},
        .INVALID_HANDLE => |err| return w.statusBug(err),
        .INVALID_PARAMETER => |err| return w.statusBug(err),
        .OBJECT_PATH_SYNTAX_BAD => |err| return w.statusBug(err),
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_SAME_DEVICE => return error.RenameAcrossMountPoints,
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .DIRECTORY_NOT_EMPTY => return error.PathAlreadyExists,
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        else => return w.unexpectedStatus(rc),
    }
}

fn dirRenameWasi(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    if (builtin.link_libc) return dirRenamePosix(userdata, old_dir, old_sub_path, new_dir, new_sub_path);

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.wasi.path_rename(old_dir.handle, old_sub_path.ptr, old_sub_path.len, new_dir.handle, new_sub_path.ptr, new_sub_path.len)) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.FileBusy,
                    .DQUOT => return error.DiskQuota,
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MLINK => return error.LinkQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .EXIST => return error.PathAlreadyExists,
                    .NOTEMPTY => return error.PathAlreadyExists,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .XDEV => return error.RenameAcrossMountPoints,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirRenamePosix(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var old_path_buffer: [posix.PATH_MAX]u8 = undefined;
    var new_path_buffer: [posix.PATH_MAX]u8 = undefined;

    const old_sub_path_posix = try pathToPosix(old_sub_path, &old_path_buffer);
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.renameat(old_dir.handle, old_sub_path_posix, new_dir.handle, new_sub_path_posix))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.FileBusy,
                    .DQUOT => return error.DiskQuota,
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ISDIR => return error.IsDir,
                    .LOOP => return error.SymLinkLoop,
                    .MLINK => return error.LinkQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .EXIST => return error.PathAlreadyExists,
                    .NOTEMPTY => return error.PathAlreadyExists,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .XDEV => return error.RenameAcrossMountPoints,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirSymLink = switch (native_os) {
    .windows => dirSymLinkWindows,
    .wasi => dirSymLinkWasi,
    else => dirSymLinkPosix,
};

fn dirSymLinkWindows(
    userdata: ?*anyopaque,
    dir: Dir,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: Dir.SymLinkFlags,
) Dir.SymLinkError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    try current_thread.checkCancel();

    // Target path does not use sliceToPrefixedFileW because certain paths
    // are handled differently when creating a symlink than they would be
    // when converting to an NT namespaced path. CreateSymbolicLink in
    // symLinkW will handle the necessary conversion.
    var target_path_w: w.PathSpace = undefined;
    target_path_w.len = try w.wtf8ToWtf16Le(&target_path_w.data, target_path);
    target_path_w.data[target_path_w.len] = 0;
    // However, we need to canonicalize any path separators to `\`, since if
    // the target path is relative, then it must use `\` as the path separator.
    std.mem.replaceScalar(
        u16,
        target_path_w.data[0..target_path_w.len],
        std.mem.nativeToLittle(u16, '/'),
        std.mem.nativeToLittle(u16, '\\'),
    );

    const sym_link_path_w = try w.sliceToPrefixedFileW(dir.handle, sym_link_path);

    const SYMLINK_DATA = extern struct {
        ReparseTag: w.IO_REPARSE_TAG,
        ReparseDataLength: w.USHORT,
        Reserved: w.USHORT,
        SubstituteNameOffset: w.USHORT,
        SubstituteNameLength: w.USHORT,
        PrintNameOffset: w.USHORT,
        PrintNameLength: w.USHORT,
        Flags: w.ULONG,
    };

    const symlink_handle = w.OpenFile(sym_link_path_w.span(), .{
        .access_mask = .{
            .GENERIC = .{ .READ = true, .WRITE = true },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        .dir = dir.handle,
        .creation = .CREATE,
        .filter = if (flags.is_directory) .dir_only else .non_directory_only,
    }) catch |err| switch (err) {
        error.IsDir => return error.PathAlreadyExists,
        error.NotDir => return error.Unexpected,
        error.WouldBlock => return error.Unexpected,
        error.PipeBusy => return error.Unexpected,
        error.NoDevice => return error.Unexpected,
        error.AntivirusInterference => return error.Unexpected,
        else => |e| return e,
    };
    defer w.CloseHandle(symlink_handle);

    // Relevant portions of the documentation:
    // > Relative links are specified using the following conventions:
    // > - Root relative—for example, "\Windows\System32" resolves to "current drive:\Windows\System32".
    // > - Current working directory–relative—for example, if the current working directory is
    // >   C:\Windows\System32, "C:File.txt" resolves to "C:\Windows\System32\File.txt".
    // > Note: If you specify a current working directory–relative link, it is created as an absolute
    // > link, due to the way the current working directory is processed based on the user and the thread.
    // https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsymboliclinkw
    var is_target_absolute = false;
    const final_target_path = target_path: {
        if (w.hasCommonNtPrefix(u16, target_path_w.span())) {
            // Already an NT path, no need to do anything to it
            break :target_path target_path_w.span();
        } else {
            switch (w.getWin32PathType(u16, target_path_w.span())) {
                // Rooted paths need to avoid getting put through wToPrefixedFileW
                // (and they are treated as relative in this context)
                // Note: It seems that rooted paths in symbolic links are relative to
                //       the drive that the symbolic exists on, not to the CWD's drive.
                //       So, if the symlink is on C:\ and the CWD is on D:\,
                //       it will still resolve the path relative to the root of
                //       the C:\ drive.
                .rooted => break :target_path target_path_w.span(),
                // Keep relative paths relative, but anything else needs to get NT-prefixed.
                else => if (!std.fs.path.isAbsoluteWindowsWtf16(target_path_w.span()))
                    break :target_path target_path_w.span(),
            }
        }
        var prefixed_target_path = try w.wToPrefixedFileW(dir.handle, target_path_w.span());
        // We do this after prefixing to ensure that drive-relative paths are treated as absolute
        is_target_absolute = std.fs.path.isAbsoluteWindowsWtf16(prefixed_target_path.span());
        break :target_path prefixed_target_path.span();
    };

    // prepare reparse data buffer
    var buffer: [w.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 = undefined;
    const buf_len = @sizeOf(SYMLINK_DATA) + final_target_path.len * 4;
    const header_len = @sizeOf(w.ULONG) + @sizeOf(w.USHORT) * 2;
    const target_is_absolute = std.fs.path.isAbsoluteWindowsWtf16(final_target_path);
    const symlink_data = SYMLINK_DATA{
        .ReparseTag = .SYMLINK,
        .ReparseDataLength = @intCast(buf_len - header_len),
        .Reserved = 0,
        .SubstituteNameOffset = @intCast(final_target_path.len * 2),
        .SubstituteNameLength = @intCast(final_target_path.len * 2),
        .PrintNameOffset = 0,
        .PrintNameLength = @intCast(final_target_path.len * 2),
        .Flags = if (!target_is_absolute) w.SYMLINK_FLAG_RELATIVE else 0,
    };

    @memcpy(buffer[0..@sizeOf(SYMLINK_DATA)], std.mem.asBytes(&symlink_data));
    @memcpy(buffer[@sizeOf(SYMLINK_DATA)..][0 .. final_target_path.len * 2], @as([*]const u8, @ptrCast(final_target_path)));
    const paths_start = @sizeOf(SYMLINK_DATA) + final_target_path.len * 2;
    @memcpy(buffer[paths_start..][0 .. final_target_path.len * 2], @as([*]const u8, @ptrCast(final_target_path)));
    const rc = w.DeviceIoControl(symlink_handle, w.FSCTL.SET_REPARSE_POINT, .{ .in = buffer[0..buf_len] });
    switch (rc) {
        .SUCCESS => {},
        .PRIVILEGE_NOT_HELD => return error.PermissionDenied,
        .ACCESS_DENIED => return error.AccessDenied,
        .INVALID_DEVICE_REQUEST => return error.FileSystem,
        else => return windows.unexpectedStatus(rc),
    }
}

fn dirSymLinkWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: Dir.SymLinkFlags,
) Dir.SymLinkError!void {
    if (builtin.link_libc) return dirSymLinkPosix(userdata, dir, target_path, sym_link_path, flags);

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.wasi.path_symlink(target_path.ptr, target_path.len, dir.handle, sym_link_path.ptr, sym_link_path.len)) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .DQUOT => return error.DiskQuota,
                    .EXIST => return error.PathAlreadyExists,
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirSymLinkPosix(
    userdata: ?*anyopaque,
    dir: Dir,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: Dir.SymLinkFlags,
) Dir.SymLinkError!void {
    _ = flags;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var target_path_buffer: [posix.PATH_MAX]u8 = undefined;
    var sym_link_path_buffer: [posix.PATH_MAX]u8 = undefined;

    const target_path_posix = try pathToPosix(target_path, &target_path_buffer);
    const sym_link_path_posix = try pathToPosix(sym_link_path, &sym_link_path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.symlinkat(target_path_posix, dir.handle, sym_link_path_posix))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .DQUOT => return error.DiskQuota,
                    .EXIST => return error.PathAlreadyExists,
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirReadLink = switch (native_os) {
    .windows => dirReadLinkWindows,
    .wasi => dirReadLinkWasi,
    else => dirReadLinkPosix,
};

fn dirReadLinkWindows(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const w = windows;

    try current_thread.checkCancel();

    var sub_path_w_buf = try windows.sliceToPrefixedFileW(dir.handle, sub_path);

    const result_w = try w.ReadLink(dir.handle, sub_path_w_buf.span(), &sub_path_w_buf.data);

    const len = std.unicode.calcWtf8Len(result_w);
    if (len > buffer.len) return error.NameTooLong;

    return std.unicode.wtf16LeToWtf8(buffer, result_w);
}

fn dirReadLinkWasi(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize {
    if (builtin.link_libc) return dirReadLinkPosix(userdata, dir, sub_path, buffer);

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var n: usize = undefined;
    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.wasi.path_readlink(dir.handle, sub_path.ptr, sub_path.len, buffer.ptr, buffer.len, &n)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return n;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.NotLink,
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirReadLinkPosix(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var sub_path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &sub_path_buffer);

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.readlinkat(dir.handle, sub_path_posix, buffer.ptr, buffer.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                const len: usize = @bitCast(rc);
                return len;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.NotLink,
                    .IO => return error.FileSystem,
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirSetPermissions = switch (native_os) {
    .windows => dirSetPermissionsWindows,
    else => dirSetPermissionsPosix,
};

fn dirSetPermissionsWindows(userdata: ?*anyopaque, dir: Dir, permissions: Dir.Permissions) Dir.SetPermissionsError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    _ = dir;
    _ = permissions;
    @panic("TODO implement dirSetPermissionsWindows");
}

fn dirSetPermissionsPosix(userdata: ?*anyopaque, dir: Dir, permissions: Dir.Permissions) Dir.SetPermissionsError!void {
    if (@sizeOf(Dir.Permissions) == 0) return;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return setPermissionsPosix(current_thread, dir.handle, permissions.toMode());
}

fn dirSetFilePermissions(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.SetFilePermissionsOptions,
) Dir.SetFilePermissionsError!void {
    if (@sizeOf(Dir.Permissions) == 0) return;
    if (is_windows) @panic("TODO implement dirSetFilePermissions windows");
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const mode = permissions.toMode();
    const flags: u32 = if (!options.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    return posixFchmodat(t, current_thread, dir.handle, sub_path_posix, mode, flags);
}

fn posixFchmodat(
    t: *Threaded,
    current_thread: *Thread,
    dir_fd: posix.fd_t,
    path: [*:0]const u8,
    mode: posix.mode_t,
    flags: u32,
) Dir.SetFilePermissionsError!void {
    // No special handling for linux is needed if we can use the libc fallback
    // or `flags` is empty. Glibc only added the fallback in 2.32.
    if (have_fchmodat_flags or flags == 0) {
        try current_thread.beginSyscall();
        while (true) {
            const rc = if (have_fchmodat_flags or builtin.link_libc)
                posix.system.fchmodat(dir_fd, path, mode, flags)
            else
                posix.system.fchmodat(dir_fd, path, mode);
            switch (posix.errno(rc)) {
                .SUCCESS => return current_thread.endSyscall(),
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .INVAL => |err| return errnoBug(err),
                        .ACCES => return error.AccessDenied,
                        .IO => return error.InputOutput,
                        .LOOP => return error.SymLinkLoop,
                        .MFILE => return error.ProcessFdQuotaExceeded,
                        .NAMETOOLONG => return error.NameTooLong,
                        .NFILE => return error.SystemFdQuotaExceeded,
                        .NOENT => return error.FileNotFound,
                        .NOTDIR => return error.FileNotFound,
                        .NOMEM => return error.SystemResources,
                        .OPNOTSUPP => return error.OperationUnsupported,
                        .PERM => return error.PermissionDenied,
                        .ROFS => return error.ReadOnlyFileSystem,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (@atomicLoad(UseFchmodat2, &t.use_fchmodat2, .monotonic) == .disabled)
        return fchmodatFallback(current_thread, dir_fd, path, mode);

    comptime assert(native_os == .linux);

    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.linux.errno(std.os.linux.fchmodat2(dir_fd, path, mode, flags))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .IO => return error.InputOutput,
                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.FileNotFound,
                    .OPNOTSUPP => return error.OperationUnsupported,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .NOSYS => {
                        @atomicStore(UseFchmodat2, &t.use_fchmodat2, .disabled, .monotonic);
                        return fchmodatFallback(current_thread, dir_fd, path, mode);
                    },
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fchmodatFallback(
    current_thread: *Thread,
    dir_fd: posix.fd_t,
    path: [*:0]const u8,
    mode: posix.mode_t,
) Dir.SetFilePermissionsError!void {
    comptime assert(native_os == .linux);
    const use_c = std.c.versionCheck(if (builtin.abi.isAndroid())
        .{ .major = 30, .minor = 0, .patch = 0 }
    else
        .{ .major = 2, .minor = 28, .patch = 0 });
    const sys = if (use_c) std.c else std.os.linux;

    // Fallback to changing permissions using procfs:
    //
    // 1. Open `path` as a `PATH` descriptor.
    // 2. Stat the fd and check if it isn't a symbolic link.
    // 3. Generate the procfs reference to the fd via `/proc/self/fd/{fd}`.
    // 4. Pass the procfs path to `chmod` with the `mode`.
    try current_thread.beginSyscall();
    const path_fd: posix.fd_t = while (true) {
        const rc = posix.system.openat(dir_fd, path, .{
            .PATH = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, @as(posix.mode_t, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                break @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .PERM => return error.PermissionDenied,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    defer posix.close(path_fd);

    try current_thread.beginSyscall();
    const path_mode = while (true) {
        var statx = std.mem.zeroes(std.os.linux.Statx);
        switch (sys.errno(sys.statx(path_fd, "", posix.AT.EMPTY_PATH, .{ .TYPE = true }, &statx))) {
            .SUCCESS => {
                current_thread.endSyscall();
                if (!statx.mask.TYPE) return error.Unexpected;
                break statx.mode;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .LOOP => return error.SymLinkLoop,
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };

    // Even though we only wanted TYPE, the kernel can still fill in the additional bits.
    if ((path_mode & posix.S.IFMT) == posix.S.IFLNK)
        return error.OperationUnsupported;

    var procfs_buf: ["/proc/self/fd/-2147483648\x00".len]u8 = undefined;
    const proc_path = std.fmt.bufPrintSentinel(&procfs_buf, "/proc/self/fd/{d}", .{path_fd}, 0) catch unreachable;
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.chmod(proc_path, mode))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .NOENT => return error.OperationUnsupported, // procfs not mounted.
                    .BADF => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .IO => return error.InputOutput,
                    .LOOP => return error.SymLinkLoop,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.FileNotFound,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const dirSetOwner = switch (native_os) {
    .windows => dirSetOwnerUnsupported,
    else => dirSetOwnerPosix,
};

fn dirSetOwnerUnsupported(userdata: ?*anyopaque, dir: Dir, owner: ?File.Uid, group: ?File.Gid) Dir.SetOwnerError!void {
    _ = userdata;
    _ = dir;
    _ = owner;
    _ = group;
    return error.Unexpected;
}

fn dirSetOwnerPosix(userdata: ?*anyopaque, dir: Dir, owner: ?File.Uid, group: ?File.Gid) Dir.SetOwnerError!void {
    if (!have_fchown) return error.Unexpected; // Unsupported OS, don't call this function.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const uid = owner orelse ~@as(posix.uid_t, 0);
    const gid = group orelse ~@as(posix.gid_t, 0);
    return posixFchown(current_thread, dir.handle, uid, gid);
}

fn posixFchown(current_thread: *Thread, fd: posix.fd_t, uid: posix.uid_t, gid: posix.gid_t) File.SetOwnerError!void {
    comptime assert(have_fchown);
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.fchown(fd, uid, gid))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err), // likely fd refers to directory opened without `Dir.OpenOptions.iterate`
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .IO => return error.InputOutput,
                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.FileNotFound,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirSetFileOwner(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    owner: ?File.Uid,
    group: ?File.Gid,
    options: Dir.SetFileOwnerOptions,
) Dir.SetFileOwnerError!void {
    if (!have_fchown) return error.Unexpected; // Unsupported OS, don't call this function.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    _ = current_thread;
    _ = dir;
    _ = sub_path_posix;
    _ = owner;
    _ = group;
    _ = options;
    @panic("TODO implement dirSetFileOwner");
}

const fileSync = switch (native_os) {
    .windows => fileSyncWindows,
    .wasi => fileSyncWasi,
    else => fileSyncPosix,
};

fn fileSyncWindows(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    try current_thread.checkCancel();

    if (windows.kernel32.FlushFileBuffers(file.handle) != 0)
        return;

    switch (windows.GetLastError()) {
        .SUCCESS => return,
        .INVALID_HANDLE => unreachable,
        .ACCESS_DENIED => return error.AccessDenied, // a sync was performed but the system couldn't update the access time
        .UNEXP_NET_ERR => return error.InputOutput,
        else => |err| return windows.unexpectedError(err),
    }
}

fn fileSyncPosix(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.fsync(file.handle))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ROFS => |err| return errnoBug(err),
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .DQUOT => return error.DiskQuota,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileSyncWasi(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.wasi.fd_sync(file.handle)) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ROFS => |err| return errnoBug(err),
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .DQUOT => return error.DiskQuota,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileIsTty(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return isTty(current_thread, file);
}

fn isTty(current_thread: *Thread, file: File) Io.Cancelable!bool {
    if (is_windows) {
        if (try isCygwinPty(current_thread, file)) return true;
        try current_thread.checkCancel();
        var out: windows.DWORD = undefined;
        return windows.kernel32.GetConsoleMode(file.handle, &out) != 0;
    }

    if (builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            const rc = posix.system.isatty(file.handle);
            switch (posix.errno(rc - 1)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return true;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => {
                    current_thread.endSyscall();
                    return false;
                },
            }
        }
    }

    if (native_os == .wasi) {
        var statbuf: std.os.wasi.fdstat_t = undefined;
        const err = std.os.wasi.fd_fdstat_get(file.handle, &statbuf);
        if (err != .SUCCESS)
            return false;

        // A tty is a character device that we can't seek or tell on.
        if (statbuf.fs_filetype != .CHARACTER_DEVICE)
            return false;
        if (statbuf.fs_rights_base.FD_SEEK or statbuf.fs_rights_base.FD_TELL)
            return false;

        return true;
    }

    if (native_os == .linux) {
        const linux = std.os.linux;
        try current_thread.beginSyscall();
        while (true) {
            var wsz: posix.winsize = undefined;
            const fd: usize = @bitCast(@as(isize, file.handle));
            const rc = linux.syscall3(.ioctl, fd, linux.T.IOCGWINSZ, @intFromPtr(&wsz));
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return true;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => {
                    current_thread.endSyscall();
                    return false;
                },
            }
        }
    }

    @compileError("unimplemented");
}

fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: File) File.EnableAnsiEscapeCodesError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        try current_thread.checkCancel();

        // For Windows Terminal, VT Sequences processing is enabled by default.
        var original_console_mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(file.handle, &original_console_mode) != 0) {
            if (original_console_mode & windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0) return;

            // For Windows Console, VT Sequences processing support was added in Windows 10 build 14361, but disabled by default.
            // https://devblogs.microsoft.com/commandline/tmux-support-arrives-for-bash-on-ubuntu-on-windows/
            //
            // Note: In Microsoft's example for enabling virtual terminal processing, it
            // shows attempting to enable `DISABLE_NEWLINE_AUTO_RETURN` as well:
            // https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences#example-of-enabling-virtual-terminal-processing
            // This is avoided because in the old Windows Console, that flag causes \n (as opposed to \r\n)
            // to behave unexpectedly (the cursor moves down 1 row but remains on the same column).
            // Additionally, the default console mode in Windows Terminal does not have
            // `DISABLE_NEWLINE_AUTO_RETURN` set, so by only enabling `ENABLE_VIRTUAL_TERMINAL_PROCESSING`
            // we end up matching the mode of Windows Terminal.
            const requested_console_modes = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            const console_mode = original_console_mode | requested_console_modes;
            try current_thread.checkCancel();
            if (windows.kernel32.SetConsoleMode(file.handle, console_mode) != 0) return;
        }
        if (try isCygwinPty(current_thread, file)) return;
    } else {
        if (try supportsAnsiEscapeCodes(current_thread, file)) return;
    }
    return error.NotTerminalDevice;
}

fn fileSupportsAnsiEscapeCodes(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    return supportsAnsiEscapeCodes(current_thread, file);
}

fn supportsAnsiEscapeCodes(current_thread: *Thread, file: File) Io.Cancelable!bool {
    if (is_windows) {
        try current_thread.checkCancel();
        var console_mode: windows.DWORD = 0;
        if (windows.kernel32.GetConsoleMode(file.handle, &console_mode) != 0) {
            if (console_mode & windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0) return true;
        }
        return isCygwinPty(current_thread, file);
    }

    if (native_os == .wasi) {
        // WASI sanitizes stdout when fd is a tty so ANSI escape codes will not
        // be interpreted as actual cursor commands, and stderr is always
        // sanitized.
        return false;
    }

    if (try isTty(current_thread, file)) return true;

    return false;
}

fn isCygwinPty(current_thread: *Thread, file: File) Io.Cancelable!bool {
    if (!is_windows) return false;

    const handle = file.handle;

    // If this is a MSYS2/cygwin pty, then it will be a named pipe with a name in one of these formats:
    //   msys-[...]-ptyN-[...]
    //   cygwin-[...]-ptyN-[...]
    //
    // Example: msys-1888ae32e00d56aa-pty0-to-master

    // First, just check that the handle is a named pipe.
    // This allows us to avoid the more costly NtQueryInformationFile call
    // for handles that aren't named pipes.
    {
        try current_thread.checkCancel();
        var io_status: windows.IO_STATUS_BLOCK = undefined;
        var device_info: windows.FILE.FS_DEVICE_INFORMATION = undefined;
        const rc = windows.ntdll.NtQueryVolumeInformationFile(
            handle,
            &io_status,
            &device_info,
            @sizeOf(windows.FILE.FS_DEVICE_INFORMATION),
            .Device,
        );
        switch (rc) {
            .SUCCESS => {},
            else => return false,
        }
        if (device_info.DeviceType.FileDevice != .NAMED_PIPE) return false;
    }

    const name_bytes_offset = @offsetOf(windows.FILE.NAME_INFORMATION, "FileName");
    // `NAME_MAX` UTF-16 code units (2 bytes each)
    // This buffer may not be long enough to handle *all* possible paths
    // (PATH_MAX_WIDE would be necessary for that), but because we only care
    // about certain paths and we know they must be within a reasonable length,
    // we can use this smaller buffer and just return false on any error from
    // NtQueryInformationFile.
    const num_name_bytes = windows.MAX_PATH * 2;
    var name_info_bytes align(@alignOf(windows.FILE.NAME_INFORMATION)) = [_]u8{0} ** (name_bytes_offset + num_name_bytes);

    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    try current_thread.checkCancel();
    const rc = windows.ntdll.NtQueryInformationFile(
        handle,
        &io_status_block,
        &name_info_bytes,
        @intCast(name_info_bytes.len),
        .Name,
    );
    switch (rc) {
        .SUCCESS => {},
        .INVALID_PARAMETER => unreachable,
        else => return false,
    }

    const name_info: *const windows.FILE_NAME_INFO = @ptrCast(&name_info_bytes);
    const name_bytes = name_info_bytes[name_bytes_offset .. name_bytes_offset + name_info.FileNameLength];
    const name_wide = std.mem.bytesAsSlice(u16, name_bytes);
    // The name we get from NtQueryInformationFile will be prefixed with a '\', e.g. \msys-1888ae32e00d56aa-pty0-to-master
    return (std.mem.startsWith(u16, name_wide, &[_]u16{ '\\', 'm', 's', 'y', 's', '-' }) or
        std.mem.startsWith(u16, name_wide, &[_]u16{ '\\', 'c', 'y', 'g', 'w', 'i', 'n', '-' })) and
        std.mem.indexOf(u16, name_wide, &[_]u16{ '-', 'p', 't', 'y' }) != null;
}

fn fileSetLength(userdata: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const signed_len: i64 = @bitCast(length);
    if (signed_len < 0) return error.FileTooBig; // Avoid ambiguous EINVAL errors.

    if (is_windows) {
        try current_thread.checkCancel();

        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const eof_info: windows.FILE.END_OF_FILE_INFORMATION = .{
            .EndOfFile = signed_len,
        };

        const status = windows.ntdll.NtSetInformationFile(
            file.handle,
            &io_status_block,
            &eof_info,
            @sizeOf(windows.FILE.END_OF_FILE_INFORMATION),
            .EndOfFile,
        );
        switch (status) {
            .SUCCESS => return,
            .INVALID_HANDLE => |err| return windows.statusBug(err), // Handle not open for writing.
            .ACCESS_DENIED => return error.AccessDenied,
            .USER_MAPPED_FILE => return error.AccessDenied,
            .INVALID_PARAMETER => return error.FileTooBig,
            else => return windows.unexpectedStatus(status),
        }
    }

    if (native_os == .wasi and !builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            switch (std.os.wasi.fd_filestat_set_size(file.handle, length)) {
                .SUCCESS => return current_thread.endSyscall(),
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .FBIG => return error.FileTooBig,
                        .IO => return error.InputOutput,
                        .PERM => return error.PermissionDenied,
                        .TXTBSY => return error.FileBusy,
                        .BADF => |err| return errnoBug(err), // Handle not open for writing
                        .INVAL => return error.NonResizable,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(ftruncate_sym(file.handle, signed_len))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FBIG => return error.FileTooBig,
                    .IO => return error.InputOutput,
                    .PERM => return error.PermissionDenied,
                    .TXTBSY => return error.FileBusy,
                    .BADF => |err| return errnoBug(err), // Handle not open for writing.
                    .INVAL => return error.NonResizable, // This is returned for /dev/null for example.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileSetOwner(userdata: ?*anyopaque, file: File, owner: ?File.Uid, group: ?File.Gid) File.SetOwnerError!void {
    if (!have_fchown) return error.Unexpected; // Unsupported OS, don't call this function.
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const uid = owner orelse ~@as(posix.uid_t, 0);
    const gid = group orelse ~@as(posix.gid_t, 0);
    return posixFchown(current_thread, file.handle, uid, gid);
}

fn fileSetPermissions(userdata: ?*anyopaque, file: File, permissions: File.Permissions) File.SetPermissionsError!void {
    if (@sizeOf(File.Permissions) == 0) return;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    switch (native_os) {
        .windows => {
            try current_thread.checkCancel();
            var io_status_block: windows.IO_STATUS_BLOCK = undefined;
            const info: windows.FILE.BASIC_INFORMATION = .{
                .CreationTime = 0,
                .LastAccessTime = 0,
                .LastWriteTime = 0,
                .ChangeTime = 0,
                .FileAttributes = permissions.toAttributes(),
            };
            const status = windows.ntdll.NtSetInformationFile(
                file.handle,
                &io_status_block,
                &info,
                @sizeOf(windows.FILE.BASIC_INFORMATION),
                .Basic,
            );
            switch (status) {
                .SUCCESS => return,
                .INVALID_HANDLE => |err| return windows.statusBug(err),
                .ACCESS_DENIED => return error.AccessDenied,
                else => return windows.unexpectedStatus(status),
            }
        },
        .wasi => return error.Unexpected, // Unsupported OS.
        else => return setPermissionsPosix(current_thread, file.handle, permissions.toMode()),
    }
}

fn setPermissionsPosix(current_thread: *Thread, fd: posix.fd_t, mode: posix.mode_t) File.SetPermissionsError!void {
    comptime assert(have_fchmod);
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.fchmod(fd, mode))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .IO => return error.InputOutput,
                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.FileNotFound,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirSetTimestamps(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.SetTimestampsOptions,
) Dir.SetTimestampsError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        @panic("TODO implement dirSetTimestamps windows");
    }

    if (native_os == .wasi and !builtin.link_libc) {
        @panic("TODO implement dirSetTimestamps wasi");
    }

    var times_buffer: [2]posix.timespec = undefined;
    const times = if (options.modify_timestamp == .now and options.access_timestamp == .now) null else p: {
        times_buffer = .{
            setTimestampToPosix(options.access_timestamp),
            setTimestampToPosix(options.modify_timestamp),
        };
        break :p &times_buffer;
    };

    const flags: u32 = if (!options.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    var path_buffer: [posix.PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    try current_thread.beginSyscall();
    while (true) switch (posix.errno(posix.system.utimensat(dir.handle, sub_path_posix, times, flags))) {
        .SUCCESS => return current_thread.endSyscall(),
        .INTR => {
            try current_thread.checkCancel();
            continue;
        },
        .BADF => |err| return current_thread.endSyscallErrnoBug(err), // always a race condition
        .FAULT => |err| return current_thread.endSyscallErrnoBug(err),
        .INVAL => |err| return current_thread.endSyscallErrnoBug(err),
        .ACCES => return current_thread.endSyscallError(error.AccessDenied),
        .PERM => return current_thread.endSyscallError(error.PermissionDenied),
        .ROFS => return current_thread.endSyscallError(error.ReadOnlyFileSystem),
        else => |err| return current_thread.endSyscallUnexpectedErrno(err),
    };
}

fn fileSetTimestamps(
    userdata: ?*anyopaque,
    file: File,
    options: File.SetTimestampsOptions,
) File.SetTimestampsError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        try current_thread.checkCancel();

        var access_time_buffer: windows.FILETIME = undefined;
        var modify_time_buffer: windows.FILETIME = undefined;
        var system_time_buffer: windows.LARGE_INTEGER = undefined;

        if (options.access_timestamp == .now or options.modify_timestamp == .now) {
            system_time_buffer = windows.ntdll.RtlGetSystemTimePrecise();
        }

        const access_ptr = switch (options.access_timestamp) {
            .unchanged => null,
            .now => @panic("TODO do SystemTimeToFileTime logic here"),
            .new => |ts| p: {
                access_time_buffer = windows.nanoSecondsToFileTime(ts);
                break :p &access_time_buffer;
            },
        };

        const modify_ptr = switch (options.modify_timestamp) {
            .unchanged => null,
            .now => @panic("TODO do SystemTimeToFileTime logic here"),
            .new => |ts| p: {
                modify_time_buffer = windows.nanoSecondsToFileTime(ts);
                break :p &modify_time_buffer;
            },
        };

        // https://github.com/ziglang/zig/issues/1840
        const rc = windows.kernel32.SetFileTime(file.handle, null, access_ptr, modify_ptr);
        if (rc == 0) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        return;
    }

    if (native_os == .wasi and !builtin.link_libc) {
        var atime: std.os.wasi.timestamp_t = 0;
        var mtime: std.os.wasi.timestamp_t = 0;
        var flags: std.os.wasi.fstflags_t = .{};

        switch (options.access_timestamp) {
            .unchanged => {},
            .now => flags.ATIM_NOW = true,
            .new => |ts| {
                atime = timestampToPosix(ts.nanoseconds).toTimestamp();
                flags.ATIM = true;
            },
        }

        switch (options.modify_timestamp) {
            .unchanged => {},
            .now => flags.MTIM_NOW = true,
            .new => |ts| {
                mtime = timestampToPosix(ts.nanoseconds).toTimestamp();
                flags.MTIM = true;
            },
        }

        try current_thread.beginSyscall();
        while (true) switch (std.os.wasi.fd_filestat_set_times(file.handle, atime, mtime, flags)) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            .BADF => |err| return current_thread.endSyscallErrnoBug(err), // File descriptor use-after-free.
            .FAULT => |err| return current_thread.endSyscallErrnoBug(err),
            .INVAL => |err| return current_thread.endSyscallErrnoBug(err),
            .ACCES => return current_thread.endSyscallError(error.AccessDenied),
            .PERM => return current_thread.endSyscallError(error.PermissionDenied),
            .ROFS => return current_thread.endSyscallError(error.ReadOnlyFileSystem),
            else => |err| return current_thread.endSyscallUnexpectedErrno(err),
        };
    }

    var times_buffer: [2]posix.timespec = undefined;
    const times = if (options.modify_timestamp == .now and options.access_timestamp == .now) null else p: {
        times_buffer = .{
            setTimestampToPosix(options.access_timestamp),
            setTimestampToPosix(options.modify_timestamp),
        };
        break :p &times_buffer;
    };

    try current_thread.beginSyscall();
    while (true) switch (posix.errno(posix.system.futimens(file.handle, times))) {
        .SUCCESS => return current_thread.endSyscall(),
        .INTR => {
            try current_thread.checkCancel();
            continue;
        },
        .BADF => |err| return current_thread.endSyscallErrnoBug(err), // always a race condition
        .FAULT => |err| return current_thread.endSyscallErrnoBug(err),
        .INVAL => |err| return current_thread.endSyscallErrnoBug(err),
        .ACCES => return current_thread.endSyscallError(error.AccessDenied),
        .PERM => return current_thread.endSyscallError(error.PermissionDenied),
        .ROFS => return current_thread.endSyscallError(error.ReadOnlyFileSystem),
        else => |err| return current_thread.endSyscallUnexpectedErrno(err),
    };
}

const windows_lock_range_off: windows.LARGE_INTEGER = 0;
const windows_lock_range_len: windows.LARGE_INTEGER = 1;

fn fileLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!void {
    if (native_os == .wasi) return error.FileLocksUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        const exclusive = switch (lock) {
            .none => {
                // To match the non-Windows behavior, unlock
                var io_status_block: windows.IO_STATUS_BLOCK = undefined;
                const status = windows.ntdll.NtUnlockFile(
                    file.handle,
                    &io_status_block,
                    &windows_lock_range_off,
                    &windows_lock_range_len,
                    0,
                );
                switch (status) {
                    .SUCCESS => {},
                    .RANGE_NOT_LOCKED => {},
                    .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
                    else => return windows.unexpectedStatus(status),
                }
                return;
            },
            .shared => false,
            .exclusive => true,
        };
        try current_thread.checkCancel();
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_range_off,
            &windows_lock_range_len,
            null,
            windows.FALSE,
            @intFromBool(exclusive),
        );
        switch (status) {
            .SUCCESS => return,
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            .LOCK_NOT_GRANTED => |err| return windows.statusBug(err), // passed FailImmediately=false
            .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
            else => return windows.unexpectedStatus(status),
        }
    }

    const operation: i32 = switch (lock) {
        .none => posix.LOCK.UN,
        .shared => posix.LOCK.SH,
        .exclusive => posix.LOCK.EX,
    };
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.flock(file.handle, operation))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOLCK => return error.SystemResources,
                    .AGAIN => |err| return errnoBug(err),
                    .OPNOTSUPP => return error.FileLocksUnsupported,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileTryLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!bool {
    if (native_os == .wasi) return error.FileLocksUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        const exclusive = switch (lock) {
            .none => {
                // To match the non-Windows behavior, unlock
                var io_status_block: windows.IO_STATUS_BLOCK = undefined;
                const status = windows.ntdll.NtUnlockFile(
                    file.handle,
                    &io_status_block,
                    &windows_lock_range_off,
                    &windows_lock_range_len,
                    0,
                );
                switch (status) {
                    .SUCCESS => return true,
                    .RANGE_NOT_LOCKED => return false,
                    .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
                    else => return windows.unexpectedStatus(status),
                }
            },
            .shared => false,
            .exclusive => true,
        };
        try current_thread.checkCancel();
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_range_off,
            &windows_lock_range_len,
            null,
            windows.TRUE,
            @intFromBool(exclusive),
        );
        switch (status) {
            .SUCCESS => return true,
            .INSUFFICIENT_RESOURCES => return error.SystemResources,
            .LOCK_NOT_GRANTED => return false,
            .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
            else => return windows.unexpectedStatus(status),
        }
    }

    const operation: i32 = switch (lock) {
        .none => posix.LOCK.UN,
        .shared => posix.LOCK.SH | posix.LOCK.NB,
        .exclusive => posix.LOCK.EX | posix.LOCK.NB,
    };
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.flock(file.handle, operation))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return true;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            .AGAIN => {
                current_thread.endSyscall();
                return false;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOLCK => return error.SystemResources,
                    .OPNOTSUPP => return error.FileLocksUnsupported,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileUnlock(userdata: ?*anyopaque, file: File) void {
    if (native_os == .wasi) return;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;

    if (is_windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtUnlockFile(
            file.handle,
            &io_status_block,
            &windows_lock_range_off,
            &windows_lock_range_len,
            0,
        );
        if (is_debug) switch (status) {
            .SUCCESS => {},
            .RANGE_NOT_LOCKED => unreachable, // Function asserts unlocked.
            .ACCESS_VIOLATION => unreachable, // bad io_status_block pointer
            else => unreachable, // Resource deallocation must succeed.
        };
        return;
    }

    while (true) {
        switch (posix.errno(posix.system.flock(file.handle, posix.LOCK.UN))) {
            .SUCCESS => return,
            .CANCELED, .INTR => continue,
            .AGAIN => return assert(!is_debug), // unlocking can't block
            .BADF => return assert(!is_debug), // File descriptor used after closed.
            .INVAL => return assert(!is_debug), // invalid parameters
            .NOLCK => return assert(!is_debug), // Resource deallocation.
            .OPNOTSUPP => return assert(!is_debug), // We already got the lock.
            else => return assert(!is_debug), // Resource deallocation must succeed.
        }
    }
}

fn fileDowngradeLock(userdata: ?*anyopaque, file: File) File.DowngradeLockError!void {
    if (native_os == .wasi) return;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        try current_thread.checkCancel();
        // On Windows it works like a semaphore + exclusivity flag. To
        // implement this function, we first obtain another lock in shared
        // mode. This changes the exclusivity flag, but increments the
        // semaphore to 2. So we follow up with an NtUnlockFile which
        // decrements the semaphore but does not modify the exclusivity flag.
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        switch (windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_range_off,
            &windows_lock_range_len,
            null,
            windows.TRUE,
            windows.FALSE,
        )) {
            .SUCCESS => {},
            .INSUFFICIENT_RESOURCES => |err| return windows.statusBug(err),
            .LOCK_NOT_GRANTED => |err| return windows.statusBug(err), // File was not locked in exclusive mode.
            .ACCESS_VIOLATION => |err| return windows.statusBug(err), // bad io_status_block pointer
            else => |status| return windows.unexpectedStatus(status),
        }
        const status = windows.ntdll.NtUnlockFile(
            file.handle,
            &io_status_block,
            &windows_lock_range_off,
            &windows_lock_range_len,
            0,
        );
        if (is_debug) switch (status) {
            .SUCCESS => {},
            .RANGE_NOT_LOCKED => unreachable, // File was not locked.
            .ACCESS_VIOLATION => unreachable, // bad io_status_block pointer
            else => unreachable, // Resource deallocation must succeed.
        };
        return;
    }

    const operation = posix.LOCK.SH | posix.LOCK.NB;

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.flock(file.handle, operation))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .AGAIN => |err| return errnoBug(err), // File was not locked in exclusive mode.
                    .BADF => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOLCK => |err| return errnoBug(err), // Lock already obtained.
                    .OPNOTSUPP => |err| return errnoBug(err), // Lock already obtained.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirOpenDirWasi(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    if (builtin.link_libc) return dirOpenDirPosix(userdata, dir, sub_path, options);
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const wasi = std.os.wasi;

    var base: std.os.wasi.rights_t = .{
        .FD_FILESTAT_GET = true,
        .FD_FDSTAT_SET_FLAGS = true,
        .FD_FILESTAT_SET_TIMES = true,
    };
    if (options.access_sub_paths) {
        base.FD_READDIR = true;
        base.PATH_CREATE_DIRECTORY = true;
        base.PATH_CREATE_FILE = true;
        base.PATH_LINK_SOURCE = true;
        base.PATH_LINK_TARGET = true;
        base.PATH_OPEN = true;
        base.PATH_READLINK = true;
        base.PATH_RENAME_SOURCE = true;
        base.PATH_RENAME_TARGET = true;
        base.PATH_FILESTAT_GET = true;
        base.PATH_FILESTAT_SET_SIZE = true;
        base.PATH_FILESTAT_SET_TIMES = true;
        base.PATH_SYMLINK = true;
        base.PATH_REMOVE_DIRECTORY = true;
        base.PATH_UNLINK_FILE = true;
    }

    const lookup_flags: wasi.lookupflags_t = .{ .SYMLINK_FOLLOW = options.follow_symlinks };
    const oflags: wasi.oflags_t = .{ .DIRECTORY = true };
    const fdflags: wasi.fdflags_t = .{};
    var fd: posix.fd_t = undefined;
    try current_thread.beginSyscall();
    while (true) {
        switch (wasi.path_open(dir.handle, lookup_flags, sub_path.ptr, sub_path.len, oflags, base, base, fdflags, &fd)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return .{ .handle = fd };
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.BadPathName,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .ACCES => return error.AccessDenied,
                    .LOOP => return error.SymLinkLoop,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NODEV => return error.NoDevice,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .BUSY => return error.DeviceBusy,
                    .NOTCAPABLE => return error.AccessDenied,
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn dirHardLink(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
    options: Dir.HardLinkOptions,
) Dir.HardLinkError!void {
    if (is_windows) return error.OperationUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (native_os == .wasi and !builtin.link_libc) {
        const flags: std.os.wasi.lookupflags_t = .{
            .SYMLINK_FOLLOW = options.follow_symlinks,
        };
        try current_thread.beginSyscall();
        while (true) {
            switch (std.os.wasi.path_link(
                old_dir.handle,
                flags,
                old_sub_path.ptr,
                old_sub_path.len,
                new_dir.handle,
                new_sub_path.ptr,
                new_sub_path.len,
            )) {
                .SUCCESS => return current_thread.endSyscall(),
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .ACCES => return error.AccessDenied,
                        .DQUOT => return error.DiskQuota,
                        .EXIST => return error.PathAlreadyExists,
                        .FAULT => |err| return errnoBug(err),
                        .IO => return error.HardwareFailure,
                        .LOOP => return error.SymLinkLoop,
                        .MLINK => return error.LinkQuotaExceeded,
                        .NAMETOOLONG => return error.NameTooLong,
                        .NOENT => return error.FileNotFound,
                        .NOMEM => return error.SystemResources,
                        .NOSPC => return error.NoSpaceLeft,
                        .NOTDIR => return error.NotDir,
                        .PERM => return error.PermissionDenied,
                        .ROFS => return error.ReadOnlyFileSystem,
                        .XDEV => return error.NotSameFileSystem,
                        .INVAL => |err| return errnoBug(err),
                        .ILSEQ => return error.BadPathName,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    var old_path_buffer: [posix.PATH_MAX]u8 = undefined;
    var new_path_buffer: [posix.PATH_MAX]u8 = undefined;

    const old_sub_path_posix = try pathToPosix(old_sub_path, &old_path_buffer);
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    const flags: u32 = if (!options.follow_symlinks) posix.AT.SYMLINK_NOFOLLOW else 0;

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.linkat(
            old_dir.handle,
            old_sub_path_posix,
            new_dir.handle,
            new_sub_path_posix,
            flags,
        ))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .DQUOT => return error.DiskQuota,
                    .EXIST => return error.PathAlreadyExists,
                    .FAULT => |err| return errnoBug(err),
                    .IO => return error.HardwareFailure,
                    .LOOP => return error.SymLinkLoop,
                    .MLINK => return error.LinkQuotaExceeded,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOSPC => return error.NoSpaceLeft,
                    .NOTDIR => return error.NotDir,
                    .PERM => return error.PermissionDenied,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .XDEV => return error.NotSameFileSystem,
                    .INVAL => |err| return errnoBug(err),
                    .ILSEQ => return error.BadPathName,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileClose(userdata: ?*anyopaque, files: []const File) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    for (files) |file| posix.close(file.handle);
}

const fileReadStreaming = switch (native_os) {
    .windows => fileReadStreamingWindows,
    else => fileReadStreamingPosix,
};

fn fileReadStreamingPosix(userdata: ?*anyopaque, file: File, data: []const []u8) File.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var iovecs_buffer: [max_iovecs_len]posix.iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    if (i == 0) return 0;
    const dest = iovecs_buffer[0..i];
    assert(dest[0].len > 0);

    if (native_os == .wasi and !builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            var nread: usize = undefined;
            switch (std.os.wasi.fd_read(file.handle, dest.ptr, dest.len, &nread)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return nread;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .BADF => return error.NotOpenForReading, // File operation on directory.
                        .IO => return error.InputOutput,
                        .ISDIR => return error.IsDir,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => return error.SocketUnconnected,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .TIMEDOUT => return error.Timeout,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.readv(file.handle, dest.ptr, @intCast(dest.len));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .AGAIN => return error.WouldBlock,
                    .BADF => |err| {
                        if (native_os == .wasi) return error.NotOpenForReading; // File operation on directory.
                        return errnoBug(err); // File descriptor used after closed.
                    },
                    .IO => return error.InputOutput,
                    .ISDIR => return error.IsDir,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketUnconnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.Timeout,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileReadStreamingWindows(userdata: ?*anyopaque, file: File, data: []const []u8) File.Reader.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const DWORD = windows.DWORD;
    var index: usize = 0;
    while (index < data.len and data[index].len == 0) index += 1;
    if (index == data.len) return 0;
    const buffer = data[index];
    const want_read_count: DWORD = @min(std.math.maxInt(DWORD), buffer.len);

    while (true) {
        try current_thread.checkCancel();
        var n: DWORD = undefined;
        if (windows.kernel32.ReadFile(file.handle, buffer.ptr, want_read_count, &n, null) != 0)
            return n;
        switch (windows.GetLastError()) {
            .IO_PENDING => |err| return windows.errorBug(err),
            .OPERATION_ABORTED => continue,
            .BROKEN_PIPE => return 0,
            .HANDLE_EOF => return 0,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            .LOCK_VIOLATION => return error.LockViolation,
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_HANDLE => return error.NotOpenForReading,
            else => |err| return windows.unexpectedError(err),
        }
    }
}

fn fileReadPositionalPosix(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (!have_preadv) @compileError("TODO implement fileReadPositionalPosix for cursed operating systems that don't support preadv (it's only Haiku)");

    var iovecs_buffer: [max_iovecs_len]posix.iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    if (i == 0) return 0;
    const dest = iovecs_buffer[0..i];
    assert(dest[0].len > 0);

    if (native_os == .wasi and !builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            var nread: usize = undefined;
            switch (std.os.wasi.fd_pread(file.handle, dest.ptr, dest.len, offset, &nread)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return nread;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .AGAIN => |err| return errnoBug(err),
                        .BADF => return error.NotOpenForReading, // File operation on directory.
                        .IO => return error.InputOutput,
                        .ISDIR => return error.IsDir,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => return error.SocketUnconnected,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .TIMEDOUT => return error.Timeout,
                        .NXIO => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = preadv_sym(file.handle, dest.ptr, @intCast(dest.len), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @bitCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .AGAIN => return error.WouldBlock,
                    .BADF => |err| {
                        if (native_os == .wasi) return error.NotOpenForReading; // File operation on directory.
                        return errnoBug(err); // File descriptor used after closed.
                    },
                    .IO => return error.InputOutput,
                    .ISDIR => return error.IsDir,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketUnconnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.Timeout,
                    .NXIO => return error.Unseekable,
                    .SPIPE => return error.Unseekable,
                    .OVERFLOW => return error.Unseekable,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

const fileReadPositional = switch (native_os) {
    .windows => fileReadPositionalWindows,
    else => fileReadPositionalPosix,
};

fn fileReadPositionalWindows(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const DWORD = windows.DWORD;

    var index: usize = 0;
    while (index < data.len and data[index].len == 0) index += 1;
    if (index == data.len) return 0;
    const buffer = data[index];
    const want_read_count: DWORD = @min(std.math.maxInt(DWORD), buffer.len);

    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = @truncate(offset),
                .OffsetHigh = @truncate(offset >> 32),
            },
        },
        .hEvent = null,
    };

    while (true) {
        try current_thread.checkCancel();
        var n: DWORD = undefined;
        if (windows.kernel32.ReadFile(file.handle, buffer.ptr, want_read_count, &n, &overlapped) != 0)
            return n;
        switch (windows.GetLastError()) {
            .IO_PENDING => |err| return windows.errorBug(err),
            .OPERATION_ABORTED => continue,
            .BROKEN_PIPE => return 0,
            .HANDLE_EOF => return 0,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            .LOCK_VIOLATION => return error.LockViolation,
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_HANDLE => return error.NotOpenForReading,
            else => |err| return windows.unexpectedError(err),
        }
    }
}

fn fileSeekBy(userdata: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const fd = file.handle;

    if (native_os == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        var result: u64 = undefined;
        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.llseek(fd, @bitCast(offset), &result, posix.SEEK.CUR))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .NXIO => return error.Unseekable,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (native_os == .windows) {
        try current_thread.checkCancel();
        return windows.SetFilePointerEx_CURRENT(fd, offset);
    }

    if (native_os == .wasi and !builtin.link_libc) {
        var new_offset: std.os.wasi.filesize_t = undefined;
        try current_thread.beginSyscall();
        while (true) {
            switch (std.os.wasi.fd_seek(fd, offset, .CUR, &new_offset)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .NXIO => return error.Unseekable,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (posix.SEEK == void) return error.Unseekable;

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(lseek_sym(fd, offset, posix.SEEK.CUR))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .INVAL => return error.Unseekable,
                    .OVERFLOW => return error.Unseekable,
                    .SPIPE => return error.Unseekable,
                    .NXIO => return error.Unseekable,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn fileSeekTo(userdata: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const fd = file.handle;

    if (native_os == .windows) {
        try current_thread.checkCancel();
        return windows.SetFilePointerEx_BEGIN(fd, offset);
    }

    if (native_os == .wasi and !builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            var new_offset: std.os.wasi.filesize_t = undefined;
            switch (std.os.wasi.fd_seek(fd, @bitCast(offset), .SET, &new_offset)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .NXIO => return error.Unseekable,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (posix.SEEK == void) return error.Unseekable;

    return posixSeekTo(current_thread, fd, offset);
}

fn posixSeekTo(current_thread: *Thread, fd: posix.fd_t, offset: u64) File.SeekError!void {
    if (native_os == .linux and !builtin.link_libc and @sizeOf(usize) == 4) {
        try current_thread.beginSyscall();
        while (true) {
            var result: u64 = undefined;
            switch (posix.errno(posix.system.llseek(fd, offset, &result, posix.SEEK.SET))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .INVAL => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .NXIO => return error.Unseekable,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(lseek_sym(fd, @bitCast(offset), posix.SEEK.SET))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .INVAL => return error.Unseekable,
                    .OVERFLOW => return error.Unseekable,
                    .SPIPE => return error.Unseekable,
                    .NXIO => return error.Unseekable,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn processExecutableOpen(userdata: ?*anyopaque, flags: File.OpenFlags) std.process.OpenExecutableError!File {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    switch (native_os) {
        .wasi => return error.OperationUnsupported,
        .linux, .serenity => return dirOpenFilePosix(t, .{ .handle = posix.AT.FDCWD }, "/proc/self/exe", flags),
        .windows => {
            // If ImagePathName is a symlink, then it will contain the path of the symlink,
            // not the path that the symlink points to. However, because we are opening
            // the file, we can let the openFileW call follow the symlink for us.
            const image_path_unicode_string = &windows.peb().ProcessParameters.ImagePathName;
            const image_path_name = image_path_unicode_string.Buffer.?[0 .. image_path_unicode_string.Length / 2 :0];
            const prefixed_path_w = try windows.wToPrefixedFileW(null, image_path_name);
            return dirOpenFileWtf16(t, null, prefixed_path_w.span(), flags);
        },
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => {
            // _NSGetExecutablePath() returns a path that might be a symlink to
            // the executable. Here it does not matter since we open it.
            var symlink_path_buf: [posix.PATH_MAX + 1]u8 = undefined;
            var n: u32 = symlink_path_buf.len;
            const rc = std.c._NSGetExecutablePath(&symlink_path_buf, &n);
            if (rc != 0) return error.NameTooLong;
            const symlink_path = std.mem.sliceTo(&symlink_path_buf, 0);
            return dirOpenFilePosix(t, .cwd(), symlink_path, flags);
        },
        else => {
            var buffer: [Dir.max_path_bytes]u8 = undefined;
            const n = try processExecutablePath(t, &buffer);
            buffer[n] = 0;
            const executable_path = buffer[0..n :0];
            return dirOpenFilePosix(t, .cwd(), executable_path, flags);
        },
    }
}

fn processExecutablePath(userdata: ?*anyopaque, out_buffer: []u8) std.process.ExecutablePathError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));

    switch (native_os) {
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => {
            // _NSGetExecutablePath() returns a path that might be a symlink to
            // the executable.
            var symlink_path_buf: [posix.PATH_MAX + 1]u8 = undefined;
            var n: u32 = symlink_path_buf.len;
            const rc = std.c._NSGetExecutablePath(&symlink_path_buf, &n);
            if (rc != 0) return error.NameTooLong;
            const symlink_path = std.mem.sliceTo(&symlink_path_buf, 0);
            return Io.Dir.realPathFileAbsolute(ioBasic(t), symlink_path, out_buffer) catch |err| switch (err) {
                error.NetworkNotFound => unreachable, // Windows-only
                else => |e| return e,
            };
        },
        .linux, .serenity => return Io.Dir.readLinkAbsolute(ioBasic(t), "/proc/self/exe", out_buffer) catch |err| switch (err) {
            error.UnsupportedReparsePointType => unreachable, // Windows-only
            error.NetworkNotFound => unreachable, // Windows-only
            else => |e| return e,
        },
        .illumos => return Io.Dir.readLinkAbsolute(ioBasic(t), "/proc/self/path/a.out", out_buffer) catch |err| switch (err) {
            error.UnsupportedReparsePointType => unreachable, // Windows-only
            error.NetworkNotFound => unreachable, // Windows-only
            else => |e| return e,
        },
        .freebsd, .dragonfly => {
            const current_thread = Thread.getCurrent(t);
            var mib: [4]c_int = .{ posix.CTL.KERN, posix.KERN.PROC, posix.KERN.PROC_PATHNAME, -1 };
            var out_len: usize = out_buffer.len;
            try current_thread.beginSyscall();
            while (true) {
                switch (posix.errno(posix.system.sysctl(&mib, mib.len, out_buffer.ptr, &out_len, null, 0))) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        return out_len - 1; // discard terminating NUL
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .FAULT => |err| return errnoBug(err),
                            .PERM => return error.PermissionDenied,
                            .NOMEM => return error.SystemResources,
                            .NOENT => |err| return errnoBug(err),
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            }
        },
        .netbsd => {
            const current_thread = Thread.getCurrent(t);
            var mib = [4]c_int{ posix.CTL.KERN, posix.KERN.PROC_ARGS, -1, posix.KERN.PROC_PATHNAME };
            var out_len: usize = out_buffer.len;
            try current_thread.beginSyscall();
            while (true) {
                switch (posix.errno(posix.system.sysctl(&mib, mib.len, out_buffer.ptr, &out_len, null, 0))) {
                    .SUCCESS => {
                        current_thread.endSyscall();
                        return out_len - 1; // discard terminating NUL
                    },
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        switch (e) {
                            .FAULT => |err| return errnoBug(err),
                            .PERM => return error.PermissionDenied,
                            .NOMEM => return error.SystemResources,
                            .NOENT => |err| return errnoBug(err),
                            else => |err| return posix.unexpectedErrno(err),
                        }
                    },
                }
            }
        },
        .openbsd, .haiku => {
            // The best we can do on these operating systems is check based on
            // the first process argument.
            const argv0 = std.mem.span(t.argv0.value orelse return error.OperationUnsupported);
            if (std.mem.findScalar(u8, argv0, '/') != null) {
                // argv[0] is a path (relative or absolute): use realpath(3) directly
                const current_thread = Thread.getCurrent(t);
                var resolved_buf: [std.c.PATH_MAX]u8 = undefined;
                try current_thread.beginSyscall();
                while (true) {
                    if (std.c.realpath(argv0, &resolved_buf)) |p| {
                        assert(p == &resolved_buf);
                        break current_thread.endSyscall();
                    } else switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
                        .INTR => {
                            try current_thread.checkCancel();
                            continue;
                        },
                        else => |e| {
                            current_thread.endSyscall();
                            switch (e) {
                                .ACCES => return error.AccessDenied,
                                .INVAL => |err| return errnoBug(err), // the pathname argument is a null pointer
                                .IO => return error.InputOutput,
                                .LOOP => return error.SymLinkLoop,
                                .NAMETOOLONG => return error.NameTooLong,
                                .NOENT => return error.FileNotFound,
                                .NOTDIR => return error.NotDir,
                                .NOMEM => |err| return errnoBug(err), // sufficient storage space is unavailable for allocation
                                else => |err| return posix.unexpectedErrno(err),
                            }
                        },
                    }
                }
                const resolved = std.mem.sliceTo(&resolved_buf, 0);
                if (resolved.len > out_buffer.len)
                    return error.NameTooLong;
                @memcpy(out_buffer[0..resolved.len], resolved);
                return resolved.len;
            } else if (argv0.len != 0) {
                // argv[0] is not empty (and not a path): search PATH
                t.scanEnviron();
                const PATH = t.environ.string.PATH orelse return error.FileNotFound;
                const current_thread = Thread.getCurrent(t);
                var it = std.mem.tokenizeScalar(u8, PATH, ':');
                it: while (it.next()) |dir| {
                    var resolved_path_buf: [std.c.PATH_MAX]u8 = undefined;
                    const resolved_path = std.fmt.bufPrintSentinel(&resolved_path_buf, "{s}/{s}", .{
                        dir, argv0,
                    }, 0) catch continue;

                    var resolved_buf: [std.c.PATH_MAX]u8 = undefined;
                    try current_thread.beginSyscall();
                    while (true) {
                        if (std.c.realpath(resolved_path, &resolved_buf)) |p| {
                            assert(p == &resolved_buf);
                            break current_thread.endSyscall();
                        } else switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
                            .INTR => {
                                try current_thread.checkCancel();
                                continue;
                            },
                            .NAMETOOLONG => {
                                current_thread.endSyscall();
                                return error.NameTooLong;
                            },
                            .NOMEM => {
                                current_thread.endSyscall();
                                return error.SystemResources;
                            },
                            .IO => {
                                current_thread.endSyscall();
                                return error.InputOutput;
                            },
                            .ACCES, .LOOP, .NOENT, .NOTDIR => {
                                current_thread.endSyscall();
                                continue :it;
                            },
                            else => |err| {
                                current_thread.endSyscall();
                                return posix.unexpectedErrno(err);
                            },
                        }
                    }
                    const resolved = std.mem.sliceTo(&resolved_buf, 0);
                    if (resolved.len > out_buffer.len)
                        return error.NameTooLong;
                    @memcpy(out_buffer[0..resolved.len], resolved);
                    return resolved.len;
                }
            }
            return error.FileNotFound;
        },
        .windows => {
            const current_thread = Thread.getCurrent(t);
            try current_thread.checkCancel();
            const w = windows;
            const image_path_unicode_string = &w.peb().ProcessParameters.ImagePathName;
            const image_path_name = image_path_unicode_string.Buffer.?[0 .. image_path_unicode_string.Length / 2 :0];

            // If ImagePathName is a symlink, then it will contain the path of the
            // symlink, not the path that the symlink points to. We want the path
            // that the symlink points to, though, so we need to get the realpath.
            var path_name_w_buf = try w.wToPrefixedFileW(null, image_path_name);

            const h_file = blk: {
                const res = w.OpenFile(path_name_w_buf.span(), .{
                    .dir = null,
                    .access_mask = .{
                        .GENERIC = .{ .READ = true },
                        .STANDARD = .{ .SYNCHRONIZE = true },
                    },
                    .creation = .OPEN,
                    .filter = .any,
                }) catch |err| switch (err) {
                    error.WouldBlock => unreachable,
                    else => |e| return e,
                };
                break :blk res;
            };
            defer w.CloseHandle(h_file);

            // TODO move GetFinalPathNameByHandle logic into std.Io.Threaded and add cancel checks
            const wide_slice = try w.GetFinalPathNameByHandle(h_file, .{}, &path_name_w_buf.data);

            const len = std.unicode.calcWtf8Len(wide_slice);
            if (len > out_buffer.len)
                return error.NameTooLong;

            const end_index = std.unicode.wtf16LeToWtf8(out_buffer, wide_slice);
            return end_index;
        },
        else => return error.OperationUnsupported,
    }
}

fn fileWritePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        if (header.len != 0) {
            return writeFilePositionalWindows(current_thread, file.handle, header, offset);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            return writeFilePositionalWindows(current_thread, file.handle, buf, offset);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        return writeFilePositionalWindows(current_thread, file.handle, pattern, offset);
    }

    var iovecs: [max_iovecs_len]posix.iovec_const = undefined;
    var iovlen: iovlen_t = 0;
    addBuf(&iovecs, &iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &iovlen, bytes);
    const pattern = data[data.len - 1];
    if (iovecs.len - iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                var backup_buffer: [splat_buffer_size]u8 = undefined;
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(&iovecs, &iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(&iovecs, &iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(&iovecs, &iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - iovlen)) |_| {
                addBuf(&iovecs, &iovlen, pattern);
            },
        },
    };

    if (iovlen == 0) return 0;

    if (native_os == .wasi and !builtin.link_libc) {
        var n_written: usize = undefined;
        try current_thread.beginSyscall();
        while (true) {
            switch (std.os.wasi.fd_pwrite(file.handle, &iovecs, iovlen, offset, &n_written)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return n_written;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .AGAIN => |err| return errnoBug(err),
                        .BADF => return error.NotOpenForWriting, // can be a race condition.
                        .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
                        .DQUOT => return error.DiskQuota,
                        .FBIG => return error.FileTooBig,
                        .IO => return error.InputOutput,
                        .NOSPC => return error.NoSpaceLeft,
                        .PERM => return error.PermissionDenied,
                        .PIPE => return error.BrokenPipe,
                        .NOTCAPABLE => return error.AccessDenied,
                        .NXIO => return error.Unseekable,
                        .SPIPE => return error.Unseekable,
                        .OVERFLOW => return error.Unseekable,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = pwritev_sym(file.handle, &iovecs, @intCast(iovlen), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .AGAIN => return error.WouldBlock,
                    .BADF => return error.NotOpenForWriting, // Usually a race condition.
                    .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
                    .DQUOT => return error.DiskQuota,
                    .FBIG => return error.FileTooBig,
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .PERM => return error.PermissionDenied,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => |err| return errnoBug(err), // Not a socket handle.
                    .BUSY => return error.DeviceBusy,
                    .TXTBSY => return error.FileBusy,
                    .NXIO => return error.Unseekable,
                    .SPIPE => return error.Unseekable,
                    .OVERFLOW => return error.Unseekable,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn writeFilePositionalWindows(
    current_thread: *Thread,
    handle: windows.HANDLE,
    bytes: []const u8,
    offset: u64,
) File.WritePositionalError!usize {
    try current_thread.checkCancel();

    var bytes_written: windows.DWORD = undefined;
    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = @truncate(offset),
                .OffsetHigh = @truncate(offset >> 32),
            },
        },
        .hEvent = null,
    };
    const adjusted_len = std.math.lossyCast(u32, bytes.len);
    if (windows.kernel32.WriteFile(handle, bytes.ptr, adjusted_len, &bytes_written, &overlapped) == 0) {
        switch (windows.GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.Canceled,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .NO_DATA => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .ACCESS_DENIED => return error.AccessDenied,
            .WORKING_SET_QUOTA => return error.SystemResources,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes_written;
}

fn fileWriteStreaming(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) File.Writer.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        if (header.len != 0) {
            return writeFileStreamingWindows(current_thread, file.handle, header);
        }
        for (data[0 .. data.len - 1]) |buf| {
            if (buf.len == 0) continue;
            return writeFileStreamingWindows(current_thread, file.handle, buf);
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return 0;
        return writeFileStreamingWindows(current_thread, file.handle, pattern);
    }

    var iovecs: [max_iovecs_len]posix.iovec_const = undefined;
    var iovlen: iovlen_t = 0;
    addBuf(&iovecs, &iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &iovlen, bytes);
    const pattern = data[data.len - 1];
    if (iovecs.len - iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                var backup_buffer: [splat_buffer_size]u8 = undefined;
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(&iovecs, &iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(&iovecs, &iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(&iovecs, &iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - iovlen)) |_| {
                addBuf(&iovecs, &iovlen, pattern);
            },
        },
    };

    if (iovlen == 0) return 0;

    if (native_os == .wasi and !builtin.link_libc) {
        var n_written: usize = undefined;
        try current_thread.beginSyscall();
        while (true) {
            switch (std.os.wasi.fd_write(file.handle, &iovecs, iovlen, &n_written)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return n_written;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .AGAIN => |err| return errnoBug(err),
                        .BADF => return error.NotOpenForWriting, // can be a race condition.
                        .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
                        .DQUOT => return error.DiskQuota,
                        .FBIG => return error.FileTooBig,
                        .IO => return error.InputOutput,
                        .NOSPC => return error.NoSpaceLeft,
                        .PERM => return error.PermissionDenied,
                        .PIPE => return error.BrokenPipe,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.writev(file.handle, &iovecs, @intCast(iovlen));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .AGAIN => return error.WouldBlock,
                    .BADF => return error.NotOpenForWriting, // Can be a race condition.
                    .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
                    .DQUOT => return error.DiskQuota,
                    .FBIG => return error.FileTooBig,
                    .IO => return error.InputOutput,
                    .NOSPC => return error.NoSpaceLeft,
                    .PERM => return error.PermissionDenied,
                    .PIPE => return error.BrokenPipe,
                    .CONNRESET => |err| return errnoBug(err), // Not a socket handle.
                    .BUSY => return error.DeviceBusy,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn writeFileStreamingWindows(
    current_thread: *Thread,
    handle: windows.HANDLE,
    bytes: []const u8,
) File.Writer.Error!usize {
    try current_thread.checkCancel();

    var bytes_written: windows.DWORD = undefined;
    const adjusted_len = std.math.lossyCast(u32, bytes.len);
    if (windows.kernel32.WriteFile(handle, bytes.ptr, adjusted_len, &bytes_written, null) == 0) {
        switch (windows.GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.Canceled,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .NO_DATA => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .ACCESS_DENIED => return error.AccessDenied,
            .WORKING_SET_QUOTA => return error.SystemResources,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes_written;
}

fn fileWriteFileStreaming(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
) File.Writer.WriteFileError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const reader_buffered = file_reader.interface.buffered();
    if (reader_buffered.len >= @intFromEnum(limit)) {
        const n = try fileWriteStreaming(t, file, header, &.{limit.slice(reader_buffered)}, 1);
        file_reader.interface.toss(n -| header.len);
        return n;
    }
    const file_limit = @intFromEnum(limit) - reader_buffered.len;
    const out_fd = file.handle;
    const in_fd = file_reader.file.handle;

    if (file_reader.size) |size| {
        if (size - file_reader.pos == 0) {
            if (reader_buffered.len != 0) {
                const n = try fileWriteStreaming(t, file, header, &.{limit.slice(reader_buffered)}, 1);
                file_reader.interface.toss(n -| header.len);
                return n;
            } else {
                return error.EndOfStream;
            }
        }
    }

    if (native_os == .freebsd) sf: {
        // Try using sendfile on FreeBSD.
        if (@atomicLoad(UseSendfile, &t.use_sendfile, .monotonic) == .disabled) break :sf;
        const offset = std.math.cast(std.c.off_t, file_reader.pos) orelse break :sf;
        var hdtr_data: std.c.sf_hdtr = undefined;
        var headers: [2]posix.iovec_const = undefined;
        var headers_i: u8 = 0;
        if (header.len != 0) {
            headers[headers_i] = .{ .base = header.ptr, .len = header.len };
            headers_i += 1;
        }
        if (reader_buffered.len != 0) {
            headers[headers_i] = .{ .base = reader_buffered.ptr, .len = reader_buffered.len };
            headers_i += 1;
        }
        const hdtr: ?*std.c.sf_hdtr = if (headers_i == 0) null else b: {
            hdtr_data = .{
                .headers = &headers,
                .hdr_cnt = headers_i,
                .trailers = null,
                .trl_cnt = 0,
            };
            break :b &hdtr_data;
        };
        var sbytes: std.c.off_t = 0;
        const nbytes: usize = @min(file_limit, std.math.maxInt(usize));
        const flags = 0;

        const current_thread = Thread.getCurrent(t);
        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(std.c.sendfile(in_fd, out_fd, offset, nbytes, hdtr, &sbytes, flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INVAL, .OPNOTSUPP, .NOTSOCK, .NOSYS => {
                    // Give calling code chance to observe before trying
                    // something else.
                    current_thread.endSyscall();
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
                .INTR, .BUSY => {
                    if (sbytes == 0) {
                        try current_thread.checkCancel();
                        continue;
                    } else {
                        // Even if we are being canceled, there have been side
                        // effects, so it is better to report those side
                        // effects to the caller.
                        current_thread.endSyscall();
                        break;
                    }
                },
                .AGAIN => {
                    current_thread.endSyscall();
                    if (sbytes == 0) return error.WouldBlock;
                    break;
                },
                else => |e| {
                    current_thread.endSyscall();
                    assert(error.Unexpected == switch (e) {
                        .NOTCONN => return error.BrokenPipe,
                        .IO => return error.InputOutput,
                        .PIPE => return error.BrokenPipe,
                        .NOBUFS => return error.SystemResources,
                        .BADF => |err| errnoBug(err),
                        .FAULT => |err| errnoBug(err),
                        else => |err| posix.unexpectedErrno(err),
                    });
                    // Give calling code chance to observe the error before trying
                    // something else.
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
            }
        }
        if (sbytes == 0) {
            file_reader.size = file_reader.pos;
            return error.EndOfStream;
        }
        const ubytes: usize = @intCast(sbytes);
        file_reader.interface.toss(ubytes -| header.len);
        return ubytes;
    }

    if (is_darwin) sf: {
        // Try using sendfile on macOS.
        if (@atomicLoad(UseSendfile, &t.use_sendfile, .monotonic) == .disabled) break :sf;
        const offset = std.math.cast(std.c.off_t, file_reader.pos) orelse break :sf;
        var hdtr_data: std.c.sf_hdtr = undefined;
        var headers: [2]posix.iovec_const = undefined;
        var headers_i: u8 = 0;
        if (header.len != 0) {
            headers[headers_i] = .{ .base = header.ptr, .len = header.len };
            headers_i += 1;
        }
        if (reader_buffered.len != 0) {
            headers[headers_i] = .{ .base = reader_buffered.ptr, .len = reader_buffered.len };
            headers_i += 1;
        }
        const hdtr: ?*std.c.sf_hdtr = if (headers_i == 0) null else b: {
            hdtr_data = .{
                .headers = &headers,
                .hdr_cnt = headers_i,
                .trailers = null,
                .trl_cnt = 0,
            };
            break :b &hdtr_data;
        };
        const max_count = std.math.maxInt(i32); // Avoid EINVAL.
        var len: std.c.off_t = @min(file_limit, max_count);
        const flags = 0;
        const current_thread = Thread.getCurrent(t);
        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(std.c.sendfile(in_fd, out_fd, offset, &len, hdtr, flags))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .OPNOTSUPP, .NOTSOCK, .NOSYS => {
                    // Give calling code chance to observe before trying
                    // something else.
                    current_thread.endSyscall();
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
                .INTR => {
                    if (len == 0) {
                        try current_thread.checkCancel();
                        continue;
                    } else {
                        // Even if we are being canceled, there have been side
                        // effects, so it is better to report those side
                        // effects to the caller.
                        current_thread.endSyscall();
                        break;
                    }
                },
                .AGAIN => {
                    current_thread.endSyscall();
                    if (len == 0) return error.WouldBlock;
                    break;
                },
                else => |e| {
                    current_thread.endSyscall();
                    assert(error.Unexpected == switch (e) {
                        .NOTCONN => return error.BrokenPipe,
                        .IO => return error.InputOutput,
                        .PIPE => return error.BrokenPipe,
                        .BADF => |err| errnoBug(err),
                        .FAULT => |err| errnoBug(err),
                        .INVAL => |err| errnoBug(err),
                        else => |err| posix.unexpectedErrno(err),
                    });
                    // Give calling code chance to observe the error before trying
                    // something else.
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
            }
        }
        if (len == 0) {
            file_reader.size = file_reader.pos;
            return error.EndOfStream;
        }
        const u_len: usize = @bitCast(len);
        file_reader.interface.toss(u_len -| header.len);
        return u_len;
    }

    if (native_os == .linux) sf: {
        // Try using sendfile on Linux.
        if (@atomicLoad(UseSendfile, &t.use_sendfile, .monotonic) == .disabled) break :sf;
        // Linux sendfile does not support headers.
        if (header.len != 0 or reader_buffered.len != 0) {
            const n = try fileWriteStreaming(t, file, header, &.{limit.slice(reader_buffered)}, 1);
            file_reader.interface.toss(n -| header.len);
            return n;
        }
        const max_count = 0x7ffff000; // Avoid EINVAL.
        var off: std.os.linux.off_t = undefined;
        const off_ptr: ?*std.os.linux.off_t, const count: usize = switch (file_reader.mode) {
            .positional => o: {
                const size = file_reader.getSize() catch return 0;
                off = std.math.cast(std.os.linux.off_t, file_reader.pos) orelse return error.ReadFailed;
                break :o .{ &off, @min(@intFromEnum(limit), size - file_reader.pos, max_count) };
            },
            .streaming => .{ null, limit.minInt(max_count) },
            .streaming_simple, .positional_simple => break :sf,
            .failure => return error.ReadFailed,
        };
        const current_thread = Thread.getCurrent(t);
        try current_thread.beginSyscall();
        const n: usize = while (true) {
            const rc = sendfile_sym(out_fd, in_fd, off_ptr, count);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break @intCast(rc);
                },
                .NOSYS, .INVAL => {
                    // Give calling code chance to observe before trying
                    // something else.
                    current_thread.endSyscall();
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    assert(error.Unexpected == switch (e) {
                        .NOTCONN => return error.BrokenPipe, // `out_fd` is an unconnected socket
                        .AGAIN => return error.WouldBlock,
                        .IO => return error.InputOutput,
                        .PIPE => return error.BrokenPipe,
                        .NOMEM => return error.SystemResources,
                        .NXIO, .SPIPE => {
                            file_reader.mode = file_reader.mode.toStreaming();
                            const pos = file_reader.pos;
                            if (pos != 0) {
                                file_reader.pos = 0;
                                file_reader.seekBy(@intCast(pos)) catch {
                                    file_reader.mode = .failure;
                                    return error.ReadFailed;
                                };
                            }
                            return 0;
                        },
                        .BADF => |err| errnoBug(err), // Always a race condition.
                        .FAULT => |err| errnoBug(err), // Segmentation fault.
                        .OVERFLOW => |err| errnoBug(err), // We avoid passing too large of a `count`.
                        else => |err| posix.unexpectedErrno(err),
                    });
                    // Give calling code chance to observe the error before trying
                    // something else.
                    @atomicStore(UseSendfile, &t.use_sendfile, .disabled, .monotonic);
                    return 0;
                },
            }
        };
        if (n == 0) {
            file_reader.size = file_reader.pos;
            return error.EndOfStream;
        }
        file_reader.pos += n;
        return n;
    }

    if (have_copy_file_range) cfr: {
        if (@atomicLoad(UseCopyFileRange, &t.use_copy_file_range, .monotonic) == .disabled) break :cfr;
        if (header.len != 0 or reader_buffered.len != 0) {
            const n = try fileWriteStreaming(t, file, header, &.{limit.slice(reader_buffered)}, 1);
            file_reader.interface.toss(n -| header.len);
            return n;
        }
        var off_in: i64 = undefined;
        const off_in_ptr: ?*i64 = switch (file_reader.mode) {
            .positional_simple, .streaming_simple => return error.Unimplemented,
            .positional => p: {
                off_in = @intCast(file_reader.pos);
                break :p &off_in;
            },
            .streaming => null,
            .failure => return error.ReadFailed,
        };
        const current_thread = Thread.getCurrent(t);
        const n: usize = switch (native_os) {
            .linux => n: {
                try current_thread.beginSyscall();
                while (true) {
                    const rc = linux_copy_file_range_sys.copy_file_range(in_fd, off_in_ptr, out_fd, null, @intFromEnum(limit), 0);
                    switch (linux_copy_file_range_sys.errno(rc)) {
                        .SUCCESS => {
                            current_thread.endSyscall();
                            break :n @intCast(rc);
                        },
                        .INTR => {
                            try current_thread.checkCancel();
                            continue;
                        },
                        .OPNOTSUPP, .INVAL, .NOSYS => {
                            // Give calling code chance to observe before trying
                            // something else.
                            current_thread.endSyscall();
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                        else => |e| {
                            current_thread.endSyscall();
                            assert(error.Unexpected == switch (e) {
                                .FBIG => return error.FileTooBig,
                                .IO => return error.InputOutput,
                                .NOMEM => return error.SystemResources,
                                .NOSPC => return error.NoSpaceLeft,
                                .OVERFLOW => |err| errnoBug(err), // We avoid passing too large a count.
                                .PERM => return error.PermissionDenied,
                                .BUSY => return error.DeviceBusy,
                                .TXTBSY => return error.FileBusy,
                                // copy_file_range can still work but not on
                                // this pair of file descriptors.
                                .XDEV => return error.Unimplemented,
                                .ISDIR => |err| errnoBug(err),
                                .BADF => |err| errnoBug(err),
                                else => |err| posix.unexpectedErrno(err),
                            });
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                    }
                }
            },
            .freebsd => n: {
                try current_thread.beginSyscall();
                while (true) {
                    const rc = std.c.copy_file_range(in_fd, off_in_ptr, out_fd, null, @intFromEnum(limit), 0);
                    switch (std.c.errno(rc)) {
                        .SUCCESS => {
                            current_thread.endSyscall();
                            break :n @intCast(rc);
                        },
                        .INTR => {
                            try current_thread.checkCancel();
                            continue;
                        },
                        .OPNOTSUPP, .INVAL, .NOSYS => {
                            // Give calling code chance to observe before trying
                            // something else.
                            current_thread.endSyscall();
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                        else => |e| {
                            current_thread.endSyscall();
                            assert(error.Unexpected == switch (e) {
                                .FBIG => return error.FileTooBig,
                                .IO => return error.InputOutput,
                                .INTEGRITY => return error.CorruptedData,
                                .NOSPC => return error.NoSpaceLeft,
                                .ISDIR => |err| errnoBug(err),
                                .BADF => |err| errnoBug(err),
                                else => |err| posix.unexpectedErrno(err),
                            });
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                    }
                }
            },
            else => comptime unreachable,
        };
        if (n == 0) {
            file_reader.size = file_reader.pos;
            return error.EndOfStream;
        }
        file_reader.pos += n;
        return n;
    }

    return error.Unimplemented;
}

fn netWriteFile(
    userdata: ?*anyopaque,
    socket_handle: net.Socket.Handle,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
) net.Stream.Writer.WriteFileError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    _ = socket_handle;
    _ = header;
    _ = file_reader;
    _ = limit;
    @panic("TODO implement netWriteFile");
}

fn netWriteFileUnavailable(
    userdata: ?*anyopaque,
    socket_handle: net.Socket.Handle,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
) net.Stream.Writer.WriteFileError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    _ = socket_handle;
    _ = header;
    _ = file_reader;
    _ = limit;
    return error.NetworkDown;
}

fn fileWriteFilePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
    offset: u64,
) File.WriteFilePositionalError!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const reader_buffered = file_reader.interface.buffered();
    if (reader_buffered.len >= @intFromEnum(limit)) {
        const n = try fileWritePositional(t, file, header, &.{limit.slice(reader_buffered)}, 1, offset);
        file_reader.interface.toss(n -| header.len);
        return n;
    }
    const out_fd = file.handle;
    const in_fd = file_reader.file.handle;

    if (file_reader.size) |size| {
        if (size - file_reader.pos == 0) {
            if (reader_buffered.len != 0) {
                const n = try fileWritePositional(t, file, header, &.{limit.slice(reader_buffered)}, 1, offset);
                file_reader.interface.toss(n -| header.len);
                return n;
            } else {
                return error.EndOfStream;
            }
        }
    }

    if (have_copy_file_range) cfr: {
        if (@atomicLoad(UseCopyFileRange, &t.use_copy_file_range, .monotonic) == .disabled) break :cfr;
        if (header.len != 0 or reader_buffered.len != 0) {
            const n = try fileWritePositional(t, file, header, &.{limit.slice(reader_buffered)}, 1, offset);
            file_reader.interface.toss(n -| header.len);
            return n;
        }
        var off_in: i64 = undefined;
        const off_in_ptr: ?*i64 = switch (file_reader.mode) {
            .positional_simple, .streaming_simple => return error.Unimplemented,
            .positional => p: {
                off_in = @intCast(file_reader.pos);
                break :p &off_in;
            },
            .streaming => null,
            .failure => return error.ReadFailed,
        };
        var off_out: i64 = @intCast(offset);
        const current_thread = Thread.getCurrent(t);
        const n: usize = switch (native_os) {
            .linux => n: {
                try current_thread.beginSyscall();
                while (true) {
                    const rc = linux_copy_file_range_sys.copy_file_range(in_fd, off_in_ptr, out_fd, &off_out, @intFromEnum(limit), 0);
                    switch (linux_copy_file_range_sys.errno(rc)) {
                        .SUCCESS => {
                            current_thread.endSyscall();
                            break :n @intCast(rc);
                        },
                        .INTR => {
                            try current_thread.checkCancel();
                            continue;
                        },
                        .OPNOTSUPP, .INVAL, .NOSYS => {
                            // Give calling code chance to observe before trying
                            // something else.
                            current_thread.endSyscall();
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                        else => |e| {
                            current_thread.endSyscall();
                            assert(error.Unexpected == switch (e) {
                                .FBIG => return error.FileTooBig,
                                .IO => return error.InputOutput,
                                .NOMEM => return error.SystemResources,
                                .NOSPC => return error.NoSpaceLeft,
                                .OVERFLOW => return error.Unseekable,
                                .NXIO => return error.Unseekable,
                                .SPIPE => return error.Unseekable,
                                .PERM => return error.PermissionDenied,
                                .TXTBSY => return error.FileBusy,
                                // copy_file_range can still work but not on
                                // this pair of file descriptors.
                                .XDEV => return error.Unimplemented,
                                .ISDIR => |err| errnoBug(err),
                                .BADF => |err| errnoBug(err),
                                else => |err| posix.unexpectedErrno(err),
                            });
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                    }
                }
            },
            .freebsd => n: {
                try current_thread.beginSyscall();
                while (true) {
                    const rc = std.c.copy_file_range(in_fd, off_in_ptr, out_fd, &off_out, @intFromEnum(limit), 0);
                    switch (std.c.errno(rc)) {
                        .SUCCESS => {
                            current_thread.endSyscall();
                            break :n @intCast(rc);
                        },
                        .INTR => {
                            try current_thread.checkCancel();
                            continue;
                        },
                        .OPNOTSUPP, .INVAL, .NOSYS => {
                            // Give calling code chance to observe before trying
                            // something else.
                            current_thread.endSyscall();
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                        else => |e| {
                            current_thread.endSyscall();
                            assert(error.Unexpected == switch (e) {
                                .FBIG => return error.FileTooBig,
                                .IO => return error.InputOutput,
                                .INTEGRITY => return error.CorruptedData,
                                .NOSPC => return error.NoSpaceLeft,
                                .OVERFLOW => return error.Unseekable,
                                .NXIO => return error.Unseekable,
                                .SPIPE => return error.Unseekable,
                                .ISDIR => |err| errnoBug(err),
                                .BADF => |err| errnoBug(err),
                                else => |err| posix.unexpectedErrno(err),
                            });
                            @atomicStore(UseCopyFileRange, &t.use_copy_file_range, .disabled, .monotonic);
                            return 0;
                        },
                    }
                }
            },
            else => comptime unreachable,
        };
        if (n == 0) {
            file_reader.size = file_reader.pos;
            return error.EndOfStream;
        }
        file_reader.pos += n;
        return n;
    }

    if (is_darwin) fcf: {
        if (@atomicLoad(UseFcopyfile, &t.use_fcopyfile, .monotonic) == .disabled) break :fcf;
        if (file_reader.pos != 0) break :fcf;
        if (offset != 0) break :fcf;
        if (limit != .unlimited) break :fcf;
        const size = file_reader.getSize() catch break :fcf;
        if (header.len != 0 or reader_buffered.len != 0) {
            const n = try fileWritePositional(t, file, header, &.{limit.slice(reader_buffered)}, 1, offset);
            file_reader.interface.toss(n -| header.len);
            return n;
        }
        const current_thread = Thread.getCurrent(t);
        try current_thread.beginSyscall();
        while (true) {
            const rc = std.c.fcopyfile(in_fd, out_fd, null, .{ .DATA = true });
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    break;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                .OPNOTSUPP => {
                    // Give calling code chance to observe before trying
                    // something else.
                    current_thread.endSyscall();
                    @atomicStore(UseFcopyfile, &t.use_fcopyfile, .disabled, .monotonic);
                    return 0;
                },
                else => |e| {
                    current_thread.endSyscall();
                    assert(error.Unexpected == switch (e) {
                        .NOMEM => return error.SystemResources,
                        .INVAL => |err| errnoBug(err),
                        else => |err| posix.unexpectedErrno(err),
                    });
                    return 0;
                },
            }
        }
        file_reader.pos = size;
        return size;
    }

    return error.Unimplemented;
}

fn nowPosix(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    const clock_id: posix.clockid_t = clockToPosix(clock);
    var tp: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(clock_id, &tp))) {
        .SUCCESS => return timestampFromPosix(&tp),
        .INVAL => return error.UnsupportedClock,
        else => |err| return posix.unexpectedErrno(err),
    }
}

const now = switch (native_os) {
    .windows => nowWindows,
    .wasi => nowWasi,
    else => nowPosix,
};

fn nowWindows(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    switch (clock) {
        .real => {
            // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds
            // and uses the NTFS/Windows epoch, which is 1601-01-01.
            const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
            return .{ .nanoseconds = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns };
        },
        .awake, .boot => {
            // QPC on windows doesn't fail on >= XP/2000 and includes time suspended.
            const qpc = windows.QueryPerformanceCounter();
            // We don't need to cache QPF as it's internally just a memory read to KUSER_SHARED_DATA
            // (a read-only page of info updated and mapped by the kernel to all processes):
            // https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data
            // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
            const qpf = windows.QueryPerformanceFrequency();

            // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
            // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
            const common_qpf = 10_000_000;
            if (qpf == common_qpf) return .{ .nanoseconds = qpc * (std.time.ns_per_s / common_qpf) };

            // Convert to ns using fixed point.
            const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
            const result = (@as(u96, qpc) * scale) >> 32;
            return .{ .nanoseconds = @intCast(result) };
        },
        .cpu_process,
        .cpu_thread,
        => return error.UnsupportedClock,
    }
}

fn nowWasi(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.Error!Io.Timestamp {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    var ns: std.os.wasi.timestamp_t = undefined;
    const err = std.os.wasi.clock_time_get(clockToWasi(clock), 1, &ns);
    if (err != .SUCCESS) return error.Unexpected;
    return .fromNanoseconds(ns);
}

const sleep = switch (native_os) {
    .windows => sleepWindows,
    .wasi => sleepWasi,
    .linux => sleepLinux,
    else => sleepPosix,
};

fn sleepLinux(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const clock_id: posix.clockid_t = clockToPosix(switch (timeout) {
        .none => .awake,
        .duration => |d| d.clock,
        .deadline => |d| d.clock,
    });
    const deadline_nanoseconds: i96 = switch (timeout) {
        .none => std.math.maxInt(i96),
        .duration => |duration| duration.raw.nanoseconds,
        .deadline => |deadline| deadline.raw.nanoseconds,
    };
    var timespec: posix.timespec = timestampToPosix(deadline_nanoseconds);
    try current_thread.beginSyscall();
    while (true) {
        switch (std.os.linux.errno(std.os.linux.clock_nanosleep(clock_id, .{ .ABSTIME = switch (timeout) {
            .none, .duration => false,
            .deadline => true,
        } }, &timespec, &timespec))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => return error.UnsupportedClock,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn sleepWindows(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const t_io = ioBasic(t);
    try current_thread.checkCancel();
    const ms = ms: {
        const d = (try timeout.toDurationFromNow(t_io)) orelse
            break :ms std.math.maxInt(windows.DWORD);
        break :ms std.math.lossyCast(windows.DWORD, d.raw.toMilliseconds());
    };
    // TODO: alertable true with checkCancel in a loop plus deadline
    _ = windows.kernel32.SleepEx(ms, windows.FALSE);
}

fn sleepWasi(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const t_io = ioBasic(t);
    const w = std.os.wasi;

    const clock: w.subscription_clock_t = if (try timeout.toDurationFromNow(t_io)) |d| .{
        .id = clockToWasi(d.clock),
        .timeout = std.math.lossyCast(u64, d.raw.nanoseconds),
        .precision = 0,
        .flags = 0,
    } else .{
        .id = .MONOTONIC,
        .timeout = std.math.maxInt(u64),
        .precision = 0,
        .flags = 0,
    };
    const in: w.subscription_t = .{
        .userdata = 0,
        .u = .{
            .tag = .CLOCK,
            .u = .{ .clock = clock },
        },
    };
    var event: w.event_t = undefined;
    var nevents: usize = undefined;
    try current_thread.beginSyscall();
    _ = w.poll_oneoff(&in, &event, 1, &nevents);
    current_thread.endSyscall();
}

fn sleepPosix(userdata: ?*anyopaque, timeout: Io.Timeout) Io.SleepError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const t_io = ioBasic(t);
    const sec_type = @typeInfo(posix.timespec).@"struct".fields[0].type;
    const nsec_type = @typeInfo(posix.timespec).@"struct".fields[1].type;

    var timespec: posix.timespec = t: {
        const d = (try timeout.toDurationFromNow(t_io)) orelse break :t .{
            .sec = std.math.maxInt(sec_type),
            .nsec = std.math.maxInt(nsec_type),
        };
        break :t timestampToPosix(d.raw.toNanoseconds());
    };
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.nanosleep(&timespec, &timespec))) {
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            // This prong handles success as well as unexpected errors.
            else => return current_thread.endSyscall(),
        }
    }
}

fn select(userdata: ?*anyopaque, futures: []const *Io.AnyFuture) Io.Cancelable!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));

    var event: Io.Event = .unset;

    for (futures, 0..) |future, i| {
        const closure: *AsyncClosure = @ptrCast(@alignCast(future));
        if (@atomicRmw(?*Io.Event, &closure.select_condition, .Xchg, &event, .seq_cst) == AsyncClosure.done_event) {
            for (futures[0..i]) |cleanup_future| {
                const cleanup_closure: *AsyncClosure = @ptrCast(@alignCast(cleanup_future));
                if (@atomicRmw(?*Io.Event, &cleanup_closure.select_condition, .Xchg, null, .seq_cst) == AsyncClosure.done_event) {
                    cleanup_closure.event.waitUncancelable(ioBasic(t)); // Ensure no reference to our stack-allocated event.
                }
            }
            return i;
        }
    }

    try event.wait(ioBasic(t));

    var result: ?usize = null;
    for (futures, 0..) |future, i| {
        const closure: *AsyncClosure = @ptrCast(@alignCast(future));
        if (@atomicRmw(?*Io.Event, &closure.select_condition, .Xchg, null, .seq_cst) == AsyncClosure.done_event) {
            closure.event.waitUncancelable(ioBasic(t)); // Ensure no reference to our stack-allocated event.
            if (result == null) result = i; // In case multiple are ready, return first.
        }
    }
    return result.?;
}

fn netListenIpPosix(
    userdata: ?*anyopaque,
    address: IpAddress,
    options: IpAddress.ListenOptions,
) IpAddress.ListenError!net.Server {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(&address);
    const socket_fd = try openSocketPosix(current_thread, family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer posix.close(socket_fd);

    if (options.reuse_address) {
        try setSocketOption(current_thread, socket_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);
        if (@hasDecl(posix.SO, "REUSEPORT"))
            try setSocketOption(current_thread, socket_fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, 1);
    }

    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(&address, &storage);
    try posixBind(current_thread, socket_fd, &storage.any, addr_len);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.listen(socket_fd, options.kernel_backlog))) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }

    try posixGetSockName(current_thread, socket_fd, &storage.any, &addr_len);
    return .{
        .socket = .{
            .handle = socket_fd,
            .address = addressFromPosix(&storage),
        },
    };
}

fn netListenIpWindows(
    userdata: ?*anyopaque,
    address: IpAddress,
    options: IpAddress.ListenOptions,
) IpAddress.ListenError!net.Server {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(&address);
    const socket_handle = try openSocketWsa(t, current_thread, family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer closeSocketWindows(socket_handle);

    if (options.reuse_address)
        try setSocketOptionWsa(t, socket_handle, posix.SOL.SOCKET, posix.SO.REUSEADDR, 1);

    var storage: WsaAddress = undefined;
    var addr_len = addressToWsa(&address, &storage);

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.bind(socket_handle, &storage.any, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            break;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .EADDRINUSE => return error.AddressInUse,
                    .EADDRNOTAVAIL => return error.AddressUnavailable,
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EFAULT => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .ENOBUFS => return error.SystemResources,
                    .ENETDOWN => return error.NetworkDown,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.listen(socket_handle, options.kernel_backlog);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            break;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .ENETDOWN => return error.NetworkDown,
                    .EADDRINUSE => return error.AddressInUse,
                    .EISCONN => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .EMFILE, .ENOBUFS => return error.SystemResources,
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EOPNOTSUPP => |err| return wsaErrorBug(err),
                    .EINPROGRESS => |err| return wsaErrorBug(err),
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }

    try wsaGetSockName(t, current_thread, socket_handle, &storage.any, &addr_len);

    return .{
        .socket = .{
            .handle = socket_handle,
            .address = addressFromWsa(&storage),
        },
    };
}

fn netListenIpUnavailable(
    userdata: ?*anyopaque,
    address: IpAddress,
    options: IpAddress.ListenOptions,
) IpAddress.ListenError!net.Server {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

fn netListenUnixPosix(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
    options: net.UnixAddress.ListenOptions,
) net.UnixAddress.ListenError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const socket_fd = openSocketPosix(current_thread, posix.AF.UNIX, .{ .mode = .stream }) catch |err| switch (err) {
        error.ProtocolUnsupportedBySystem => return error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedByAddressFamily => return error.AddressFamilyUnsupported,
        error.SocketModeUnsupported => return error.AddressFamilyUnsupported,
        error.OptionUnsupported => return error.Unexpected,
        else => |e| return e,
    };
    errdefer posix.close(socket_fd);

    var storage: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(address, &storage);
    try posixBindUnix(current_thread, socket_fd, &storage.any, addr_len);

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.listen(socket_fd, options.kernel_backlog))) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }

    return socket_fd;
}

fn netListenUnixWindows(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
    options: net.UnixAddress.ListenOptions,
) net.UnixAddress.ListenError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const socket_handle = openSocketWsa(t, current_thread, posix.AF.UNIX, .{ .mode = .stream }) catch |err| switch (err) {
        error.ProtocolUnsupportedByAddressFamily => return error.AddressFamilyUnsupported,
        else => |e| return e,
    };
    errdefer closeSocketWindows(socket_handle);

    var storage: WsaAddress = undefined;
    const addr_len = addressUnixToWsa(address, &storage);

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.bind(socket_handle, &storage.any, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) break;
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .EADDRINUSE => return error.AddressInUse,
                    .EADDRNOTAVAIL => return error.AddressUnavailable,
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EFAULT => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .ENOBUFS => return error.SystemResources,
                    .ENETDOWN => return error.NetworkDown,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }

    while (true) {
        try current_thread.checkCancel();
        const rc = ws2_32.listen(socket_handle, options.kernel_backlog);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            return socket_handle;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => continue,
            .NOTINITIALISED => {
                try initializeWsa(t);
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .ENETDOWN => return error.NetworkDown,
                    .EADDRINUSE => return error.AddressInUse,
                    .EISCONN => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .EMFILE, .ENOBUFS => return error.SystemResources,
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EOPNOTSUPP => |err| return wsaErrorBug(err),
                    .EINPROGRESS => |err| return wsaErrorBug(err),
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }
}

fn netListenUnixUnavailable(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
    options: net.UnixAddress.ListenOptions,
) net.UnixAddress.ListenError!net.Socket.Handle {
    _ = userdata;
    _ = address;
    _ = options;
    return error.AddressFamilyUnsupported;
}

fn posixBindUnix(
    current_thread: *Thread,
    fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.bind(fd, addr, addr_len))) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .ADDRNOTAVAIL => return error.AddressUnavailable,
                    .NOMEM => return error.SystemResources,

                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .PERM => return error.PermissionDenied,

                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOTSOCK => |err| return errnoBug(err), // invalid `sockfd`
                    .FAULT => |err| return errnoBug(err), // invalid `addr` pointer
                    .NAMETOOLONG => |err| return errnoBug(err),
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn posixBind(
    current_thread: *Thread,
    socket_fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.bind(socket_fd, addr, addr_len))) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOTSOCK => |err| return errnoBug(err), // invalid `sockfd`
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .ADDRNOTAVAIL => return error.AddressUnavailable,
                    .FAULT => |err| return errnoBug(err), // invalid `addr` pointer
                    .NOMEM => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn posixConnect(
    current_thread: *Thread,
    socket_fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.connect(socket_fd, addr, addr_len))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ADDRNOTAVAIL => return error.AddressUnavailable,
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .AGAIN, .INPROGRESS => return error.WouldBlock,
                    .ALREADY => return error.ConnectionPending,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNREFUSED => return error.ConnectionRefused,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .FAULT => |err| return errnoBug(err),
                    .ISCONN => |err| return errnoBug(err),
                    .HOSTUNREACH => return error.HostUnreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTSOCK => |err| return errnoBug(err),
                    .PROTOTYPE => |err| return errnoBug(err),
                    .TIMEDOUT => return error.Timeout,
                    .CONNABORTED => |err| return errnoBug(err),
                    .ACCES => return error.AccessDenied,
                    .PERM => |err| return errnoBug(err),
                    .NOENT => |err| return errnoBug(err),
                    .NETDOWN => return error.NetworkDown,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn posixConnectUnix(
    current_thread: *Thread,
    fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.connect(fd, addr, addr_len))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .AGAIN => return error.WouldBlock,
                    .INPROGRESS => return error.WouldBlock,
                    .ACCES => return error.AccessDenied,

                    .LOOP => return error.SymLinkLoop,
                    .NOENT => return error.FileNotFound,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    .PERM => return error.PermissionDenied,

                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNABORTED => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .ISCONN => |err| return errnoBug(err),
                    .NOTSOCK => |err| return errnoBug(err),
                    .PROTOTYPE => |err| return errnoBug(err),
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn posixGetSockName(
    current_thread: *Thread,
    socket_fd: posix.fd_t,
    addr: *posix.sockaddr,
    addr_len: *posix.socklen_t,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.getsockname(socket_fd, addr, addr_len))) {
            .SUCCESS => {
                current_thread.endSyscall();
                break;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err), // invalid parameters
                    .NOTSOCK => |err| return errnoBug(err), // always a race condition
                    .NOBUFS => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn wsaGetSockName(
    t: *Threaded,
    current_thread: *Thread,
    handle: ws2_32.SOCKET,
    addr: *ws2_32.sockaddr,
    addr_len: *i32,
) !void {
    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.getsockname(handle, addr, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            return;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .ENETDOWN => return error.NetworkDown,
                    .EFAULT => |err| return wsaErrorBug(err),
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }
}

fn setSocketOption(current_thread: *Thread, fd: posix.fd_t, level: i32, opt_name: u32, option: u32) !void {
    const o: []const u8 = @ptrCast(&option);
    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.setsockopt(fd, level, opt_name, o.ptr, @intCast(o.len)))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOTSOCK => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn setSocketOptionWsa(t: *Threaded, socket: Io.net.Socket.Handle, level: i32, opt_name: u32, option: u32) !void {
    const o: []const u8 = @ptrCast(&option);
    const rc = ws2_32.setsockopt(socket, level, @bitCast(opt_name), o.ptr, @intCast(o.len));
    while (true) {
        if (rc != ws2_32.SOCKET_ERROR) return;
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => continue,
            .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
            .NOTINITIALISED => {
                try initializeWsa(t);
                continue;
            },
            .ENETDOWN => return error.NetworkDown,
            .EFAULT => |err| return wsaErrorBug(err),
            .ENOTSOCK => |err| return wsaErrorBug(err),
            .EINVAL => |err| return wsaErrorBug(err),
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
}

fn netConnectIpPosix(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!net.Stream {
    if (!have_networking) return error.NetworkDown;
    if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout");
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(address);
    const socket_fd = try openSocketPosix(current_thread, family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer posix.close(socket_fd);
    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try posixConnect(current_thread, socket_fd, &storage.any, addr_len);
    try posixGetSockName(current_thread, socket_fd, &storage.any, &addr_len);
    return .{ .socket = .{
        .handle = socket_fd,
        .address = addressFromPosix(&storage),
    } };
}

fn netConnectIpWindows(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!net.Stream {
    if (!have_networking) return error.NetworkDown;
    if (options.timeout != .none) @panic("TODO implement netConnectIpWindows with timeout");
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(address);
    const socket_handle = try openSocketWsa(t, current_thread, family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer closeSocketWindows(socket_handle);

    var storage: WsaAddress = undefined;
    var addr_len = addressToWsa(address, &storage);

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.connect(socket_handle, &storage.any, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            break;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .EADDRNOTAVAIL => return error.AddressUnavailable,
                    .ECONNREFUSED => return error.ConnectionRefused,
                    .ECONNRESET => return error.ConnectionResetByPeer,
                    .ETIMEDOUT => return error.Timeout,
                    .EHOSTUNREACH => return error.HostUnreachable,
                    .ENETUNREACH => return error.NetworkUnreachable,
                    .EFAULT => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .EISCONN => |err| return wsaErrorBug(err),
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EWOULDBLOCK => return error.WouldBlock,
                    .EACCES => return error.AccessDenied,
                    .ENOBUFS => return error.SystemResources,
                    .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }

    try wsaGetSockName(t, current_thread, socket_handle, &storage.any, &addr_len);

    return .{ .socket = .{
        .handle = socket_handle,
        .address = addressFromWsa(&storage),
    } };
}

fn netConnectIpUnavailable(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!net.Stream {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

fn netConnectUnixPosix(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
) net.UnixAddress.ConnectError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const socket_fd = openSocketPosix(current_thread, posix.AF.UNIX, .{ .mode = .stream }) catch |err| switch (err) {
        error.OptionUnsupported => return error.Unexpected,
        else => |e| return e,
    };
    errdefer posix.close(socket_fd);
    var storage: UnixAddress = undefined;
    const addr_len = addressUnixToPosix(address, &storage);
    try posixConnectUnix(current_thread, socket_fd, &storage.any, addr_len);
    return socket_fd;
}

fn netConnectUnixWindows(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
) net.UnixAddress.ConnectError!net.Socket.Handle {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const socket_handle = try openSocketWsa(t, current_thread, posix.AF.UNIX, .{ .mode = .stream });
    errdefer closeSocketWindows(socket_handle);
    var storage: WsaAddress = undefined;
    const addr_len = addressUnixToWsa(address, &storage);

    while (true) {
        const rc = ws2_32.connect(socket_handle, &storage.any, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) break;
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => continue,
            .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
            .NOTINITIALISED => {
                try initializeWsa(t);
                continue;
            },

            .ECONNREFUSED => return error.FileNotFound,
            .EFAULT => |err| return wsaErrorBug(err),
            .EINVAL => |err| return wsaErrorBug(err),
            .EISCONN => |err| return wsaErrorBug(err),
            .ENOTSOCK => |err| return wsaErrorBug(err),
            .EWOULDBLOCK => return error.WouldBlock,
            .EACCES => return error.AccessDenied,
            .ENOBUFS => return error.SystemResources,
            .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }

    return socket_handle;
}

fn netConnectUnixUnavailable(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
) net.UnixAddress.ConnectError!net.Socket.Handle {
    _ = userdata;
    _ = address;
    return error.AddressFamilyUnsupported;
}

fn netBindIpPosix(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.BindOptions,
) IpAddress.BindError!net.Socket {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(address);
    const socket_fd = try openSocketPosix(current_thread, family, options);
    errdefer posix.close(socket_fd);
    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try posixBind(current_thread, socket_fd, &storage.any, addr_len);
    try posixGetSockName(current_thread, socket_fd, &storage.any, &addr_len);
    return .{
        .handle = socket_fd,
        .address = addressFromPosix(&storage),
    };
}

fn netBindIpWindows(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.BindOptions,
) IpAddress.BindError!net.Socket {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const family = posixAddressFamily(address);
    const socket_handle = try openSocketWsa(t, current_thread, family, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer closeSocketWindows(socket_handle);

    var storage: WsaAddress = undefined;
    var addr_len = addressToWsa(address, &storage);

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.bind(socket_handle, &storage.any, addr_len);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            break;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .EADDRINUSE => return error.AddressInUse,
                    .EADDRNOTAVAIL => return error.AddressUnavailable,
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EFAULT => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .ENOBUFS => return error.SystemResources,
                    .ENETDOWN => return error.NetworkDown,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }

    try wsaGetSockName(t, current_thread, socket_handle, &storage.any, &addr_len);

    return .{
        .handle = socket_handle,
        .address = addressFromWsa(&storage),
    };
}

fn netBindIpUnavailable(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.BindOptions,
) IpAddress.BindError!net.Socket {
    _ = userdata;
    _ = address;
    _ = options;
    return error.NetworkDown;
}

fn openSocketPosix(
    current_thread: *Thread,
    family: posix.sa_family_t,
    options: IpAddress.BindOptions,
) error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    OptionUnsupported,
    Unexpected,
    Canceled,
}!posix.socket_t {
    const mode = posixSocketMode(options.mode);
    const protocol = posixProtocol(options.protocol);
    try current_thread.beginSyscall();
    const socket_fd = while (true) {
        const flags: u32 = mode | if (socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
        const socket_rc = posix.system.socket(family, flags, protocol);
        switch (posix.errno(socket_rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(socket_rc);
                errdefer posix.close(fd);
                if (socket_flags_unsupported) while (true) {
                    try current_thread.checkCancel();
                    switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
                        .SUCCESS => break,
                        .INTR => continue,
                        else => |err| {
                            current_thread.endSyscall();
                            return posix.unexpectedErrno(err);
                        },
                    }
                };
                current_thread.endSyscall();
                break fd;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .INVAL => return error.ProtocolUnsupportedBySystem,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                    .PROTOTYPE => return error.SocketModeUnsupported,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    errdefer posix.close(socket_fd);

    if (options.ip6_only) {
        if (posix.IPV6 == void) return error.OptionUnsupported;
        try setSocketOption(current_thread, socket_fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, 0);
    }

    return socket_fd;
}

fn openSocketWsa(
    t: *Threaded,
    current_thread: *Thread,
    family: posix.sa_family_t,
    options: IpAddress.BindOptions,
) !ws2_32.SOCKET {
    const mode = posixSocketMode(options.mode);
    const protocol = posixProtocol(options.protocol);
    const flags: u32 = ws2_32.WSA_FLAG_OVERLAPPED | ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.WSASocketW(family, @bitCast(mode), @bitCast(protocol), null, 0, flags);
        if (rc != ws2_32.INVALID_SOCKET) {
            current_thread.endSyscall();
            return rc;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .EMFILE => return error.ProcessFdQuotaExceeded,
                    .ENOBUFS => return error.SystemResources,
                    .EPROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }
}

fn netAcceptPosix(userdata: ?*anyopaque, listen_fd: net.Socket.Handle) net.Server.AcceptError!net.Stream {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    var storage: PosixAddress = undefined;
    var addr_len: posix.socklen_t = @sizeOf(PosixAddress);
    try current_thread.beginSyscall();
    const fd = while (true) {
        const rc = if (have_accept4)
            posix.system.accept4(listen_fd, &storage.any, &addr_len, posix.SOCK.CLOEXEC)
        else
            posix.system.accept(listen_fd, &storage.any, &addr_len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(rc);
                errdefer posix.close(fd);
                if (!have_accept4) while (true) {
                    try current_thread.checkCancel();
                    switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
                        .SUCCESS => break,
                        .INTR => continue,
                        else => |err| {
                            current_thread.endSyscall();
                            return posix.unexpectedErrno(err);
                        },
                    }
                };
                current_thread.endSyscall();
                break fd;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .AGAIN => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNABORTED => return error.ConnectionAborted,
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => return error.SocketNotListening,
                    .NOTSOCK => |err| return errnoBug(err),
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .OPNOTSUPP => |err| return errnoBug(err),
                    .PROTO => return error.ProtocolFailure,
                    .PERM => return error.BlockedByFirewall,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    };
    return .{ .socket = .{
        .handle = fd,
        .address = addressFromPosix(&storage),
    } };
}

fn netAcceptWindows(userdata: ?*anyopaque, listen_handle: net.Socket.Handle) net.Server.AcceptError!net.Stream {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    var storage: WsaAddress = undefined;
    var addr_len: i32 = @sizeOf(WsaAddress);
    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.accept(listen_handle, &storage.any, &addr_len);
        if (rc != ws2_32.INVALID_SOCKET) {
            current_thread.endSyscall();
            return .{ .socket = .{
                .handle = rc,
                .address = addressFromWsa(&storage),
            } };
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .ECONNRESET => return error.ConnectionAborted,
                    .EFAULT => |err| return wsaErrorBug(err),
                    .ENOTSOCK => |err| return wsaErrorBug(err),
                    .EINVAL => |err| return wsaErrorBug(err),
                    .EMFILE => return error.ProcessFdQuotaExceeded,
                    .ENETDOWN => return error.NetworkDown,
                    .ENOBUFS => return error.SystemResources,
                    .EOPNOTSUPP => |err| return wsaErrorBug(err),
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }
}

fn netAcceptUnavailable(userdata: ?*anyopaque, listen_handle: net.Socket.Handle) net.Server.AcceptError!net.Stream {
    _ = userdata;
    _ = listen_handle;
    return error.NetworkDown;
}

fn netReadPosix(userdata: ?*anyopaque, fd: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var iovecs_buffer: [max_iovecs_len]posix.iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len != 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    const dest = iovecs_buffer[0..i];
    assert(dest[0].len > 0);

    if (native_os == .wasi and !builtin.link_libc) {
        try current_thread.beginSyscall();
        while (true) {
            var n: usize = undefined;
            switch (std.os.wasi.fd_read(fd, dest.ptr, dest.len, &n)) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return n;
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err),
                        .FAULT => |err| return errnoBug(err),
                        .AGAIN => |err| return errnoBug(err),
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .NOTCONN => return error.SocketUnconnected,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        .TIMEDOUT => return error.Timeout,
                        .NOTCAPABLE => return error.AccessDenied,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.readv(fd, dest.ptr, @intCast(dest.len));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .AGAIN => |err| return errnoBug(err),
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketUnconnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.Timeout,
                    .PIPE => return error.SocketUnconnected,
                    .NETDOWN => return error.NetworkDown,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn netReadWindows(userdata: ?*anyopaque, handle: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const bufs = b: {
        var iovec_buffer: [max_iovecs_len]ws2_32.WSABUF = undefined;
        var i: usize = 0;
        var n: usize = 0;
        for (data) |buf| {
            if (iovec_buffer.len - i == 0) break;
            if (buf.len == 0) continue;
            if (std.math.cast(u32, buf.len)) |len| {
                iovec_buffer[i] = .{ .buf = buf.ptr, .len = len };
                i += 1;
                n += len;
                continue;
            }
            iovec_buffer[i] = .{ .buf = buf.ptr, .len = std.math.maxInt(u32) };
            i += 1;
            n += std.math.maxInt(u32);
            break;
        }

        const bufs = iovec_buffer[0..i];
        assert(bufs[0].len != 0);

        break :b bufs;
    };

    while (true) {
        try current_thread.checkCancel();

        var flags: u32 = 0;
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        var n: u32 = undefined;
        const rc = ws2_32.WSARecv(handle, bufs.ptr, @intCast(bufs.len), &n, &flags, &overlapped, null);
        if (rc != ws2_32.SOCKET_ERROR) return n;
        const wsa_error: ws2_32.WinsockError = switch (ws2_32.WSAGetLastError()) {
            .IO_PENDING => e: {
                var result_flags: u32 = undefined;
                const overlapped_rc = ws2_32.WSAGetOverlappedResult(
                    handle,
                    &overlapped,
                    &n,
                    windows.TRUE,
                    &result_flags,
                );
                if (overlapped_rc == windows.FALSE) {
                    break :e ws2_32.WSAGetLastError();
                } else {
                    return n;
                }
            },
            else => |err| err,
        };
        switch (wsa_error) {
            .EINTR => continue,
            .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
            .NOTINITIALISED => {
                try initializeWsa(t);
                continue;
            },

            .ECONNRESET => return error.ConnectionResetByPeer,
            .EFAULT => unreachable, // a pointer is not completely contained in user address space.
            .EINVAL => |err| return wsaErrorBug(err),
            .EMSGSIZE => |err| return wsaErrorBug(err),
            .ENETDOWN => return error.NetworkDown,
            .ENETRESET => return error.ConnectionResetByPeer,
            .ENOTCONN => return error.SocketUnconnected,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
}

fn netReadUnavailable(userdata: ?*anyopaque, fd: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    _ = userdata;
    _ = fd;
    _ = data;
    return error.NetworkDown;
}

fn netSendPosix(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    if (!have_networking) return .{ error.NetworkDown, 0 };
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const posix_flags: u32 =
        @as(u32, if (@hasDecl(posix.MSG, "CONFIRM") and flags.confirm) posix.MSG.CONFIRM else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "DONTROUTE") and flags.dont_route) posix.MSG.DONTROUTE else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "EOR") and flags.eor) posix.MSG.EOR else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "OOB") and flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (@hasDecl(posix.MSG, "FASTOPEN") and flags.fastopen) posix.MSG.FASTOPEN else 0) |
        posix.MSG.NOSIGNAL;

    var i: usize = 0;
    while (messages.len - i != 0) {
        if (have_sendmmsg) {
            i += netSendMany(current_thread, handle, messages[i..], posix_flags) catch |err| return .{ err, i };
            continue;
        }
        netSendOne(t, current_thread, handle, &messages[i], posix_flags) catch |err| return .{ err, i };
        i += 1;
    }
    return .{ null, i };
}

fn netSendWindows(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    if (!have_networking) return .{ error.NetworkDown, 0 };
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    _ = handle;
    _ = messages;
    _ = flags;
    @panic("TODO netSendWindows");
}

fn netSendUnavailable(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    _ = userdata;
    _ = handle;
    _ = messages;
    _ = flags;
    return .{ error.NetworkDown, 0 };
}

fn netSendOne(
    t: *Threaded,
    current_thread: *Thread,
    handle: net.Socket.Handle,
    message: *net.OutgoingMessage,
    flags: u32,
) net.Socket.SendError!void {
    var addr: PosixAddress = undefined;
    var iovec: posix.iovec_const = .{ .base = @constCast(message.data_ptr), .len = message.data_len };
    const msg: posix.msghdr_const = .{
        .name = &addr.any,
        .namelen = addressToPosix(message.address, &addr),
        .iov = (&iovec)[0..1],
        .iovlen = 1,
        // OS returns EINVAL if this pointer is invalid even if controllen is zero.
        .control = if (message.control.len == 0) null else @constCast(message.control.ptr),
        .controllen = @intCast(message.control.len),
        .flags = 0,
    };
    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.sendmsg(handle, &msg, flags);
        if (is_windows) {
            if (rc != ws2_32.SOCKET_ERROR) {
                current_thread.endSyscall();
                message.data_len = @intCast(rc);
                return;
            }
            switch (ws2_32.WSAGetLastError()) {
                .EINTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                .NOTINITIALISED => {
                    try initializeWsa(t);
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                        .EACCES => return error.AccessDenied,
                        .EADDRNOTAVAIL => return error.AddressUnavailable,
                        .ECONNRESET => return error.ConnectionResetByPeer,
                        .EMSGSIZE => return error.MessageOversize,
                        .ENOBUFS => return error.SystemResources,
                        .ENOTSOCK => return error.FileDescriptorNotASocket,
                        .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                        .EDESTADDRREQ => unreachable, // A destination address is required.
                        .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                        .EHOSTUNREACH => return error.NetworkUnreachable,
                        .EINVAL => unreachable,
                        .ENETDOWN => return error.NetworkDown,
                        .ENETRESET => return error.ConnectionResetByPeer,
                        .ENETUNREACH => return error.NetworkUnreachable,
                        .ENOTCONN => return error.SocketUnconnected,
                        .ESHUTDOWN => |err| return wsaErrorBug(err),
                        else => |err| return windows.unexpectedWSAError(err),
                    }
                },
            }
        }
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                message.data_len = @intCast(rc);
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => return error.AccessDenied,
                    .ALREADY => return error.FastOpenAlreadyInProgress,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .DESTADDRREQ => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .ISCONN => |err| return errnoBug(err),
                    .MSGSIZE => return error.MessageOversize,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTSOCK => |err| return errnoBug(err),
                    .OPNOTSUPP => |err| return errnoBug(err),
                    .PIPE => return error.SocketUnconnected,
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .HOSTUNREACH => return error.HostUnreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTCONN => return error.SocketUnconnected,
                    .NETDOWN => return error.NetworkDown,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn netSendMany(
    current_thread: *Thread,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: u32,
) net.Socket.SendError!usize {
    var msg_buffer: [64]posix.system.mmsghdr = undefined;
    var addr_buffer: [msg_buffer.len]PosixAddress = undefined;
    var iovecs_buffer: [msg_buffer.len]posix.iovec = undefined;
    const min_len: usize = @min(messages.len, msg_buffer.len);
    const clamped_messages = messages[0..min_len];
    const clamped_msgs = (&msg_buffer)[0..min_len];
    const clamped_addrs = (&addr_buffer)[0..min_len];
    const clamped_iovecs = (&iovecs_buffer)[0..min_len];

    for (clamped_messages, clamped_msgs, clamped_addrs, clamped_iovecs) |*message, *msg, *addr, *iovec| {
        iovec.* = .{ .base = @constCast(message.data_ptr), .len = message.data_len };
        msg.* = .{
            .hdr = .{
                .name = &addr.any,
                .namelen = addressToPosix(message.address, addr),
                .iov = iovec[0..1],
                .iovlen = 1,
                .control = @constCast(message.control.ptr),
                .controllen = message.control.len,
                .flags = 0,
            },
            .len = undefined, // Populated by calling sendmmsg below.
        };
    }

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.sendmmsg(handle, clamped_msgs.ptr, @intCast(clamped_msgs.len), flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                const n: usize = @intCast(rc);
                for (clamped_messages[0..n], clamped_msgs[0..n]) |*message, *msg| {
                    message.data_len = msg.len;
                }
                return n;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .AGAIN => |err| return errnoBug(err),
                    .ALREADY => return error.FastOpenAlreadyInProgress,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .DESTADDRREQ => |err| return errnoBug(err), // The socket is not connection-mode, and no peer address is set.
                    .FAULT => |err| return errnoBug(err), // An invalid user space address was specified for an argument.
                    .INVAL => |err| return errnoBug(err), // Invalid argument passed.
                    .ISCONN => |err| return errnoBug(err), // connection-mode socket was connected already but a recipient was specified
                    .MSGSIZE => return error.MessageOversize,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTSOCK => |err| return errnoBug(err), // The file descriptor sockfd does not refer to a socket.
                    .OPNOTSUPP => |err| return errnoBug(err), // Some bit in the flags argument is inappropriate for the socket type.
                    .PIPE => return error.SocketUnconnected,
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .HOSTUNREACH => return error.HostUnreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTCONN => return error.SocketUnconnected,
                    .NETDOWN => return error.NetworkDown,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn netReceivePosix(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    message_buffer: []net.IncomingMessage,
    data_buffer: []u8,
    flags: net.ReceiveFlags,
    timeout: Io.Timeout,
) struct { ?net.Socket.ReceiveTimeoutError, usize } {
    if (!have_networking) return .{ error.NetworkDown, 0 };
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    const t_io = io(t);

    // recvmmsg is useless, here's why:
    // * [timeout bug](https://bugzilla.kernel.org/show_bug.cgi?id=75371)
    // * it wants iovecs for each message but we have a better API: one data
    //   buffer to handle all the messages. The better API cannot be lowered to
    //   the split vectors though because reducing the buffer size might make
    //   some messages unreceivable.

    // So the strategy instead is to use non-blocking recvmsg calls, calling
    // poll() with timeout if the first one returns EAGAIN.
    const posix_flags: u32 =
        @as(u32, if (flags.oob) posix.MSG.OOB else 0) |
        @as(u32, if (flags.peek) posix.MSG.PEEK else 0) |
        @as(u32, if (flags.trunc) posix.MSG.TRUNC else 0) |
        posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL;

    var poll_fds: [1]posix.pollfd = .{
        .{
            .fd = handle,
            .events = posix.POLL.IN,
            .revents = undefined,
        },
    };
    var message_i: usize = 0;
    var data_i: usize = 0;

    const deadline = timeout.toDeadline(t_io) catch |err| return .{ err, message_i };

    recv: while (true) {
        if (message_buffer.len - message_i == 0) return .{ null, message_i };
        const message = &message_buffer[message_i];
        const remaining_data_buffer = data_buffer[data_i..];
        var storage: PosixAddress = undefined;
        var iov: posix.iovec = .{ .base = remaining_data_buffer.ptr, .len = remaining_data_buffer.len };
        var msg: posix.msghdr = .{
            .name = &storage.any,
            .namelen = @sizeOf(PosixAddress),
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = message.control.ptr,
            .controllen = @intCast(message.control.len),
            .flags = undefined,
        };

        current_thread.beginSyscall() catch |err| return .{ err, message_i };
        const recv_rc = posix.system.recvmsg(handle, &msg, posix_flags);
        current_thread.endSyscall();
        switch (posix.errno(recv_rc)) {
            .SUCCESS => {
                const data = remaining_data_buffer[0..@intCast(recv_rc)];
                data_i += data.len;
                message.* = .{
                    .from = addressFromPosix(&storage),
                    .data = data,
                    .control = if (msg.control) |ptr| @as([*]u8, @ptrCast(ptr))[0..msg.controllen] else message.control,
                    .flags = .{
                        .eor = (msg.flags & posix.MSG.EOR) != 0,
                        .trunc = (msg.flags & posix.MSG.TRUNC) != 0,
                        .ctrunc = (msg.flags & posix.MSG.CTRUNC) != 0,
                        .oob = (msg.flags & posix.MSG.OOB) != 0,
                        .errqueue = if (@hasDecl(posix.MSG, "ERRQUEUE")) (msg.flags & posix.MSG.ERRQUEUE) != 0 else false,
                    },
                };
                message_i += 1;
                continue;
            },
            .AGAIN => while (true) {
                if (message_i != 0) return .{ null, message_i };

                const max_poll_ms = std.math.maxInt(u31);
                const timeout_ms: u31 = if (deadline) |d| t: {
                    const duration = d.durationFromNow(t_io) catch |err| return .{ err, message_i };
                    if (duration.raw.nanoseconds <= 0) return .{ error.Timeout, message_i };
                    break :t @intCast(@min(max_poll_ms, duration.raw.toMilliseconds()));
                } else max_poll_ms;

                current_thread.beginSyscall() catch |err| return .{ err, message_i };
                const poll_rc = posix.system.poll(&poll_fds, poll_fds.len, timeout_ms);
                current_thread.endSyscall();

                switch (posix.errno(poll_rc)) {
                    .SUCCESS => {
                        if (poll_rc == 0) {
                            // Although spurious timeouts are OK, when no deadline
                            // is passed we must not return `error.Timeout`.
                            if (deadline == null) continue;
                            return .{ error.Timeout, message_i };
                        }
                        continue :recv;
                    },
                    .INTR => continue,

                    .FAULT => |err| return .{ errnoBug(err), message_i },
                    .INVAL => |err| return .{ errnoBug(err), message_i },
                    .NOMEM => return .{ error.SystemResources, message_i },
                    else => |err| return .{ posix.unexpectedErrno(err), message_i },
                }
            },
            .INTR => continue,

            .BADF => |err| return .{ errnoBug(err), message_i },
            .NFILE => return .{ error.SystemFdQuotaExceeded, message_i },
            .MFILE => return .{ error.ProcessFdQuotaExceeded, message_i },
            .FAULT => |err| return .{ errnoBug(err), message_i },
            .INVAL => |err| return .{ errnoBug(err), message_i },
            .NOBUFS => return .{ error.SystemResources, message_i },
            .NOMEM => return .{ error.SystemResources, message_i },
            .NOTCONN => return .{ error.SocketUnconnected, message_i },
            .NOTSOCK => |err| return .{ errnoBug(err), message_i },
            .MSGSIZE => return .{ error.MessageOversize, message_i },
            .PIPE => return .{ error.SocketUnconnected, message_i },
            .OPNOTSUPP => |err| return .{ errnoBug(err), message_i },
            .CONNRESET => return .{ error.ConnectionResetByPeer, message_i },
            .NETDOWN => return .{ error.NetworkDown, message_i },
            else => |err| return .{ posix.unexpectedErrno(err), message_i },
        }
    }
}

fn netReceiveWindows(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    message_buffer: []net.IncomingMessage,
    data_buffer: []u8,
    flags: net.ReceiveFlags,
    timeout: Io.Timeout,
) struct { ?net.Socket.ReceiveTimeoutError, usize } {
    if (!have_networking) return .{ error.NetworkDown, 0 };
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    @panic("TODO implement netReceiveWindows");
}

fn netReceiveUnavailable(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    message_buffer: []net.IncomingMessage,
    data_buffer: []u8,
    flags: net.ReceiveFlags,
    timeout: Io.Timeout,
) struct { ?net.Socket.ReceiveTimeoutError, usize } {
    _ = userdata;
    _ = handle;
    _ = message_buffer;
    _ = data_buffer;
    _ = flags;
    _ = timeout;
    return .{ error.NetworkDown, 0 };
}

fn netWritePosix(
    userdata: ?*anyopaque,
    fd: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    var iovecs: [max_iovecs_len]posix.iovec_const = undefined;
    var msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iovecs,
        .iovlen = 0,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    addBuf(&iovecs, &msg.iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &msg.iovlen, bytes);
    const pattern = data[data.len - 1];
    if (iovecs.len - msg.iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(&iovecs, &msg.iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                var backup_buffer: [splat_buffer_size]u8 = undefined;
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(&iovecs, &msg.iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - msg.iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(&iovecs, &msg.iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(&iovecs, &msg.iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                addBuf(&iovecs, &msg.iovlen, pattern);
            },
        },
    };
    const flags = posix.MSG.NOSIGNAL;

    try current_thread.beginSyscall();
    while (true) {
        const rc = posix.system.sendmsg(fd, &msg, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                current_thread.endSyscall();
                return @intCast(rc);
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ACCES => |err| return errnoBug(err),
                    .AGAIN => |err| return errnoBug(err),
                    .ALREADY => return error.FastOpenAlreadyInProgress,
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .DESTADDRREQ => |err| return errnoBug(err), // The socket is not connection-mode, and no peer address is set.
                    .FAULT => |err| return errnoBug(err), // An invalid user space address was specified for an argument.
                    .INVAL => |err| return errnoBug(err), // Invalid argument passed.
                    .ISCONN => |err| return errnoBug(err), // connection-mode socket was connected already but a recipient was specified
                    .MSGSIZE => |err| return errnoBug(err),
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTSOCK => |err| return errnoBug(err), // The file descriptor sockfd does not refer to a socket.
                    .OPNOTSUPP => |err| return errnoBug(err), // Some bit in the flags argument is inappropriate for the socket type.
                    .PIPE => return error.SocketUnconnected,
                    .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                    .HOSTUNREACH => return error.HostUnreachable,
                    .NETUNREACH => return error.NetworkUnreachable,
                    .NOTCONN => return error.SocketUnconnected,
                    .NETDOWN => return error.NetworkDown,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn netWriteWindows(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    comptime assert(native_os == .windows);

    var iovecs: [max_iovecs_len]ws2_32.WSABUF = undefined;
    var len: u32 = 0;
    addWsaBuf(&iovecs, &len, header);
    for (data[0 .. data.len - 1]) |bytes| addWsaBuf(&iovecs, &len, bytes);
    const pattern = data[data.len - 1];
    if (iovecs.len - len != 0) switch (splat) {
        0 => {},
        1 => addWsaBuf(&iovecs, &len, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                var backup_buffer: [64]u8 = undefined;
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addWsaBuf(&iovecs, &len, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and len < iovecs.len) {
                    addWsaBuf(&iovecs, &len, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addWsaBuf(&iovecs, &len, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - len)) |_| {
                addWsaBuf(&iovecs, &len, pattern);
            },
        },
    };

    while (true) {
        try current_thread.checkCancel();

        var n: u32 = undefined;
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        const rc = ws2_32.WSASend(handle, &iovecs, len, &n, 0, &overlapped, null);
        if (rc != ws2_32.SOCKET_ERROR) return n;
        const wsa_error: ws2_32.WinsockError = switch (ws2_32.WSAGetLastError()) {
            .IO_PENDING => e: {
                var result_flags: u32 = undefined;
                const overlapped_rc = ws2_32.WSAGetOverlappedResult(
                    handle,
                    &overlapped,
                    &n,
                    windows.TRUE,
                    &result_flags,
                );
                if (overlapped_rc == windows.FALSE) {
                    break :e ws2_32.WSAGetLastError();
                } else {
                    return n;
                }
            },
            else => |err| err,
        };
        switch (wsa_error) {
            .EINTR, .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => continue,
            .NOTINITIALISED => {
                try initializeWsa(t);
                continue;
            },

            .ECONNABORTED => return error.ConnectionResetByPeer,
            .ECONNRESET => return error.ConnectionResetByPeer,
            .EINVAL => return error.SocketUnconnected,
            .ENETDOWN => return error.NetworkDown,
            .ENETRESET => return error.ConnectionResetByPeer,
            .ENOBUFS => return error.SystemResources,
            .ENOTCONN => return error.SocketUnconnected,
            .ENOTSOCK => |err| return wsaErrorBug(err),
            .EOPNOTSUPP => |err| return wsaErrorBug(err),
            .ESHUTDOWN => |err| return wsaErrorBug(err),
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
}

fn addWsaBuf(v: []ws2_32.WSABUF, i: *u32, bytes: []const u8) void {
    const cap = std.math.maxInt(u32);
    var remaining = bytes;
    while (remaining.len > cap) {
        if (v.len - i.* == 0) return;
        v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = cap };
        i.* += 1;
        remaining = remaining[cap..];
    } else {
        @branchHint(.likely);
        if (v.len - i.* == 0) return;
        v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = @intCast(remaining.len) };
        i.* += 1;
    }
}

fn netWriteUnavailable(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    _ = userdata;
    _ = handle;
    _ = header;
    _ = data;
    _ = splat;
    return error.NetworkDown;
}

/// This is either usize or u32. Since, either is fine, let's use the same
/// `addBuf` function for both writing to a file and sending network messages.
const iovlen_t = switch (native_os) {
    .wasi => u32,
    else => @FieldType(posix.msghdr_const, "iovlen"),
};

fn addBuf(v: []posix.iovec_const, i: *iovlen_t, bytes: []const u8) void {
    // OS checks ptr addr before length so zero length vectors must be omitted.
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
    i.* += 1;
}

fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    _ = t;
    switch (native_os) {
        .windows => for (handles) |handle| closeSocketWindows(handle),
        else => for (handles) |handle| posix.close(handle),
    }
}

fn netCloseUnavailable(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    _ = userdata;
    _ = handles;
    unreachable; // How you gonna close something that was impossible to open?
}

fn netShutdownPosix(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const posix_how: i32 = switch (how) {
        .recv => posix.SHUT.RD,
        .send => posix.SHUT.WR,
        .both => posix.SHUT.RDWR,
    };

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.shutdown(handle, posix_how))) {
            .SUCCESS => {
                current_thread.endSyscall();
                return;
            },
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .BADF, .NOTSOCK, .INVAL => |err| return errnoBug(err),
                    .NOTCONN => return error.SocketUnconnected,
                    .NOBUFS => return error.SystemResources,
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}

fn netShutdownWindows(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    if (!have_networking) return error.NetworkDown;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    const wsa_how: i32 = switch (how) {
        .recv => ws2_32.SD_RECEIVE,
        .send => ws2_32.SD_SEND,
        .both => ws2_32.SD_BOTH,
    };

    try current_thread.beginSyscall();
    while (true) {
        const rc = ws2_32.shutdown(handle, wsa_how);
        if (rc != ws2_32.SOCKET_ERROR) {
            current_thread.endSyscall();
            return;
        }
        switch (ws2_32.WSAGetLastError()) {
            .EINTR => {
                try current_thread.checkCancel();
                continue;
            },
            .NOTINITIALISED => {
                try initializeWsa(t);
                try current_thread.checkCancel();
                continue;
            },
            else => |e| {
                current_thread.endSyscall();
                switch (e) {
                    .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                    .ECONNABORTED => return error.ConnectionAborted,
                    .ECONNRESET => return error.ConnectionResetByPeer,
                    .ENETDOWN => return error.NetworkDown,
                    .ENOTCONN => return error.SocketUnconnected,
                    .EINVAL, .ENOTSOCK => |err| return wsaErrorBug(err),
                    else => |err| return windows.unexpectedWSAError(err),
                }
            },
        }
    }
}

fn netShutdownUnavailable(_: ?*anyopaque, _: net.Socket.Handle, _: net.ShutdownHow) net.ShutdownError!void {
    unreachable; // How you gonna shutdown something that was impossible to open?
}

fn netInterfaceNameResolve(
    userdata: ?*anyopaque,
    name: *const net.Interface.Name,
) net.Interface.Name.ResolveError!net.Interface {
    if (!have_networking) return error.InterfaceNotFound;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (native_os == .linux) {
        const sock_fd = openSocketPosix(current_thread, posix.AF.UNIX, .{ .mode = .dgram }) catch |err| switch (err) {
            error.ProcessFdQuotaExceeded => return error.SystemResources,
            error.SystemFdQuotaExceeded => return error.SystemResources,
            error.AddressFamilyUnsupported => return error.Unexpected,
            error.ProtocolUnsupportedBySystem => return error.Unexpected,
            error.ProtocolUnsupportedByAddressFamily => return error.Unexpected,
            error.SocketModeUnsupported => return error.Unexpected,
            error.OptionUnsupported => return error.Unexpected,
            else => |e| return e,
        };
        defer posix.close(sock_fd);

        var ifr: posix.ifreq = .{
            .ifrn = .{ .name = @bitCast(name.bytes) },
            .ifru = undefined,
        };

        try current_thread.beginSyscall();
        while (true) {
            switch (posix.errno(posix.system.ioctl(sock_fd, posix.SIOCGIFINDEX, @intFromPtr(&ifr)))) {
                .SUCCESS => {
                    current_thread.endSyscall();
                    return .{ .index = @bitCast(ifr.ifru.ivalue) };
                },
                .INTR => {
                    try current_thread.checkCancel();
                    continue;
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .INVAL => |err| return errnoBug(err), // Bad parameters.
                        .NOTTY => |err| return errnoBug(err),
                        .NXIO => |err| return errnoBug(err),
                        .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                        .FAULT => |err| return errnoBug(err), // Bad pointer parameter.
                        .IO => |err| return errnoBug(err), // sock_fd is not a file descriptor
                        .NODEV => return error.InterfaceNotFound,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                },
            }
        }
    }

    if (native_os == .windows) {
        try current_thread.checkCancel();
        @panic("TODO implement netInterfaceNameResolve for Windows");
    }

    if (builtin.link_libc) {
        try current_thread.checkCancel();
        const index = std.c.if_nametoindex(&name.bytes);
        if (index == 0) return error.InterfaceNotFound;
        return .{ .index = @bitCast(index) };
    }

    @panic("unimplemented");
}

fn netInterfaceNameResolveUnavailable(
    userdata: ?*anyopaque,
    name: *const net.Interface.Name,
) net.Interface.Name.ResolveError!net.Interface {
    _ = userdata;
    _ = name;
    return error.InterfaceNotFound;
}

fn netInterfaceName(userdata: ?*anyopaque, interface: net.Interface) net.Interface.NameError!net.Interface.Name {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);
    try current_thread.checkCancel();

    if (native_os == .linux) {
        _ = interface;
        @panic("TODO implement netInterfaceName for linux");
    }

    if (native_os == .windows) {
        @panic("TODO implement netInterfaceName for windows");
    }

    if (builtin.link_libc) {
        @panic("TODO implement netInterfaceName for libc");
    }

    @panic("unimplemented");
}

fn netInterfaceNameUnavailable(userdata: ?*anyopaque, interface: net.Interface) net.Interface.NameError!net.Interface.Name {
    _ = userdata;
    _ = interface;
    return error.Unexpected;
}

fn netLookup(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) net.HostName.LookupError!void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    defer resolved.close(io(t));
    netLookupFallible(t, host_name, resolved, options) catch |err| switch (err) {
        error.Closed => unreachable, // `resolved` must not be closed until `netLookup` returns
        else => |e| return e,
    };
}

fn netLookupUnavailable(
    userdata: ?*anyopaque,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) net.HostName.LookupError!void {
    _ = host_name;
    _ = options;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    resolved.close(ioBasic(t));
    return error.NetworkDown;
}

fn netLookupFallible(
    t: *Threaded,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) (net.HostName.LookupError || Io.QueueClosedError)!void {
    if (!have_networking) return error.NetworkDown;

    const current_thread: *Thread = .getCurrent(t);
    const t_io = io(t);
    const name = host_name.bytes;
    assert(name.len <= HostName.max_len);

    if (is_windows) {
        var name_buffer: [HostName.max_len + 1]u16 = undefined;
        const name_len = std.unicode.wtf8ToWtf16Le(&name_buffer, host_name.bytes) catch
            unreachable; // HostName is prevalidated.
        name_buffer[name_len] = 0;
        const name_w = name_buffer[0..name_len :0];

        var port_buffer: [8]u8 = undefined;
        var port_buffer_wide: [8]u16 = undefined;
        const port = std.fmt.bufPrint(&port_buffer, "{d}", .{options.port}) catch
            unreachable; // `port_buffer` is big enough for decimal u16.
        for (port, port_buffer_wide[0..port.len]) |byte, *wide|
            wide.* = std.mem.nativeToLittle(u16, byte);
        port_buffer_wide[port.len] = 0;
        const port_w = port_buffer_wide[0..port.len :0];

        const hints: ws2_32.ADDRINFOEXW = .{
            .flags = .{ .NUMERICSERV = true },
            .family = if (options.family) |f| switch (f) {
                .ip4 => posix.AF.INET,
                .ip6 => posix.AF.INET6,
            } else posix.AF.UNSPEC,
            .socktype = posix.SOCK.STREAM,
            .protocol = posix.IPPROTO.TCP,
            .canonname = null,
            .addr = null,
            .addrlen = 0,
            .blob = null,
            .bloblen = 0,
            .provider = null,
            .next = null,
        };
        const cancel_handle: ?*windows.HANDLE = null;
        var res: *ws2_32.ADDRINFOEXW = undefined;
        const timeout: ?*ws2_32.timeval = null;
        while (true) {
            try current_thread.checkCancel(); // TODO make requestCancel call GetAddrInfoExCancel
            // TODO make this append to the queue eagerly rather than blocking until
            // the whole thing finishes
            const rc: ws2_32.WinsockError = @enumFromInt(ws2_32.GetAddrInfoExW(name_w, port_w, .DNS, null, &hints, &res, timeout, null, null, cancel_handle));
            switch (rc) {
                @as(ws2_32.WinsockError, @enumFromInt(0)) => break,
                .EINTR => continue,
                .ECANCELLED, .E_CANCELLED, .OPERATION_ABORTED => return error.Canceled,
                .NOTINITIALISED => {
                    try initializeWsa(t);
                    continue;
                },
                .TRY_AGAIN => return error.NameServerFailure,
                .EINVAL => |err| return wsaErrorBug(err),
                .NO_RECOVERY => return error.NameServerFailure,
                .EAFNOSUPPORT => return error.AddressFamilyUnsupported,
                .NOT_ENOUGH_MEMORY => return error.SystemResources,
                .HOST_NOT_FOUND => return error.UnknownHostName,
                .TYPE_NOT_FOUND => return error.ProtocolUnsupportedByAddressFamily,
                .ESOCKTNOSUPPORT => return error.ProtocolUnsupportedBySystem,
                else => |err| return windows.unexpectedWSAError(err),
            }
        }
        defer ws2_32.FreeAddrInfoExW(res);

        var it: ?*ws2_32.ADDRINFOEXW = res;
        var canon_name: ?[*:0]const u16 = null;
        while (it) |info| : (it = info.next) {
            const addr = info.addr orelse continue;
            const storage: WsaAddress = .{ .any = addr.* };
            try resolved.putOne(t_io, .{ .address = addressFromWsa(&storage) });

            if (info.canonname) |n| {
                if (canon_name == null) {
                    canon_name = n;
                }
            }
        }
        if (canon_name) |n| {
            const len = std.unicode.wtf16LeToWtf8(options.canonical_name_buffer, std.mem.sliceTo(n, 0));
            try resolved.putOne(t_io, .{ .canonical_name = .{
                .bytes = options.canonical_name_buffer[0..len],
            } });
        }
        return;
    }

    // On Linux, glibc provides getaddrinfo_a which is capable of supporting our semantics.
    // However, musl's POSIX-compliant getaddrinfo is not, so we bypass it.

    if (builtin.target.isGnuLibC()) {
        // TODO use getaddrinfo_a / gai_cancel
    }

    if (native_os == .linux) {
        if (options.family != .ip4) {
            if (IpAddress.parseIp6(name, options.port)) |addr| {
                try resolved.putAll(t_io, &.{
                    .{ .address = addr },
                    .{ .canonical_name = copyCanon(options.canonical_name_buffer, name) },
                });
                return;
            } else |_| {}
        }

        if (options.family != .ip6) {
            if (IpAddress.parseIp4(name, options.port)) |addr| {
                try resolved.putAll(t_io, &.{
                    .{ .address = addr },
                    .{ .canonical_name = copyCanon(options.canonical_name_buffer, name) },
                });
                return;
            } else |_| {}
        }

        lookupHosts(t, host_name, resolved, options) catch |err| switch (err) {
            error.UnknownHostName => {},
            else => |e| return e,
        };

        // RFC 6761 Section 6.3.3
        // Name resolution APIs and libraries SHOULD recognize
        // localhost names as special and SHOULD always return the IP
        // loopback address for address queries and negative responses
        // for all other query types.

        // Check for equal to "localhost(.)" or ends in ".localhost(.)"
        const localhost = if (name[name.len - 1] == '.') "localhost." else "localhost";
        if (std.mem.endsWith(u8, name, localhost) and
            (name.len == localhost.len or name[name.len - localhost.len] == '.'))
        {
            var results_buffer: [3]HostName.LookupResult = undefined;
            var results_index: usize = 0;
            if (options.family != .ip4) {
                results_buffer[results_index] = .{ .address = .{ .ip6 = .loopback(options.port) } };
                results_index += 1;
            }
            if (options.family != .ip6) {
                results_buffer[results_index] = .{ .address = .{ .ip4 = .loopback(options.port) } };
                results_index += 1;
            }
            const canon_name = "localhost";
            const canon_name_dest = options.canonical_name_buffer[0..canon_name.len];
            canon_name_dest.* = canon_name.*;
            results_buffer[results_index] = .{ .canonical_name = .{ .bytes = canon_name_dest } };
            results_index += 1;
            try resolved.putAll(t_io, results_buffer[0..results_index]);
            return;
        }

        return lookupDnsSearch(t, host_name, resolved, options);
    }

    if (native_os == .openbsd) {
        // TODO use getaddrinfo_async / asr_abort
    }

    if (native_os == .freebsd) {
        // TODO use dnsres_getaddrinfo
    }

    if (is_darwin) {
        // TODO use CFHostStartInfoResolution / CFHostCancelInfoResolution
    }

    if (builtin.link_libc) {
        // This operating system lacks a way to resolve asynchronously. We are
        // stuck with getaddrinfo.
        var name_buffer: [HostName.max_len + 1]u8 = undefined;
        @memcpy(name_buffer[0..host_name.bytes.len], host_name.bytes);
        name_buffer[host_name.bytes.len] = 0;
        const name_c = name_buffer[0..host_name.bytes.len :0];

        var port_buffer: [8]u8 = undefined;
        const port_c = std.fmt.bufPrintZ(&port_buffer, "{d}", .{options.port}) catch unreachable;

        const hints: posix.addrinfo = .{
            .flags = .{ .NUMERICSERV = true },
            .family = posix.AF.UNSPEC,
            .socktype = posix.SOCK.STREAM,
            .protocol = posix.IPPROTO.TCP,
            .canonname = null,
            .addr = null,
            .addrlen = 0,
            .next = null,
        };
        var res: ?*posix.addrinfo = null;
        try current_thread.beginSyscall();
        while (true) {
            switch (posix.system.getaddrinfo(name_c.ptr, port_c.ptr, &hints, &res)) {
                @as(posix.system.EAI, @enumFromInt(0)) => {
                    current_thread.endSyscall();
                    break;
                },
                .SYSTEM => switch (posix.errno(-1)) {
                    .INTR => {
                        try current_thread.checkCancel();
                        continue;
                    },
                    else => |e| {
                        current_thread.endSyscall();
                        return posix.unexpectedErrno(e);
                    },
                },
                else => |e| {
                    current_thread.endSyscall();
                    switch (e) {
                        .ADDRFAMILY => return error.AddressFamilyUnsupported,
                        .AGAIN => return error.NameServerFailure,
                        .FAIL => return error.NameServerFailure,
                        .FAMILY => return error.AddressFamilyUnsupported,
                        .MEMORY => return error.SystemResources,
                        .NODATA => return error.UnknownHostName,
                        .NONAME => return error.UnknownHostName,
                        else => return error.Unexpected,
                    }
                },
            }
        }
        defer if (res) |some| posix.system.freeaddrinfo(some);

        var it = res;
        var canon_name: ?[*:0]const u8 = null;
        while (it) |info| : (it = info.next) {
            const addr = info.addr orelse continue;
            const storage: PosixAddress = .{ .any = addr.* };
            try resolved.putOne(t_io, .{ .address = addressFromPosix(&storage) });

            if (info.canonname) |n| {
                if (canon_name == null) {
                    canon_name = n;
                }
            }
        }
        if (canon_name) |n| {
            try resolved.putOne(t_io, .{
                .canonical_name = copyCanon(options.canonical_name_buffer, std.mem.sliceTo(n, 0)),
            });
        }
        return;
    }

    return error.OptionUnsupported;
}

fn lockStderr(
    userdata: ?*anyopaque,
    buffer: []u8,
    terminal_mode: ?Io.Terminal.Mode,
) Io.Cancelable!Io.LockedStderr {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    // Only global mutex since this is Threaded.
    std.process.stderr_thread_mutex.lock();
    return initLockedStderr(t, buffer, terminal_mode);
}

fn tryLockStderr(
    userdata: ?*anyopaque,
    buffer: []u8,
    terminal_mode: ?Io.Terminal.Mode,
) Io.Cancelable!?Io.LockedStderr {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    // Only global mutex since this is Threaded.
    if (!std.process.stderr_thread_mutex.tryLock()) return null;
    return try initLockedStderr(t, buffer, terminal_mode);
}

fn initLockedStderr(
    t: *Threaded,
    buffer: []u8,
    terminal_mode: ?Io.Terminal.Mode,
) Io.Cancelable!Io.LockedStderr {
    if (!t.stderr_writer_initialized) {
        const io_t = ioBasic(t);
        if (is_windows) t.stderr_writer.file = .stderr();
        t.stderr_writer.io = io_t;
        t.stderr_writer_initialized = true;
        t.scanEnviron();
        const NO_COLOR = t.environ.exist.NO_COLOR;
        const CLICOLOR_FORCE = t.environ.exist.CLICOLOR_FORCE;
        t.stderr_mode = terminal_mode orelse try .detect(io_t, t.stderr_writer.file, NO_COLOR, CLICOLOR_FORCE);
    }
    std.Progress.clearWrittenWithEscapeCodes(&t.stderr_writer) catch |err| switch (err) {
        error.WriteFailed => switch (t.stderr_writer.err.?) {
            error.Canceled => |e| return e,
            else => {},
        },
    };
    t.stderr_writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => switch (t.stderr_writer.err.?) {
            error.Canceled => |e| return e,
            else => {},
        },
    };
    t.stderr_writer.interface.buffer = buffer;
    return .{
        .file_writer = &t.stderr_writer,
        .terminal_mode = terminal_mode orelse t.stderr_mode,
    };
}

fn unlockStderr(userdata: ?*anyopaque) void {
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    t.stderr_writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => switch (t.stderr_writer.err.?) {
            error.Canceled => recancel(t),
            else => {},
        },
    };
    t.stderr_writer.interface.end = 0;
    t.stderr_writer.interface.buffer = &.{};
    std.process.stderr_thread_mutex.unlock();
}

fn processSetCurrentDir(userdata: ?*anyopaque, dir: Dir) std.process.SetCurrentDirError!void {
    if (native_os == .wasi) return error.OperationUnsupported;
    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const current_thread = Thread.getCurrent(t);

    if (is_windows) {
        try current_thread.checkCancel();
        var dir_path_buffer: [windows.PATH_MAX_WIDE]u16 = undefined;
        // TODO move GetFinalPathNameByHandle logic into std.Io.Threaded and add cancel checks
        const dir_path = try windows.GetFinalPathNameByHandle(dir.handle, .{}, &dir_path_buffer);
        const path_len_bytes = std.math.cast(u16, dir_path.len * 2) orelse return error.NameTooLong;
        try current_thread.checkCancel();
        var nt_name: windows.UNICODE_STRING = .{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(dir_path.ptr),
        };
        switch (windows.ntdll.RtlSetCurrentDirectory_U(&nt_name)) {
            .SUCCESS => return,
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .NO_MEDIA_IN_DEVICE => return error.NoDevice,
            .INVALID_PARAMETER => |err| return windows.statusBug(err),
            .ACCESS_DENIED => return error.AccessDenied,
            .OBJECT_PATH_SYNTAX_BAD => |err| return windows.statusBug(err),
            .NOT_A_DIRECTORY => return error.NotDir,
            else => |status| return windows.unexpectedStatus(status),
        }
    }

    if (dir.handle == posix.AT.FDCWD) return;

    try current_thread.beginSyscall();
    while (true) {
        switch (posix.errno(posix.system.fchdir(dir.handle))) {
            .SUCCESS => return current_thread.endSyscall(),
            .INTR => {
                try current_thread.checkCancel();
                continue;
            },
            .ACCES => {
                current_thread.endSyscall();
                return error.AccessDenied;
            },
            .BADF => |err| {
                current_thread.endSyscall();
                return errnoBug(err);
            },
            .NOTDIR => {
                current_thread.endSyscall();
                return error.NotDir;
            },
            .IO => {
                current_thread.endSyscall();
                return error.FileSystem;
            },
            else => |err| {
                current_thread.endSyscall();
                return posix.unexpectedErrno(err);
            },
        }
    }
}

pub const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

const UnixAddress = extern union {
    any: posix.sockaddr,
    un: posix.sockaddr.un,
};

const WsaAddress = extern union {
    any: ws2_32.sockaddr,
    in: ws2_32.sockaddr.in,
    in6: ws2_32.sockaddr.in6,
    un: ws2_32.sockaddr.un,
};

pub fn posixAddressFamily(a: *const IpAddress) posix.sa_family_t {
    return switch (a.*) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
}

pub fn addressFromPosix(posix_address: *const PosixAddress) IpAddress {
    return switch (posix_address.any.family) {
        posix.AF.INET => .{ .ip4 = address4FromPosix(&posix_address.in) },
        posix.AF.INET6 => .{ .ip6 = address6FromPosix(&posix_address.in6) },
        else => .{ .ip4 = .loopback(0) },
    };
}

fn addressFromWsa(wsa_address: *const WsaAddress) IpAddress {
    return switch (wsa_address.any.family) {
        posix.AF.INET => .{ .ip4 = address4FromWsa(&wsa_address.in) },
        posix.AF.INET6 => .{ .ip6 = address6FromWsa(&wsa_address.in6) },
        else => .{ .ip4 = .loopback(0) },
    };
}

pub fn addressToPosix(a: *const IpAddress, storage: *PosixAddress) posix.socklen_t {
    return switch (a.*) {
        .ip4 => |ip4| {
            storage.in = address4ToPosix(ip4);
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |*ip6| {
            storage.in6 = address6ToPosix(ip6);
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn addressToWsa(a: *const IpAddress, storage: *WsaAddress) i32 {
    return switch (a.*) {
        .ip4 => |ip4| {
            storage.in = address4ToPosix(ip4);
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |*ip6| {
            storage.in6 = address6ToPosix(ip6);
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn addressUnixToPosix(a: *const net.UnixAddress, storage: *UnixAddress) posix.socklen_t {
    @memcpy(storage.un.path[0..a.path.len], a.path);
    storage.un.family = posix.AF.UNIX;
    storage.un.path[a.path.len] = 0;
    return @sizeOf(posix.sockaddr.un);
}

fn addressUnixToWsa(a: *const net.UnixAddress, storage: *WsaAddress) i32 {
    @memcpy(storage.un.path[0..a.path.len], a.path);
    storage.un.family = posix.AF.UNIX;
    storage.un.path[a.path.len] = 0;
    return @sizeOf(posix.sockaddr.un);
}

fn address4FromPosix(in: *const posix.sockaddr.in) net.Ip4Address {
    return .{
        .port = std.mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    };
}

fn address6FromPosix(in6: *const posix.sockaddr.in6) net.Ip6Address {
    return .{
        .port = std.mem.bigToNative(u16, in6.port),
        .bytes = in6.addr,
        .flow = in6.flowinfo,
        .interface = .{ .index = in6.scope_id },
    };
}

fn address4FromWsa(in: *const ws2_32.sockaddr.in) net.Ip4Address {
    return .{
        .port = std.mem.bigToNative(u16, in.port),
        .bytes = @bitCast(in.addr),
    };
}

fn address6FromWsa(in6: *const ws2_32.sockaddr.in6) net.Ip6Address {
    return .{
        .port = std.mem.bigToNative(u16, in6.port),
        .bytes = in6.addr,
        .flow = in6.flowinfo,
        .interface = .{ .index = in6.scope_id },
    };
}

fn address4ToPosix(a: net.Ip4Address) posix.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .addr = @bitCast(a.bytes),
    };
}

fn address6ToPosix(a: *const net.Ip6Address) posix.sockaddr.in6 {
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .flowinfo = a.flow,
        .addr = a.bytes,
        .scope_id = a.interface.index,
    };
}

pub fn errnoBug(err: posix.E) Io.UnexpectedError {
    if (is_debug) std.debug.panic("programmer bug caused syscall error: {t}", .{err});
    return error.Unexpected;
}

fn wsaErrorBug(err: ws2_32.WinsockError) Io.UnexpectedError {
    if (is_debug) std.debug.panic("programmer bug caused syscall error: {t}", .{err});
    return error.Unexpected;
}

pub fn posixSocketMode(mode: net.Socket.Mode) u32 {
    return switch (mode) {
        .stream => posix.SOCK.STREAM,
        .dgram => posix.SOCK.DGRAM,
        .seqpacket => posix.SOCK.SEQPACKET,
        .raw => posix.SOCK.RAW,
        .rdm => posix.SOCK.RDM,
    };
}

pub fn posixProtocol(protocol: ?net.Protocol) u32 {
    return @intFromEnum(protocol orelse return 0);
}

fn recoverableOsBugDetected() void {
    if (is_debug) unreachable;
}

fn clockToPosix(clock: Io.Clock) posix.clockid_t {
    return switch (clock) {
        .real => posix.CLOCK.REALTIME,
        .awake => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.UPTIME_RAW,
            else => posix.CLOCK.MONOTONIC,
        },
        .boot => switch (native_os) {
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => posix.CLOCK.MONOTONIC_RAW,
            // On freebsd derivatives, use MONOTONIC_FAST as currently there's
            // no precision tradeoff.
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            // On linux, use BOOTTIME instead of MONOTONIC as it ticks while
            // suspended.
            .linux => posix.CLOCK.BOOTTIME,
            // On other posix systems, MONOTONIC is generally the fastest and
            // ticks while suspended.
            else => posix.CLOCK.MONOTONIC,
        },
        .cpu_process => posix.CLOCK.PROCESS_CPUTIME_ID,
        .cpu_thread => posix.CLOCK.THREAD_CPUTIME_ID,
    };
}

fn clockToWasi(clock: Io.Clock) std.os.wasi.clockid_t {
    return switch (clock) {
        .real => .REALTIME,
        .awake => .MONOTONIC,
        .boot => .MONOTONIC,
        .cpu_process => .PROCESS_CPUTIME_ID,
        .cpu_thread => .THREAD_CPUTIME_ID,
    };
}

const linux_statx_request: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .ATIME = true,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .SIZE = true,
    .NLINK = true,
};

const linux_statx_check: std.os.linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .ATIME = false,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .SIZE = true,
    .NLINK = true,
};

fn statFromLinux(stx: *const std.os.linux.Statx) Io.UnexpectedError!File.Stat {
    const actual_mask_int: u32 = @bitCast(stx.mask);
    const wanted_mask_int: u32 = @bitCast(linux_statx_check);
    if ((actual_mask_int | wanted_mask_int) != actual_mask_int) return error.Unexpected;

    return .{
        .inode = stx.ino,
        .nlink = stx.nlink,
        .size = stx.size,
        .permissions = .fromMode(stx.mode),
        .kind = switch (stx.mode & std.os.linux.S.IFMT) {
            std.os.linux.S.IFDIR => .directory,
            std.os.linux.S.IFCHR => .character_device,
            std.os.linux.S.IFBLK => .block_device,
            std.os.linux.S.IFREG => .file,
            std.os.linux.S.IFIFO => .named_pipe,
            std.os.linux.S.IFLNK => .sym_link,
            std.os.linux.S.IFSOCK => .unix_domain_socket,
            else => .unknown,
        },
        .atime = if (!stx.mask.ATIME) null else .{
            .nanoseconds = @intCast(@as(i128, stx.atime.sec) * std.time.ns_per_s + stx.atime.nsec),
        },
        .mtime = .{ .nanoseconds = @intCast(@as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec) },
        .ctime = .{ .nanoseconds = @intCast(@as(i128, stx.ctime.sec) * std.time.ns_per_s + stx.ctime.nsec) },
    };
}

fn statFromPosix(st: *const posix.Stat) File.Stat {
    const atime = st.atime();
    const mtime = st.mtime();
    const ctime = st.ctime();
    return .{
        .inode = st.ino,
        .nlink = st.nlink,
        .size = @bitCast(st.size),
        .permissions = .fromMode(st.mode),
        .kind = k: {
            const m = st.mode & posix.S.IFMT;
            switch (m) {
                posix.S.IFBLK => break :k .block_device,
                posix.S.IFCHR => break :k .character_device,
                posix.S.IFDIR => break :k .directory,
                posix.S.IFIFO => break :k .named_pipe,
                posix.S.IFLNK => break :k .sym_link,
                posix.S.IFREG => break :k .file,
                posix.S.IFSOCK => break :k .unix_domain_socket,
                else => {},
            }
            if (native_os == .illumos) switch (m) {
                posix.S.IFDOOR => break :k .door,
                posix.S.IFPORT => break :k .event_port,
                else => {},
            };

            break :k .unknown;
        },
        .atime = timestampFromPosix(&atime),
        .mtime = timestampFromPosix(&mtime),
        .ctime = timestampFromPosix(&ctime),
    };
}

fn statFromWasi(st: *const std.os.wasi.filestat_t) File.Stat {
    return .{
        .inode = st.ino,
        .nlink = st.nlink,
        .size = @bitCast(st.size),
        .permissions = .default_file,
        .kind = switch (st.filetype) {
            .BLOCK_DEVICE => .block_device,
            .CHARACTER_DEVICE => .character_device,
            .DIRECTORY => .directory,
            .SYMBOLIC_LINK => .sym_link,
            .REGULAR_FILE => .file,
            .SOCKET_STREAM, .SOCKET_DGRAM => .unix_domain_socket,
            else => .unknown,
        },
        .atime = .fromNanoseconds(st.atim),
        .mtime = .fromNanoseconds(st.mtim),
        .ctime = .fromNanoseconds(st.ctim),
    };
}

fn timestampFromPosix(timespec: *const posix.timespec) Io.Timestamp {
    return .{ .nanoseconds = @intCast(@as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec) };
}

fn timestampToPosix(nanoseconds: i96) posix.timespec {
    if (builtin.zig_backend == .stage2_wasm) {
        // Workaround for https://codeberg.org/ziglang/zig/issues/30575
        return .{
            .sec = @intCast(@divTrunc(nanoseconds, std.time.ns_per_s)),
            .nsec = @intCast(@rem(nanoseconds, std.time.ns_per_s)),
        };
    }
    return .{
        .sec = @intCast(@divFloor(nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(nanoseconds, std.time.ns_per_s)),
    };
}

fn setTimestampToPosix(set_ts: File.SetTimestamp) posix.timespec {
    return switch (set_ts) {
        .unchanged => .OMIT,
        .now => .NOW,
        .new => |t| timestampToPosix(t.nanoseconds),
    };
}

fn pathToPosix(file_path: []const u8, buffer: *[posix.PATH_MAX]u8) Dir.PathNameError![:0]u8 {
    if (std.mem.containsAtLeastScalar2(u8, file_path, 0, 1)) return error.BadPathName;
    // >= rather than > to make room for the null byte
    if (file_path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..file_path.len], file_path);
    buffer[file_path.len] = 0;
    return buffer[0..file_path.len :0];
}

fn lookupDnsSearch(
    t: *Threaded,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) (HostName.LookupError || Io.QueueClosedError)!void {
    const t_io = io(t);
    const rc = HostName.ResolvConf.init(t_io) catch return error.ResolvConfParseFailed;

    // Count dots, suppress search when >=ndots or name ends in
    // a dot, which is an explicit request for global scope.
    const dots = std.mem.countScalar(u8, host_name.bytes, '.');
    const search_len = if (dots >= rc.ndots or std.mem.endsWith(u8, host_name.bytes, ".")) 0 else rc.search_len;
    const search = rc.search_buffer[0..search_len];

    var canon_name = host_name.bytes;

    // Strip final dot for canon, fail if multiple trailing dots.
    if (std.mem.endsWith(u8, canon_name, ".")) canon_name.len -= 1;
    if (std.mem.endsWith(u8, canon_name, ".")) return error.UnknownHostName;

    // Name with search domain appended is set up in `canon_name`. This
    // both provides the desired default canonical name (if the requested
    // name is not a CNAME record) and serves as a buffer for passing the
    // full requested name to `lookupDns`.
    @memcpy(options.canonical_name_buffer[0..canon_name.len], canon_name);
    options.canonical_name_buffer[canon_name.len] = '.';
    var it = std.mem.tokenizeAny(u8, search, " \t");
    while (it.next()) |token| {
        @memcpy(options.canonical_name_buffer[canon_name.len + 1 ..][0..token.len], token);
        const lookup_canon_name = options.canonical_name_buffer[0 .. canon_name.len + 1 + token.len];
        if (lookupDns(t, lookup_canon_name, &rc, resolved, options)) |result| {
            return result;
        } else |err| switch (err) {
            error.UnknownHostName => continue,
            else => |e| return e,
        }
    }

    const lookup_canon_name = options.canonical_name_buffer[0..canon_name.len];
    return lookupDns(t, lookup_canon_name, &rc, resolved, options);
}

fn lookupDns(
    t: *Threaded,
    lookup_canon_name: []const u8,
    rc: *const HostName.ResolvConf,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) (HostName.LookupError || Io.QueueClosedError)!void {
    const t_io = io(t);
    const family_records: [2]struct { af: IpAddress.Family, rr: HostName.DnsRecord } = .{
        .{ .af = .ip6, .rr = .A },
        .{ .af = .ip4, .rr = .AAAA },
    };
    var query_buffers: [2][280]u8 = undefined;
    var answer_buffer: [2 * 512]u8 = undefined;
    var queries_buffer: [2][]const u8 = undefined;
    var answers_buffer: [2][]const u8 = undefined;
    var nq: usize = 0;
    var answer_buffer_i: usize = 0;

    for (family_records) |fr| {
        if (options.family != fr.af) {
            const entropy = std.crypto.random.array(u8, 2);
            const len = writeResolutionQuery(&query_buffers[nq], 0, lookup_canon_name, 1, fr.rr, entropy);
            queries_buffer[nq] = query_buffers[nq][0..len];
            nq += 1;
        }
    }

    var ip4_mapped_buffer: [HostName.ResolvConf.max_nameservers]IpAddress = undefined;
    const ip4_mapped = ip4_mapped_buffer[0..rc.nameservers_len];
    var any_ip6 = false;
    for (rc.nameservers(), ip4_mapped) |*ns, *m| {
        m.* = .{ .ip6 = .fromAny(ns.*) };
        any_ip6 = any_ip6 or ns.* == .ip6;
    }
    var socket = s: {
        if (any_ip6) ip6: {
            const ip6_addr: IpAddress = .{ .ip6 = .unspecified(0) };
            const socket = ip6_addr.bind(t_io, .{ .ip6_only = true, .mode = .dgram }) catch |err| switch (err) {
                error.AddressFamilyUnsupported => break :ip6,
                else => |e| return e,
            };
            break :s socket;
        }
        any_ip6 = false;
        const ip4_addr: IpAddress = .{ .ip4 = .unspecified(0) };
        const socket = try ip4_addr.bind(t_io, .{ .mode = .dgram });
        break :s socket;
    };
    defer socket.close(t_io);

    const mapped_nameservers = if (any_ip6) ip4_mapped else rc.nameservers();
    const queries = queries_buffer[0..nq];
    const answers = answers_buffer[0..queries.len];
    var answers_remaining = answers.len;
    for (answers) |*answer| answer.len = 0;

    // boot clock is chosen because time the computer is suspended should count
    // against time spent waiting for external messages to arrive.
    const clock: Io.Clock = .boot;
    var now_ts = try clock.now(t_io);
    const final_ts = now_ts.addDuration(.fromSeconds(rc.timeout_seconds));
    const attempt_duration: Io.Duration = .{
        .nanoseconds = (std.time.ns_per_s / rc.attempts) * @as(i96, rc.timeout_seconds),
    };

    send: while (now_ts.nanoseconds < final_ts.nanoseconds) : (now_ts = try clock.now(t_io)) {
        const max_messages = queries_buffer.len * HostName.ResolvConf.max_nameservers;
        {
            var message_buffer: [max_messages]Io.net.OutgoingMessage = undefined;
            var message_i: usize = 0;
            for (queries, answers) |query, *answer| {
                if (answer.len != 0) continue;
                for (mapped_nameservers) |*ns| {
                    message_buffer[message_i] = .{
                        .address = ns,
                        .data_ptr = query.ptr,
                        .data_len = query.len,
                    };
                    message_i += 1;
                }
            }
            _ = netSendPosix(t, socket.handle, message_buffer[0..message_i], .{});
        }

        const timeout: Io.Timeout = .{ .deadline = .{
            .raw = now_ts.addDuration(attempt_duration),
            .clock = clock,
        } };

        while (true) {
            var message_buffer: [max_messages]Io.net.IncomingMessage = @splat(.init);
            const buf = answer_buffer[answer_buffer_i..];
            const recv_err, const recv_n = socket.receiveManyTimeout(t_io, &message_buffer, buf, .{}, timeout);
            for (message_buffer[0..recv_n]) |*received_message| {
                const reply = received_message.data;
                // Ignore non-identifiable packets.
                if (reply.len < 4) continue;

                // Ignore replies from addresses we didn't send to.
                const ns = for (mapped_nameservers) |*ns| {
                    if (received_message.from.eql(ns)) break ns;
                } else {
                    continue;
                };

                // Find which query this answer goes with, if any.
                const query, const answer = for (queries, answers) |query, *answer| {
                    if (reply[0] == query[0] and reply[1] == query[1]) break .{ query, answer };
                } else {
                    continue;
                };
                if (answer.len != 0) continue;

                // Only accept positive or negative responses; retry immediately on
                // server failure, and ignore all other codes such as refusal.
                switch (reply[3] & 15) {
                    0, 3 => {
                        answer.* = reply;
                        answer_buffer_i += reply.len;
                        answers_remaining -= 1;
                        if (answer_buffer.len - answer_buffer_i == 0) break :send;
                        if (answers_remaining == 0) break :send;
                    },
                    2 => {
                        var retry_message: Io.net.OutgoingMessage = .{
                            .address = ns,
                            .data_ptr = query.ptr,
                            .data_len = query.len,
                        };
                        _ = netSendPosix(t, socket.handle, (&retry_message)[0..1], .{});
                        continue;
                    },
                    else => continue,
                }
            }
            if (recv_err) |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => continue :send,
                else => continue,
            };
        }
    } else {
        return error.NameServerFailure;
    }

    var addresses_len: usize = 0;
    var canonical_name: ?HostName = null;

    for (answers) |answer| {
        var it = HostName.DnsResponse.init(answer) catch {
            // Here we could potentially add diagnostics to the results queue.
            continue;
        };
        while (it.next() catch {
            // Here we could potentially add diagnostics to the results queue.
            continue;
        }) |record| switch (record.rr) {
            .A => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 4) return error.InvalidDnsARecord;
                try resolved.putOne(t_io, .{ .address = .{ .ip4 = .{
                    .bytes = data[0..4].*,
                    .port = options.port,
                } } });
                addresses_len += 1;
            },
            .AAAA => {
                const data = record.packet[record.data_off..][0..record.data_len];
                if (data.len != 16) return error.InvalidDnsAAAARecord;
                try resolved.putOne(t_io, .{ .address = .{ .ip6 = .{
                    .bytes = data[0..16].*,
                    .port = options.port,
                } } });
                addresses_len += 1;
            },
            .CNAME => {
                _, canonical_name = HostName.expand(record.packet, record.data_off, options.canonical_name_buffer) catch
                    return error.InvalidDnsCnameRecord;
            },
            _ => continue,
        };
    }

    try resolved.putOne(t_io, .{ .canonical_name = canonical_name orelse .{ .bytes = lookup_canon_name } });
    if (addresses_len == 0) return error.NameServerFailure;
}

fn lookupHosts(
    t: *Threaded,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) !void {
    const t_io = io(t);
    const file = Dir.openFileAbsolute(t_io, "/etc/hosts", .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => return error.UnknownHostName,

        error.Canceled => |e| return e,

        else => {
            // Here we could add more detailed diagnostics to the results queue.
            return error.DetectingNetworkConfigurationFailed;
        },
    };
    defer file.close(t_io);

    var line_buf: [512]u8 = undefined;
    var file_reader = file.reader(t_io, &line_buf);
    return lookupHostsReader(t, host_name, resolved, options, &file_reader.interface) catch |err| switch (err) {
        error.ReadFailed => switch (file_reader.err.?) {
            error.Canceled => |e| return e,
            else => {
                // Here we could add more detailed diagnostics to the results queue.
                return error.DetectingNetworkConfigurationFailed;
            },
        },
        error.Canceled,
        error.Closed,
        error.UnknownHostName,
        => |e| return e,
    };
}

fn lookupHostsReader(
    t: *Threaded,
    host_name: HostName,
    resolved: *Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
    reader: *Io.Reader,
) error{ ReadFailed, Canceled, UnknownHostName, Closed }!void {
    const t_io = io(t);
    var addresses_len: usize = 0;
    var canonical_name: ?HostName = null;
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Skip lines that are too long.
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            },
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => break,
        };
        reader.toss(1);
        var split_it = std.mem.splitScalar(u8, line, '#');
        const no_comment_line = split_it.first();

        var line_it = std.mem.tokenizeAny(u8, no_comment_line, " \t");
        const ip_text = line_it.next() orelse continue;
        var first_name_text: ?[]const u8 = null;
        while (line_it.next()) |name_text| {
            if (std.mem.eql(u8, name_text, host_name.bytes)) {
                if (first_name_text == null) first_name_text = name_text;
                break;
            }
        } else continue;

        if (canonical_name == null) {
            if (HostName.init(first_name_text.?)) |name_text| {
                if (name_text.bytes.len <= options.canonical_name_buffer.len) {
                    const canonical_name_dest = options.canonical_name_buffer[0..name_text.bytes.len];
                    @memcpy(canonical_name_dest, name_text.bytes);
                    canonical_name = .{ .bytes = canonical_name_dest };
                }
            } else |_| {}
        }

        if (options.family != .ip6) {
            if (IpAddress.parseIp4(ip_text, options.port)) |addr| {
                try resolved.putOne(t_io, .{ .address = addr });
                addresses_len += 1;
            } else |_| {}
        }
        if (options.family != .ip4) {
            if (IpAddress.parseIp6(ip_text, options.port)) |addr| {
                try resolved.putOne(t_io, .{ .address = addr });
                addresses_len += 1;
            } else |_| {}
        }
    }

    if (canonical_name) |canon_name| try resolved.putOne(t_io, .{ .canonical_name = canon_name });
    if (addresses_len == 0) return error.UnknownHostName;
}

/// Writes DNS resolution query packet data to `w`; at most 280 bytes.
fn writeResolutionQuery(q: *[280]u8, op: u4, dname: []const u8, class: u8, ty: HostName.DnsRecord, entropy: [2]u8) usize {
    // This implementation is ported from musl libc.
    // A more idiomatic "ziggy" implementation would be welcome.
    var name = dname;
    if (std.mem.endsWith(u8, name, ".")) name.len -= 1;
    assert(name.len <= 253);
    const n = 17 + name.len + @intFromBool(name.len != 0);

    // Construct query template - ID will be filled later
    q[0..2].* = entropy;
    @memset(q[2..n], 0);
    q[2] = @as(u8, op) * 8 + 1;
    q[5] = 1;
    @memcpy(q[13..][0..name.len], name);
    var i: usize = 13;
    var j: usize = undefined;
    while (q[i] != 0) : (i = j + 1) {
        j = i;
        while (q[j] != 0 and q[j] != '.') : (j += 1) {}
        // TODO determine the circumstances for this and whether or
        // not this should be an error.
        if (j - i - 1 > 62) unreachable;
        q[i - 1] = @intCast(j - i);
    }
    q[i + 1] = @intFromEnum(ty);
    q[i + 3] = class;
    return n;
}

fn copyCanon(canonical_name_buffer: *[HostName.max_len]u8, name: []const u8) HostName {
    const dest = canonical_name_buffer[0..name.len];
    @memcpy(dest, name);
    return .{ .bytes = dest };
}

/// Darwin XNU 7195.50.7.100.1 introduced __ulock_wait2 and migrated code paths (notably pthread_cond_t) towards it:
/// https://github.com/apple/darwin-xnu/commit/d4061fb0260b3ed486147341b72468f836ed6c8f#diff-08f993cc40af475663274687b7c326cc6c3031e0db3ac8de7b24624610616be6
///
/// This XNU version appears to correspond to 11.0.1:
/// https://kernelshaman.blogspot.com/2021/01/building-xnu-for-macos-big-sur-1101.html
///
/// ulock_wait() uses 32-bit micro-second timeouts where 0 = INFINITE or no-timeout
/// ulock_wait2() uses 64-bit nano-second timeouts (with the same convention)
const darwin_supports_ulock_wait2 = builtin.os.version_range.semver.min.major >= 11;

fn closeSocketWindows(s: ws2_32.SOCKET) void {
    const rc = ws2_32.closesocket(s);
    if (is_debug) switch (rc) {
        0 => {},
        ws2_32.SOCKET_ERROR => switch (ws2_32.WSAGetLastError()) {
            else => recoverableOsBugDetected(),
        },
        else => recoverableOsBugDetected(),
    };
}

const Wsa = struct {
    status: Status = .uninitialized,
    mutex: Io.Mutex = .init,
    init_error: ?Wsa.InitError = null,

    const Status = enum { uninitialized, initialized, failure };

    const InitError = error{
        ProcessFdQuotaExceeded,
        NetworkDown,
        VersionUnsupported,
        BlockingOperationInProgress,
    } || Io.UnexpectedError;
};

fn initializeWsa(t: *Threaded) error{ NetworkDown, Canceled }!void {
    const t_io = io(t);
    const wsa = &t.wsa;
    try wsa.mutex.lock(t_io);
    defer wsa.mutex.unlock(t_io);
    switch (wsa.status) {
        .uninitialized => {
            var wsa_data: ws2_32.WSADATA = undefined;
            const minor_version = 2;
            const major_version = 2;
            switch (ws2_32.WSAStartup((@as(windows.WORD, minor_version) << 8) | major_version, &wsa_data)) {
                0 => {
                    wsa.status = .initialized;
                    return;
                },
                else => |err_int| {
                    wsa.status = .failure;
                    wsa.init_error = switch (@as(ws2_32.WinsockError, @enumFromInt(@as(u16, @intCast(err_int))))) {
                        .SYSNOTREADY => error.NetworkDown,
                        .VERNOTSUPPORTED => error.VersionUnsupported,
                        .EINPROGRESS => error.BlockingOperationInProgress,
                        .EPROCLIM => error.ProcessFdQuotaExceeded,
                        else => |err| windows.unexpectedWSAError(err),
                    };
                },
            }
        },
        .initialized => return,
        .failure => {},
    }
    return error.NetworkDown;
}

fn doNothingSignalHandler(_: posix.SIG) callconv(.c) void {}

const pthreads_futex = struct {
    const c = std.c;
    const atomic = std.atomic;

    const Event = struct {
        cond: c.pthread_cond_t,
        mutex: c.pthread_mutex_t,
        state: enum { empty, waiting, notified },

        fn init(self: *Event) void {
            // Use static init instead of pthread_cond/mutex_init() since this is generally faster.
            self.cond = .{};
            self.mutex = .{};
            self.state = .empty;
        }

        fn deinit(self: *Event) void {
            // Some platforms reportedly give EINVAL for statically initialized pthread types.
            const rc = c.pthread_cond_destroy(&self.cond);
            assert(rc == .SUCCESS or rc == .INVAL);

            const rm = c.pthread_mutex_destroy(&self.mutex);
            assert(rm == .SUCCESS or rm == .INVAL);

            self.* = undefined;
        }

        fn wait(self: *Event, timeout: ?u64) error{Timeout}!void {
            assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
            defer assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

            // Early return if the event was already set.
            if (self.state == .notified) {
                return;
            }

            // Compute the absolute timeout if one was specified.
            // POSIX requires that REALTIME is used by default for the pthread timedwait functions.
            // This can be changed with pthread_condattr_setclock, but it's an extension and may not be available everywhere.
            var ts: c.timespec = undefined;
            if (timeout) |timeout_ns| {
                ts = std.posix.clock_gettime(c.CLOCK.REALTIME) catch return error.Timeout;
                ts.sec +|= @as(@TypeOf(ts.sec), @intCast(timeout_ns / std.time.ns_per_s));
                ts.nsec += @as(@TypeOf(ts.nsec), @intCast(timeout_ns % std.time.ns_per_s));

                if (ts.nsec >= std.time.ns_per_s) {
                    ts.sec +|= 1;
                    ts.nsec -= std.time.ns_per_s;
                }
            }

            // Start waiting on the event - there can be only one thread waiting.
            assert(self.state == .empty);
            self.state = .waiting;

            while (true) {
                // Block using either pthread_cond_wait or pthread_cond_timewait if there's an absolute timeout.
                const rc = blk: {
                    if (timeout == null) break :blk c.pthread_cond_wait(&self.cond, &self.mutex);
                    break :blk c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
                };

                // After waking up, check if the event was set.
                if (self.state == .notified) {
                    return;
                }

                assert(self.state == .waiting);
                switch (rc) {
                    .SUCCESS => {},
                    .TIMEDOUT => {
                        // If timed out, reset the event to avoid the set() thread doing an unnecessary signal().
                        self.state = .empty;
                        return error.Timeout;
                    },
                    .INVAL => recoverableOsBugDetected(), // cond, mutex, and potentially ts should all be valid
                    .PERM => recoverableOsBugDetected(), // mutex is locked when cond_*wait() functions are called
                    else => recoverableOsBugDetected(),
                }
            }
        }

        fn set(self: *Event) void {
            assert(c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
            defer assert(c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);

            // Make sure that multiple calls to set() were not done on the same Event.
            const old_state = self.state;
            assert(old_state != .notified);

            // Mark the event as set and wake up the waiting thread if there was one.
            // This must be done while the mutex as the wait() thread could deallocate
            // the condition variable once it observes the new state, potentially causing a UAF if done unlocked.
            self.state = .notified;
            if (old_state == .waiting) {
                assert(c.pthread_cond_signal(&self.cond) == .SUCCESS);
            }
        }
    };

    const Treap = std.Treap(usize, std.math.order);
    const Waiter = struct {
        node: Treap.Node,
        prev: ?*Waiter,
        next: ?*Waiter,
        tail: ?*Waiter,
        is_queued: bool,
        event: Event,
    };

    // An unordered set of Waiters
    const WaitList = struct {
        top: ?*Waiter = null,
        len: usize = 0,

        fn push(self: *WaitList, waiter: *Waiter) void {
            waiter.next = self.top;
            self.top = waiter;
            self.len += 1;
        }

        fn pop(self: *WaitList) ?*Waiter {
            const waiter = self.top orelse return null;
            self.top = waiter.next;
            self.len -= 1;
            return waiter;
        }
    };

    const WaitQueue = struct {
        fn insert(treap: *Treap, address: usize, waiter: *Waiter) void {
            // prepare the waiter to be inserted.
            waiter.next = null;
            waiter.is_queued = true;

            // Find the wait queue entry associated with the address.
            // If there isn't a wait queue on the address, this waiter creates the queue.
            var entry = treap.getEntryFor(address);
            const entry_node = entry.node orelse {
                waiter.prev = null;
                waiter.tail = waiter;
                entry.set(&waiter.node);
                return;
            };

            // There's a wait queue on the address; get the queue head and tail.
            const head: *Waiter = @fieldParentPtr("node", entry_node);
            const tail = head.tail orelse unreachable;

            // Push the waiter to the tail by replacing it and linking to the previous tail.
            head.tail = waiter;
            tail.next = waiter;
            waiter.prev = tail;
        }

        fn remove(treap: *Treap, address: usize, max_waiters: usize) WaitList {
            // Find the wait queue associated with this address and get the head/tail if any.
            var entry = treap.getEntryFor(address);
            var queue_head: ?*Waiter = if (entry.node) |node| @fieldParentPtr("node", node) else null;
            const queue_tail = if (queue_head) |head| head.tail else null;

            // Once we're done updating the head, fix it's tail pointer and update the treap's queue head as well.
            defer entry.set(blk: {
                const new_head = queue_head orelse break :blk null;
                new_head.tail = queue_tail;
                break :blk &new_head.node;
            });

            var removed = WaitList{};
            while (removed.len < max_waiters) {
                // dequeue and collect waiters from their wait queue.
                const waiter = queue_head orelse break;
                queue_head = waiter.next;
                removed.push(waiter);

                // When dequeueing, we must mark is_queued as false.
                // This ensures that a waiter which calls tryRemove() returns false.
                assert(waiter.is_queued);
                waiter.is_queued = false;
            }

            return removed;
        }

        fn tryRemove(treap: *Treap, address: usize, waiter: *Waiter) bool {
            if (!waiter.is_queued) {
                return false;
            }

            queue_remove: {
                // Find the wait queue associated with the address.
                var entry = blk: {
                    // A waiter without a previous link means it's the queue head that's in the treap so we can avoid lookup.
                    if (waiter.prev == null) {
                        assert(waiter.node.key == address);
                        break :blk treap.getEntryForExisting(&waiter.node);
                    }
                    break :blk treap.getEntryFor(address);
                };

                // The queue head and tail must exist if we're removing a queued waiter.
                const head: *Waiter = @fieldParentPtr("node", entry.node orelse unreachable);
                const tail = head.tail orelse unreachable;

                // A waiter with a previous link is never the head of the queue.
                if (waiter.prev) |prev| {
                    assert(waiter != head);
                    prev.next = waiter.next;

                    // A waiter with both a previous and next link is in the middle.
                    // We only need to update the surrounding waiter's links to remove it.
                    if (waiter.next) |next| {
                        assert(waiter != tail);
                        next.prev = waiter.prev;
                        break :queue_remove;
                    }

                    // A waiter with a previous but no next link means it's the tail of the queue.
                    // In that case, we need to update the head's tail reference.
                    assert(waiter == tail);
                    head.tail = waiter.prev;
                    break :queue_remove;
                }

                // A waiter with no previous link means it's the queue head of queue.
                // We must replace (or remove) the head waiter reference in the treap.
                assert(waiter == head);
                entry.set(blk: {
                    const new_head = waiter.next orelse break :blk null;
                    new_head.tail = head.tail;
                    break :blk &new_head.node;
                });
            }

            // Mark the waiter as successfully removed.
            waiter.is_queued = false;
            return true;
        }
    };

    const Bucket = struct {
        mutex: c.pthread_mutex_t align(atomic.cache_line) = .{},
        pending: atomic.Value(usize) = atomic.Value(usize).init(0),
        treap: Treap = .{},

        // Global array of buckets that addresses map to.
        // Bucket array size is pretty much arbitrary here, but it must be a power of two for fibonacci hashing.
        var buckets = [_]Bucket{.{}} ** @bitSizeOf(usize);

        // https://github.com/Amanieu/parking_lot/blob/1cf12744d097233316afa6c8b7d37389e4211756/core/src/parking_lot.rs#L343-L353
        fn from(address: usize) *Bucket {
            // The upper `@bitSizeOf(usize)` bits of the fibonacci golden ratio.
            // Hashing this via (h * k) >> (64 - b) where k=golden-ration and b=bitsize-of-array
            // evenly lays out h=hash values over the bit range even when the hash has poor entropy (identity-hash for pointers).
            const max_multiplier_bits = @bitSizeOf(usize);
            const fibonacci_multiplier = 0x9E3779B97F4A7C15 >> (64 - max_multiplier_bits);

            const max_bucket_bits = @ctz(buckets.len);
            comptime assert(std.math.isPowerOfTwo(buckets.len));

            const index = (address *% fibonacci_multiplier) >> (max_multiplier_bits - max_bucket_bits);
            return &buckets[index];
        }
    };

    const Address = struct {
        fn from(ptr: *const u32) usize {
            // Get the alignment of the pointer.
            const alignment = @alignOf(atomic.Value(u32));
            comptime assert(std.math.isPowerOfTwo(alignment));

            // Make sure the pointer is aligned,
            // then cut off the zero bits from the alignment to get the unique address.
            const addr = @intFromPtr(ptr);
            assert(addr & (alignment - 1) == 0);
            return addr >> @ctz(@as(usize, alignment));
        }
    };

    fn wait(ptr: *const u32, expect: u32, timeout: ?u64) error{Timeout}!void {
        const address = Address.from(ptr);
        const bucket = Bucket.from(address);

        // Announce that there's a waiter in the bucket before checking the ptr/expect condition.
        // If the announcement is reordered after the ptr check, the waiter could deadlock:
        //
        // - T1: checks ptr == expect which is true
        // - T2: updates ptr to != expect
        // - T2: does Futex.wake(), sees no pending waiters, exits
        // - T1: bumps pending waiters (was reordered after the ptr == expect check)
        // - T1: goes to sleep and misses both the ptr change and T2's wake up
        //
        // acquire barrier to ensure the announcement happens before the ptr check below.
        var pending = bucket.pending.fetchAdd(1, .acquire);
        assert(pending < std.math.maxInt(usize));

        // If the wait gets canceled, remove the pending count we previously added.
        // This is done outside the mutex lock to keep the critical section short in case of contention.
        var canceled = false;
        defer if (canceled) {
            pending = bucket.pending.fetchSub(1, .monotonic);
            assert(pending > 0);
        };

        var waiter: Waiter = undefined;
        {
            assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
            defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

            canceled = @atomicLoad(u32, ptr, .monotonic) != expect;
            if (canceled) {
                return;
            }

            waiter.event.init();
            WaitQueue.insert(&bucket.treap, address, &waiter);
        }

        defer {
            assert(!waiter.is_queued);
            waiter.event.deinit();
        }

        waiter.event.wait(timeout) catch {
            // If we fail to cancel after a timeout, it means a wake() thread
            // dequeued us and will wake us up. We must wait until the event is
            // set as that's a signal that the wake() thread won't access the
            // waiter memory anymore. If we return early without waiting, the
            // waiter on the stack would be invalidated and the wake() thread
            // risks a UAF.
            defer if (!canceled) waiter.event.wait(null) catch unreachable;

            assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
            defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

            canceled = WaitQueue.tryRemove(&bucket.treap, address, &waiter);
            if (canceled) {
                return error.Timeout;
            }
        };
    }

    fn wake(ptr: *const u32, max_waiters: u32) void {
        const address = Address.from(ptr);
        const bucket = Bucket.from(address);

        // Quick check if there's even anything to wake up.
        // The change to the ptr's value must happen before we check for pending waiters.
        // If not, the wake() thread could miss a sleeping waiter and have it deadlock:
        //
        // - T2: p = has pending waiters (reordered before the ptr update)
        // - T1: bump pending waiters
        // - T1: if ptr == expected: sleep()
        // - T2: update ptr != expected
        // - T2: p is false from earlier so doesn't wake (T1 missed ptr update and T2 missed T1 sleeping)
        //
        // What we really want here is a Release load, but that doesn't exist under the C11 memory model.
        // We could instead do `bucket.pending.fetchAdd(0, Release) == 0` which achieves effectively the same thing,
        // LLVM lowers the fetchAdd(0, .release) into an mfence+load which avoids gaining ownership of the cache-line.
        if (bucket.pending.fetchAdd(0, .release) == 0) {
            return;
        }

        // Keep a list of all the waiters notified and wake then up outside the mutex critical section.
        var notified = WaitList{};
        defer if (notified.len > 0) {
            const pending = bucket.pending.fetchSub(notified.len, .monotonic);
            assert(pending >= notified.len);

            while (notified.pop()) |waiter| {
                assert(!waiter.is_queued);
                waiter.event.set();
            }
        };

        assert(c.pthread_mutex_lock(&bucket.mutex) == .SUCCESS);
        defer assert(c.pthread_mutex_unlock(&bucket.mutex) == .SUCCESS);

        // Another pending check again to avoid the WaitQueue lookup if not necessary.
        if (bucket.pending.load(.monotonic) > 0) {
            notified = WaitQueue.remove(&bucket.treap, address, max_waiters);
        }
    }
};

fn scanEnviron(t: *Threaded) void {
    t.mutex.lock();
    defer t.mutex.unlock();

    if (t.environ.initialized) return;
    t.environ.initialized = true;

    if (is_windows) {
        const ptr = windows.peb().ProcessParameters.Environment;

        var i: usize = 0;
        while (ptr[i] != 0) {
            const key_start = i;

            // There are some special environment variables that start with =,
            // so we need a special case to not treat = as a key/value separator
            // if it's the first character.
            // https://devblogs.microsoft.com/oldnewthing/20100506-00/?p=14133
            if (ptr[key_start] == '=') i += 1;

            while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
            const key_w = ptr[key_start..i];
            if (std.mem.eql(u16, key_w, &.{ 'N', 'O', '_', 'C', 'O', 'L', 'O', 'R' })) {
                t.environ.exist.NO_COLOR = true;
            } else if (std.mem.eql(u16, key_w, &.{ 'C', 'L', 'I', 'C', 'O', 'L', 'O', 'R', '_', 'F', 'O', 'R', 'C', 'E' })) {
                t.environ.exist.CLICOLOR_FORCE = true;
            }
            comptime assert(@sizeOf(Environ.String) == 0);

            while (ptr[i] != 0) : (i += 1) {} // skip over '=' and value
            i += 1; // skip over null byte
        }
    } else if (native_os == .wasi and !builtin.link_libc) {
        var environ_count: usize = undefined;
        var environ_buf_size: usize = undefined;

        switch (std.os.wasi.environ_sizes_get(&environ_count, &environ_buf_size)) {
            .SUCCESS => {},
            else => |err| {
                t.environ.err = posix.unexpectedErrno(err);
                return;
            },
        }
        if (environ_count == 0) return;

        const environ = t.allocator.alloc([*:0]u8, environ_count) catch |err| {
            t.environ.err = err;
            return;
        };
        defer t.allocator.free(environ);
        const environ_buf = t.allocator.alloc(u8, environ_buf_size) catch |err| {
            t.environ.err = err;
            return;
        };
        defer t.allocator.free(environ_buf);

        switch (std.os.wasi.environ_get(environ.ptr, environ_buf.ptr)) {
            .SUCCESS => {},
            else => |err| {
                t.environ.err = posix.unexpectedErrno(err);
                return;
            },
        }

        for (environ) |env| {
            const pair = std.mem.sliceTo(env, 0);
            var parts = std.mem.splitScalar(u8, pair, '=');
            const key = parts.first();
            if (std.mem.eql(u8, key, "NO_COLOR")) {
                t.environ.exist.NO_COLOR = true;
            } else if (std.mem.eql(u8, key, "CLICOLOR_FORCE")) {
                t.environ.exist.CLICOLOR_FORCE = true;
            }
            comptime assert(@sizeOf(Environ.String) == 0);
        }
    } else if (builtin.link_libc) {
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const value = line[line_i + 1 .. end_i :0];

            if (std.mem.eql(u8, key, "NO_COLOR")) {
                t.environ.exist.NO_COLOR = true;
            } else if (std.mem.eql(u8, key, "CLICOLOR_FORCE")) {
                t.environ.exist.CLICOLOR_FORCE = true;
            } else if (@hasField(Environ.String, "PATH") and std.mem.eql(u8, key, "PATH")) {
                t.environ.string.PATH = value;
            }
        }
    } else {
        for (t.environ.block) |line| {
            var line_i: usize = 0;
            while (line[line_i] != 0 and line[line_i] != '=') : (line_i += 1) {}
            const key = line[0..line_i];

            var end_i: usize = line_i;
            while (line[end_i] != 0) : (end_i += 1) {}
            const value = line[line_i + 1 .. end_i :0];

            if (std.mem.eql(u8, key, "NO_COLOR")) {
                t.environ.exist.NO_COLOR = true;
            } else if (std.mem.eql(u8, key, "CLICOLOR_FORCE")) {
                t.environ.exist.CLICOLOR_FORCE = true;
            } else if (@hasField(Environ.String, "PATH") and std.mem.eql(u8, key, "PATH")) {
                t.environ.string.PATH = value;
            }
        }
    }
}

test {
    _ = @import("Threaded/test.zig");
}
