const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../../os/posix.zig");
const net = @import("../../os/net.zig");
const time = @import("../../os/time.zig");
const Duration = @import("../../time.zig").Duration;
const Clock = @import("../../time.zig").Clock;
const common = @import("common.zig");

const unexpectedError = @import("../../os/base.zig").unexpectedError;
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Queue = @import("../queue.zig").Queue;
const NetAccept = @import("../completion.zig").NetAccept;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetRecvFrom = @import("../completion.zig").NetRecvFrom;
const NetSendTo = @import("../completion.zig").NetSendTo;
const NetRecvMsg = @import("../completion.zig").NetRecvMsg;
const NetRecvMmsg = @import("../completion.zig").NetRecvMmsg;
const NetSendMsg = @import("../completion.zig").NetSendMsg;
const NetSendMmsg = @import("../completion.zig").NetSendMmsg;
const NetSendFile = @import("../completion.zig").NetSendFile;
const NetClose = @import("../completion.zig").NetClose;
const PipeClose = @import("../completion.zig").PipeClose;
const MachPort = @import("../completion.zig").MachPort;
const ProcessWait = @import("../completion.zig").ProcessWait;
const fs = @import("../../os/fs.zig");
const readiness = @import("../readiness.zig");

pub const NetHandle = net.fd_t;

const Op = @import("../completion.zig").Op;
const Support = @import("../completion.zig").Support;
const WallTimerMode = @import("../completion.zig").WallTimerMode;

// Boot is the one wall clock worth arming here, and only on Darwin. It is a
// relative NOTE_MACH_CONTINUOUS_TIME timer, so XNU computes the deadline in its
// own continuous timebase and nothing can invalidate it later; that also makes
// it the only way to fire a boot deadline that comes due while the system is
// asleep, which a poll timeout measured on the awake clock would sleep through.
// It is capped rather than trusted outright because the kernel is free to
// coalesce it (see armWall), and the poll timeout is the prompter of the two.
//
// Real is not armed at all. XNU converts a NOTE_ABSOLUTE calendar deadline to a
// Mach deadline once at registration, with an explicit "if the relationship
// between MAT and gettimeofday changes, the underlying timer does not update"
// in filt_timervalidate, so a wall-clock step afterwards leaves it pointing at
// the wrong moment. Re-deriving the interval from now(.real) on every scan,
// which is what the fallback does, is both correct across steps and no less
// prompt, so the timer would only add a syscall and a wake to ignore.
//
// The other BSDs arm neither: their EVFILT_TIMER absolute clock is
// monotonic-only and underspecified, with no CLOCK_REALTIME timer at all.
pub const wall_timer_modes: [3]WallTimerMode = if (builtin.os.tag.isDarwin())
    .{ .fallback, .native_capped, .fallback }
else
    .{ .fallback, .fallback, .fallback };
pub const supports_nonblocking_file_io = false;
pub const supports_recv_dontwait = true;
pub const supports_recvmmsg = builtin.os.tag == .freebsd or builtin.os.tag == .netbsd;

pub fn capability(comptime op: Op) Support {
    return switch (op) {
        .file_read_streaming, .file_write_streaming => .maybe,
        // FreeBSD's sendfile is asynchronous with respect to file reads. The
        // Darwin implementation can block the loop and deliberately falls back.
        .net_send_file => if (builtin.os.tag == .freebsd) .yes else .no,
        .file_open,
        .file_create,
        .file_close,
        .file_read,
        .file_write,
        .file_sync,
        .file_sync_range,
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
        => .no,
        .group,
        .timer,
        .async,
        .work,
        .net_open,
        .net_bind,
        .net_listen,
        .net_connect,
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_recvmmsg,
        .net_sendmsg,
        .net_sendmmsg,
        .net_poll,
        .net_shutdown,
        .net_close,
        .pipe_poll,
        .pipe_create,
        .pipe_close,
        .mach_port,
        .process_wait,
        => .yes,
    };
}

pub fn supports(_: *const Self, comptime op: Op, data: *op.toType()) bool {
    comptime std.debug.assert(capability(op) == .maybe);
    if (comptime op == .file_read_streaming or op == .file_write_streaming) {
        return common.resolveStreamingSupport(data);
    }
    @compileError("unhandled runtime kqueue capability: " ++ @tagName(op));
}

pub const SharedState = struct {
    /// Which loops of the group have which sockets registered. See readiness.zig.
    holders: readiness.Holders = .{},
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};

const Self = @This();

/// Progress of a native sendfile op. Initialized in submit() (which caps the
/// request to the file size) and advanced by the checkCompletion arm each time
/// the socket's write edge fires.
pub const NetSendFileData = struct {
    /// File offset for the next sendfile call.
    offset: u64 = 0,
    /// Bytes still to send; 0 means the op is done.
    remaining: usize = 0,
    /// Total bytes sent so far (the operation result).
    sent: usize = 0,
};

/// Ends a native sendfile op with `err`, or with the bytes sent so far if
/// there were any (see NetSendFile).
fn finishNetSendFile(comp: *Completion, err: anyerror) CheckResult {
    const sent = comp.cast(NetSendFile).internal.sent;
    if (sent > 0) comp.setResult(.net_send_file, sent) else comp.setError(err);
    return .completed;
}

const log = @import("../../common.zig").log;

// These are not defined in std.c for FreeBSD/NetBSD,
// but the values are the same across all systems using kqueue
const EV_ERROR: u16 = 0x4000;
const EV_EOF: u16 = 0x8000;

// std.c has wrong numbers for EVFILT_USER and NOTE_TRIGGER on NetBSD
// https://github.com/ziglang/zig/pull/25853
const EVFILT_USER: i16 = switch (builtin.target.os.tag) {
    .netbsd => 8,
    else => std.c.EVFILT.USER,
};
const NOTE_TRIGGER: u32 = 0x01000000;

const delete_marker: usize = std.math.maxInt(usize);

// udata of an fd registration: the top two bits are 0b01, telling it apart from
// the object waits (udata == 0) and from delete_marker, and the registration's
// generation is in the low bits. Pollable fds are registered edge-triggered
// (EV_CLEAR) with the kqueue of each loop that parks on them (see readiness.zig).
const reg_udata_shift = @bitSizeOf(usize) - 2;
const reg_udata_tag: usize = 1 << reg_udata_shift;

comptime {
    std.debug.assert(readiness.gen_bits <= reg_udata_shift);
}

fn regUdata(gen: readiness.Gen) usize {
    return reg_udata_tag | gen;
}

fn udataIsReg(udata: usize) bool {
    return udata >> reg_udata_shift == 0b01;
}

fn filterForDir(dir: readiness.Dir) i16 {
    return switch (dir) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };
}

// EVFILT_TIMER ident for the boot wall-clock timer (Darwin only). It has the
// EVFILT_TIMER filter to itself, so a plain 0 ident doesn't collide with the
// fd-based idents on the other filters.
const WALL_BOOT_IDENT: usize = 0;

/// Completions waiting on one kernel object that is not an fd: a process
/// (EVFILT_PROC) or a Mach port, keyed by ident and filter.
const ObjectWait = struct {
    completions: Queue(Completion),
};

allocator: std.mem.Allocator,
shared: *SharedState = undefined,
/// This loop's fd registrations (see readiness.zig).
fds: *readiness.FdTable = undefined,
/// Backend-internal inflight count: ops accepted by submit() and not yet
/// completed. Every op is completed on the loop that accepted it (a parked
/// socket op by its own loop's poller, a cancel routed to it), so a plain
/// counter suffices. Read by hasInflight() to skip the poll syscall when
/// nothing can arrive.
inflight: usize = 0,
kqueue_fd: i32 = -1,
waker_ident: usize = undefined,
object_waits: std.AutoHashMapUnmanaged(u64, ObjectWait) = .empty,
change_buffer: std.ArrayList(std.c.Kevent) = .empty,
events: []std.c.Kevent,
/// Currently-armed absolute deadline (ns in the boot epoch) for the boot
/// EVFILT_TIMER, or null if disarmed. Darwin only.
wall_armed: ?u64 = null,

fn makeKey(ident: usize, filter: i32) u64 {
    std.debug.assert(ident <= std.math.maxInt(u32));
    return (@as(u64, @intCast(ident)) << 32) | @as(u32, @bitCast(filter));
}

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    const kq = std.c.kqueue();
    const kqueue_fd: i32 = switch (posix.errno(kq)) {
        .SUCCESS => @intCast(kq),
        else => |err| return unexpectedError(err),
    };
    errdefer _ = std.c.close(kqueue_fd);

    const events = try allocator.alloc(std.c.Kevent, queue_size);
    errdefer allocator.free(events);

    var change_buffer = try std.ArrayList(std.c.Kevent).initCapacity(allocator, queue_size);
    errdefer change_buffer.deinit(allocator);

    // Use address of self as unique waker ident
    const waker_ident = @intFromPtr(self);

    // Register EVFILT_USER for wakeups
    var changes: [1]std.c.Kevent = .{.{
        .ident = waker_ident,
        .filter = EVFILT_USER,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    const rc = std.c.kevent(kqueue_fd, &changes, 1, &.{}, 0, null);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return unexpectedError(err),
    }

    const fds = try shared_state.holders.acquire(allocator, Self, kqueue_fd);
    errdefer shared_state.holders.release(fds);

    self.* = .{
        .allocator = allocator,
        .shared = shared_state,
        .fds = fds,
        .kqueue_fd = kqueue_fd,
        .waker_ident = waker_ident,
        .change_buffer = change_buffer,
        .events = events,
    };

    try self.object_waits.ensureTotalCapacity(self.allocator, queue_size);
}

pub fn deinit(self: *Self) void {
    self.object_waits.deinit(self.allocator);
    self.change_buffer.deinit(self.allocator);
    self.allocator.free(self.events);
    // Before closing the kqueue: once released, no close on another thread can
    // reach this loop's registrations.
    self.shared.holders.release(self.fds);
    if (self.kqueue_fd != -1) {
        _ = std.c.close(self.kqueue_fd);
    }
}

pub fn wake(self: *Self, state: *LoopState) void {
    _ = state;
    var changes: [1]std.c.Kevent = .{.{
        .ident = self.waker_ident,
        .filter = EVFILT_USER,
        .flags = 0,
        .fflags = NOTE_TRIGGER,
        .data = 0,
        .udata = 0,
    }};
    // A silently failed trigger strands the sleeping loop until its poll
    // timeout: wake_requested is already set, so later wakers skip the
    // syscall. Retry EINTR; anything else means the waker is broken and
    // every subsequent wake would be lost, so fail loudly.
    while (true) {
        const rc = std.c.kevent(self.kqueue_fd, &changes, 1, &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| std.debug.panic("kqueue: waker NOTE_TRIGGER failed: {t}", .{err}),
        }
    }
}

/// Arm/update/disarm the boot clock's EVFILT_TIMER to an absolute deadline (ns
/// in the boot epoch; null = disarm). Returns false only if it couldn't arm a
/// pending deadline, so the loop falls back to its poll timeout alone. Darwin
/// only; other kqueue platforms keep the fallback (the comptime guard also keeps
/// the Darwin-only NOTE_* references out of their builds).
pub fn syncWallTimer(self: *Self, clock: Clock, deadline: ?u64) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        std.debug.assert(clock == .boot);
        return self.armWall(deadline);
    }
    return true;
}

fn armWall(self: *Self, deadline: ?u64) bool {
    if (self.wall_armed == deadline) return true; // unchanged (incl. both null)
    // reserveChange only fails on OOM: the change buffer grows and is reused
    // across polls (clearRetainingCapacity), so there's no "full" condition like
    // io_uring's fixed SQ ring. On OOM while arming a pending deadline, report
    // failure so the loop folds this clock into the capped poll timeout and
    // retries next scan. A failed disarm has no pending deadline to fold, so
    // report success and let the stale one-shot wake harmlessly / retry later.
    const change = self.reserveChange() catch {
        log.err("kqueue: failed to reserve change buffer slot for wall timer", .{});
        return deadline == null;
    };
    if (deadline) |d| {
        // A relative interval on the continuous timebase: XNU computes the
        // deadline with clock_continuoustime_interval_to_deadline and arms the
        // thread_call with THREAD_CALL_CONTINUOUS, so it counts suspend and
        // there is no foreign epoch for the kernel to snapshot. Our `.boot` is
        // CLOCK_MONOTONIC_RAW, the same counter, and an interval needs no epoch
        // match anyway.
        //
        // Deliberately not NOTE_CRITICAL. The kernel coalesces this against the
        // thread's latency QoS (timer_compute_leeway), and NOTE_CRITICAL is the
        // only lever that narrows that window: NOTE_LEEWAY can only widen it,
        // and timer_call_slop skips coalescing only for TIMER_CALL_SYS_CRITICAL,
        // which no kevent can ask for. But the flag asks the system for
        // realtime-tier treatment of every boot deadline a program sets, which
        // is the application's call to make and not a library's; libdispatch
        // exposes the same thing as an opt-in (DISPATCH_TIMER_STRICT) and
        // coalesces by default. The lateness it would buy back is already
        // covered: `native_capped` keeps the loop's own poll timeout, and that
        // is what actually decides when a due timer fires.
        const now_ns = time.now(.boot).toNanoseconds();
        const fflags: u32 = std.c.NOTE.NSECONDS | std.c.NOTE.MACH_CONTINUOUS_TIME;
        const data: isize = @intCast(if (d > now_ns) d - now_ns else 0);
        change.* = .{
            .ident = WALL_BOOT_IDENT,
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = fflags,
            .data = data,
            .udata = 0,
        };
    } else {
        change.* = .{
            .ident = WALL_BOOT_IDENT,
            .filter = std.c.EVFILT.TIMER,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
    }
    self.wall_armed = deadline;
    return true;
}

fn getFilter(completion: *Completion) i16 {
    return switch (completion.op) {
        .process_wait => std.c.EVFILT.PROC,
        .mach_port => if (builtin.os.tag.isDarwin()) std.c.EVFILT.MACHPORT else unreachable,
        else => unreachable,
    };
}

fn getIdent(completion: *Completion) usize {
    return switch (completion.op) {
        .process_wait => @intCast(completion.cast(ProcessWait).handle),
        .mach_port => completion.cast(MachPort).port,
        else => unreachable,
    };
}

fn getFflags(completion: *Completion) u32 {
    return switch (completion.op) {
        .process_wait => std.c.NOTE.EXIT,
        else => 0,
    };
}

fn reserveChange(self: *Self) !*std.c.Kevent {
    return self.change_buffer.addOne(self.allocator);
}

fn addObjectWait(self: *Self, state: *LoopState, completion: *Completion) void {
    const ident = getIdent(completion);
    const filter = getFilter(completion);
    const key = makeKey(ident, filter);

    completion.prev = null;
    completion.next = null;

    const gop = self.object_waits.getOrPut(self.allocator, key) catch {
        log.err("Failed to add an object wait: OutOfMemory", .{});
        completion.setError(error.Unexpected);
        state.markCompletedFromBackend(completion);
        return;
    };

    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .completions = .{} };
        const change = self.reserveChange() catch {
            _ = self.object_waits.remove(key);
            completion.setError(error.Unexpected);
            state.markCompletedFromBackend(completion);
            return;
        };
        change.* = .{
            .ident = ident,
            .filter = filter,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = getFflags(completion),
            .data = 0,
            .udata = 0,
        };
    }

    gop.value_ptr.completions.push(completion);
}

fn removeObjectWait(self: *Self, completion: *Completion) void {
    const ident = getIdent(completion);
    const filter = getFilter(completion);
    const key = makeKey(ident, filter);
    const entry = self.object_waits.getPtr(key) orelse return;

    _ = entry.completions.remove(completion);

    if (entry.completions.head == null) {
        const change = self.reserveChange() catch {
            _ = self.object_waits.remove(key);
            return;
        };
        change.* = .{
            .ident = ident,
            .filter = filter,
            .flags = std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = delete_marker,
        };
        _ = self.object_waits.remove(key);
    }
}

// ---- socket registration path ------------------------------------------------

// Backend hooks for the generic readiness path in readiness.zig.

/// Change the directions `fd` is registered for in this loop's kqueue from
/// `old` to `new`, adding an EV_CLEAR knote for each new direction and deleting
/// the knote of each dropped one. Applied with an immediate kevent call rather
/// than through the change buffer, so no change can be left pending past a
/// close of the fd and then applied to whatever reuses its number. Called by
/// readiness.zig.
pub fn setInterest(self: *Self, fd: NetHandle, old: readiness.Dirs, new: readiness.Dirs, gen: readiness.Gen) bool {
    return changeInterest(self.kqueue_fd, fd, old, new, gen);
}

fn changeInterest(kqueue_fd: i32, fd: NetHandle, old: readiness.Dirs, new: readiness.Dirs, gen: readiness.Gen) bool {
    var changes: [2]std.c.Kevent = undefined;
    var n: usize = 0;
    for ([_]readiness.Dir{ .read, .write }) |dir| {
        const bit = readiness.dirBit(dir);
        if ((old ^ new) & bit == 0) continue;
        changes[n] = .{
            .ident = @intCast(fd),
            .filter = filterForDir(dir),
            .flags = if (new & bit != 0) std.c.EV.ADD | std.c.EV.CLEAR else std.c.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = regUdata(gen),
        };
        n += 1;
    }
    while (true) {
        const rc = std.c.kevent(kqueue_fd, &changes, @intCast(n), &.{}, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return true,
            .INTR => continue,
            // Deleting a knote the kernel already dropped with a closed fd.
            .NOENT => |err| if (new & ~old == 0) return true else {
                log.err("Failed to register socket with kqueue: {}", .{err});
                return false;
            },
            else => |err| {
                log.err("Failed to register socket with kqueue: {}", .{err});
                return false;
            },
        }
    }
}

/// Nothing to remove before a close: closing the fd removes its knotes from
/// every kqueue. Called by readiness.zig.
pub fn forgetSocket(poller_fd: i32, fd: NetHandle) void {
    _ = poller_fd;
    _ = fd;
}

/// Delete an open socket's knotes from another loop's kqueue (see
/// readiness.Holders.claim). Called by readiness.zig.
pub fn dropSocket(poller_fd: i32, fd: NetHandle, registered: readiness.Dirs) void {
    _ = changeInterest(poller_fd, fd, registered, 0, 0);
}

/// A no-error event for the optimistic (pre-park) checkCompletion attempt.
pub fn probeEvent(fd: NetHandle, dir: readiness.Dir) std.c.Kevent {
    return .{
        .ident = @intCast(fd),
        .filter = filterForDir(dir),
        .flags = 0,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
}

/// Drop one inflight op. Called via LoopState.markCompletedFromBackend on the
/// owner thread.
pub fn decrInflight(self: *Self) void {
    self.inflight -= 1;
}

/// Whether poll() could produce completions. Used by the loop to skip the
/// wait syscall in no-wait ticks when nothing can arrive.
pub fn hasInflight(self: *const Self) bool {
    return self.inflight > 0;
}

/// Submit a completion to the backend - infallible.
/// On error, completes the operation immediately with error.Unexpected.
/// `op` is `c.op`, passed at compile time so each op compiles to its own
/// specialized submit with no runtime dispatch on the op.
pub fn submit(self: *Self, state: *LoopState, comptime op: Op, c: *Completion) void {
    // Counted for every accepted op (sync completers decrement right back via
    // markCompletedFromBackend), mirroring the decrInflight in every completion
    // path so the balance needs no per-path reasoning.
    self.inflight += 1;

    switch (op) {
        .group, .timer, .async, .work => unreachable, // Managed by the loop

        // Synchronous operations - complete immediately
        .net_open => {
            common.handleNetOpen(c);
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
            const data = c.cast(NetClose);
            // Tear down the persistent registration before the fd is closed, so a
            // future socket that reuses this fd number starts clean on every loop.
            readiness.unregister(self, data.handle);
            common.handleNetClose(c);
            state.markCompletedFromBackend(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompletedFromBackend(c);
        },

        // Sockets take the persistent edge-triggered path: try the
        // syscall optimistically, register with this loop's kqueue only on
        // WouldBlock.
        .net_connect => readiness.submitConnect(self, state, c),
        .net_accept,
        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .net_recvmsg,
        .net_recvmmsg,
        .net_sendmsg,
        .net_sendmmsg,
        => readiness.submitIo(self, state, c),
        .net_poll => readiness.submitPoll(self, state, c),

        .pipe_poll => readiness.submitPoll(self, state, c),
        // Streaming file I/O is routed here by the loop only when the fd is
        // pollable (non-seekable): try it, park on WouldBlock.
        .file_read_streaming, .file_write_streaming => readiness.submitIo(self, state, c),
        .mach_port, .process_wait => self.addObjectWait(state, c),

        .pipe_create => {
            const fds = fs.pipe() catch |err| {
                c.setError(err);
                state.markCompletedFromBackend(c);
                return;
            };
            c.setResult(.pipe_create, fds);
            state.markCompletedFromBackend(c);
        },
        .pipe_close => {
            const data = c.cast(PipeClose);
            if (fs.close(data.handle)) |_| {
                c.setResult(.pipe_close, {});
            } else |err| {
                c.setError(err);
            }
            state.markCompletedFromBackend(c);
        },

        // File operations are handled by Loop via thread pool
        .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_sync_range, .file_size, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .file_stat, .dir_open, .dir_close, .dir_read, .dir_create_dir, .dir_rename, .dir_rename_preserve, .dir_delete_file, .dir_delete_dir, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link, .device_io_control => unreachable,
        .net_send_file => {
            // Driven by Loop's generic read/write fallback on backends
            // without native sendfile, never reaches the backend there.
            if (comptime capability(.net_send_file) != .yes) unreachable;
            // Cap the request to the current file size once, so the
            // continuation can treat "remaining == 0" as done and never
            // spins on a writable socket at EOF. Then drive the sendfile
            // syscall through the generic socket path like any other
            // write op: try it, park on WouldBlock, resume on the write
            // edge (see checkCompletion).
            const data = c.cast(NetSendFile);
            const file_size = fs.fileSize(data.file) catch |err| {
                c.setError(switch (err) {
                    error.PermissionDenied => error.AccessDenied,
                    else => |e| e,
                });
                state.markCompletedFromBackend(c);
                return;
            };
            data.internal.offset = data.offset;
            data.internal.remaining = @intCast(@min(@as(u64, data.remaining), file_size -| data.offset));
            readiness.submitIo(self, state, c);
        },
    }
}

/// Cancel a completion - infallible.
/// Note: target.canceled is already set by loop.add() or loop.cancel() before this is called.
pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    if (readiness.isRegisteredOp(target.op)) {
        // Parked in this loop's waiters for the fd. If detach finds the op
        // already claimed by readiness.onEvent (a callback it ran is canceling
        // it), it has a natural result, so leave it alone rather than
        // overwriting it with Canceled and completing it twice. A socket's
        // registration is left in place, and dropped later if it goes unused;
        // any other is dropped with its last waiter.
        if (!readiness.detach(self, target)) return;
        // A sendfile parked partway through reports what it sent (see
        // NetSendFile).
        if (comptime capability(.net_send_file) == .yes) {
            if (target.op == .net_send_file) {
                const sent = target.cast(NetSendFile).internal.sent;
                if (sent > 0) {
                    target.setResult(.net_send_file, sent);
                    state.markCompletedFromBackend(target);
                    return;
                }
            }
        }
    } else {
        self.removeObjectWait(target);
    }

    target.setError(error.Canceled);
    state.markCompletedFromBackend(target);
}

pub fn poll(self: *Self, state: *LoopState, timeout: Duration) !bool {
    var timeout_spec: std.c.timespec = undefined;
    const timeout_ptr: ?*const std.c.timespec = if (timeout.value < std.math.maxInt(time.TimeInt)) blk: {
        const timeout_ns = timeout.toNanoseconds();
        timeout_spec = .{
            .sec = @intCast(timeout_ns / time.ns_per_s),
            .nsec = @intCast(timeout_ns % time.ns_per_s),
        };
        break :blk &timeout_spec;
    } else null;

    const changes = self.change_buffer.items;
    const rc = std.c.kevent(
        self.kqueue_fd,
        changes.ptr,
        @intCast(changes.len),
        self.events.ptr,
        @intCast(self.events.len),
        timeout_ptr,
    );
    const n: usize = switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => 0, // Interrupted by signal, no events
        else => |err| return unexpectedError(err),
    };
    self.change_buffer.clearRetainingCapacity();

    if (n == 0) {
        return true; // Timed out
    }

    var wall_fired = false;
    for (self.events[0..n]) |event| {
        // Check if this is the async wakeup user event
        if (event.filter == EVFILT_USER and event.ident == self.waker_ident) {
            continue;
        }

        // A boot wall timer event. Forget the armed deadline in both the
        // fired and the failed-registration case: on a successful one-shot fire
        // the kernel already removed it (EV_ONESHOT), and on EV_ERROR the ADD
        // never stuck, so the stored deadline is stale either way — clearing it
        // lets syncWallTimer re-queue the ADD on the next scan.
        if (event.filter == std.c.EVFILT.TIMER) {
            self.wall_armed = null;
            // EV_ERROR surfaces a changelist (ADD/DELETE) failure with errno in
            // event.data; no timer actually fired, so don't report a timeout.
            if (event.flags & EV_ERROR != 0) {
                log.err("kqueue: EVFILT_TIMER registration failed (ident={}): errno {}", .{ event.ident, event.data });
                continue;
            }
            wall_fired = true;
            continue;
        }

        if (event.udata == delete_marker) continue;

        // Registered fds: the filter tells us the direction; ERR/EOF is
        // delivered to the waiter, which surfaces it via its syscall.
        if (udataIsReg(event.udata)) {
            const sock_fd: NetHandle = @intCast(event.ident);
            const dir: readiness.Dir = if (event.filter == std.c.EVFILT.READ) .read else .write;
            const gen: readiness.Gen = @truncate(event.udata);
            readiness.onEvent(self, state, sock_fd, gen, readiness.dirBit(dir), &event);
            continue;
        }

        const key = makeKey(event.ident, event.filter);
        reload: while (true) {
            const entry = self.object_waits.get(key) orelse break :reload;

            var iter: ?*Completion = entry.completions.head;
            var completed_any = false;
            while (iter) |completion| {
                iter = completion.next;

                if (completion.loadState().phase != .running) {
                    continue;
                }

                switch (checkCompletion(completion, &event)) {
                    .completed => {
                        self.removeObjectWait(completion);
                        state.markCompletedFromBackend(completion);
                        completed_any = true;
                        break;
                    },
                    .requeue => {},
                }
            }
            if (!completed_any) break :reload;
        }
    }

    // A fired wall timer is reported as a timeout so the loop re-runs
    // checkTimers and fires the due boot/real timers.
    return wall_fired;
}

const CheckResult = enum { completed, requeue };

fn handleKqueueError(event: *const std.c.Kevent, comptime errnoToError: fn (net.E) anyerror) ?anyerror {
    const has_error = (event.flags & EV_ERROR) != 0;
    const has_eof = (event.flags & EV_EOF) != 0;
    if (!has_error and !has_eof) return null;

    if (has_error) {
        // event.data contains the errno when EV_ERROR is set
        if (event.data != 0) {
            return errnoToError(@fromBackingInt(@intCast(@as(i32, @intCast(event.data)))));
        }
    }

    const sock_err = net.getSockError(@intCast(event.ident)) catch return error.Unexpected;
    if (sock_err == 0) return null; // No actual error, caller should retry operation
    return errnoToError(@fromBackingInt(@intCast(sock_err)));
}

pub fn checkCompletion(comp: *Completion, event: *const std.c.Kevent) CheckResult {
    switch (comp.op) {
        .net_connect => {
            if (handleKqueueError(event, net.errnoToConnectError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_connect, {});
            }
            return .completed;
        },
        .net_accept => {
            const data = comp.cast(NetAccept);
            if (handleKqueueError(event, net.errnoToAcceptError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.accept(data.handle, data.addr, data.addr_len, data.flags)) |handle| {
                comp.setResult(.net_accept, handle);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recv => {
            const data = comp.cast(NetRecv);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recv(data.handle, data.buffers.iovecs, data.flags)) |n| {
                comp.setResult(.net_recv, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    if (data.flags.dontwait) {
                        comp.setError(err);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_send => {
            const data = comp.cast(NetSend);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.send(data.handle, data.buffer.iovecs, data.flags)) |n| {
                comp.setResult(.net_send, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvfrom => {
            const data = comp.cast(NetRecvFrom);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvfrom(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_recvfrom, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    if (data.flags.dontwait) {
                        comp.setError(err);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendto => {
            const data = comp.cast(NetSendTo);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendto(data.handle, data.buffer.iovecs, data.flags, data.addr, data.addr_len)) |n| {
                comp.setResult(.net_sendto, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvmsg => {
            const data = comp.cast(NetRecvMsg);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.recvmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |result| {
                comp.setResult(.net_recvmsg, result);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    if (data.flags.dontwait) {
                        comp.setError(err);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_recvmmsg => {
            const data = comp.cast(NetRecvMmsg);
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (data.recvFromSlots()) |count| {
                comp.setResult(.net_recvmmsg, count);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendmsg => {
            const data = comp.cast(NetSendMsg);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (net.sendmsg(data.handle, data.data.iovecs, data.flags, data.addr, data.addr_len, data.control)) |n| {
                comp.setResult(.net_sendmsg, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_sendmmsg => {
            const data = comp.cast(NetSendMmsg);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                comp.setError(err);
                return .completed;
            }
            if (NetSendMmsg.sendSlots(data.handle, data.slots, data.flags)) |count| {
                comp.setResult(.net_sendmmsg, count);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .net_send_file => {
            if (comptime capability(.net_send_file) != .yes) unreachable;
            const data = comp.cast(NetSendFile);
            if (handleKqueueError(event, net.errnoToSendError)) |err| {
                return finishNetSendFile(comp, err);
            }
            while (data.internal.remaining > 0) {
                var sbytes: posix.off_t = 0;
                const rc = std.c.sendfile(
                    data.file,
                    data.handle,
                    @intCast(data.internal.offset),
                    data.internal.remaining,
                    null,
                    &sbytes,
                    0,
                );
                // Progress is reported through sbytes even when the call
                // "fails" (EAGAIN/EINTR after a partial transfer).
                const sent: usize = @intCast(sbytes);
                data.internal.offset += sent;
                data.internal.remaining -= sent;
                data.internal.sent += sent;
                switch (posix.errno(rc)) {
                    // Success means the whole remaining request was sent,
                    // or the file was truncated under us (sendfile stops
                    // at EOF); either way there is nothing left to drive.
                    .SUCCESS => break,
                    .INTR => continue,
                    .AGAIN => return .requeue,
                    // The source is not a regular file (e.g. a pipe), which
                    // the caller can recover from by reading it instead.
                    .INVAL => return finishNetSendFile(comp, error.Unseekable),
                    else => |err| return finishNetSendFile(comp, net.errnoToSendError(err)),
                }
            }
            comp.setResult(.net_send_file, data.internal.sent);
            return .completed;
        },
        .net_poll => {
            // For poll operations, EOF means the socket is "ready" (will return EOF on next read).
            // Reuse handleKqueueError so we only fail on real socket errors (SO_ERROR != 0),
            // consistent with the other net_* ops.
            if (handleKqueueError(event, net.errnoToRecvError)) |err| {
                comp.setError(err);
            } else {
                comp.setResult(.net_poll, {});
            }
            return .completed;
        },
        inline .file_read_streaming => |op| {
            const data = comp.cast(op.toType());
            // Check for actual errors first
            const has_error = (event.flags & EV_ERROR) != 0;
            if (has_error and event.data != 0) {
                comp.setError(fs.errnoToFileReadError(@fromBackingInt(@intCast(@as(i32, @intCast(event.data))))));
                return .completed;
            }
            // Try to read - there might still be data in the pipe buffer
            if (fs.readv(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // For pipes, EV_EOF means the write end is closed
                    // If we got WouldBlock and EOF is set, that's EOF (no more data)
                    const has_eof = (event.flags & EV_EOF) != 0;
                    if (has_eof) {
                        comp.setResult(op, 0);
                        return .completed;
                    }
                    return .requeue;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        inline .file_write_streaming => |op| {
            const data = comp.cast(op.toType());
            // For pipes, check for errors but don't use getSockError
            const has_error = (event.flags & EV_ERROR) != 0;
            const has_eof = (event.flags & EV_EOF) != 0;
            if (has_error and event.data != 0) {
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                const err = fs.errnoToFileWriteError(@fromBackingInt(@intCast(@as(i32, @intCast(event.data)))));
                comp.setError(switch (err) {
                    error.NotOpenForWriting => error.BrokenPipe,
                    else => err,
                });
                return .completed;
            }
            if (has_eof) {
                // Read end closed
                comp.setError(error.BrokenPipe);
                return .completed;
            }
            if (fs.writev(data.handle, data.buffer.iovecs)) |n| {
                comp.setResult(op, n);
                return .completed;
            } else |err| switch (err) {
                error.WouldBlock => return .requeue,
                // BSD systems return EBADF (NotOpenForWriting) when writing to closed pipe
                // Normalize to BrokenPipe for consistency with Linux
                error.NotOpenForWriting => {
                    comp.setError(error.BrokenPipe);
                    return .completed;
                },
                else => {
                    comp.setError(err);
                    return .completed;
                },
            }
        },
        .pipe_close => unreachable, // Handled synchronously in submit
        .pipe_create => unreachable, // Handled synchronously in submit
        .pipe_poll => {
            // For poll operations, any event (error, EOF, or readiness) means "ready"
            // The actual error (if any) will be discovered on the next read/write
            comp.setResult(.pipe_poll, {});
            return .completed;
        },
        .mach_port => {
            comp.setResult(.mach_port, {});
            return .completed;
        },
        .process_wait => {
            // Process exited - call waitpid to get exit status and reap zombie
            // Following libuv pattern: kevent just notifies us, waitpid gets the status
            const data = comp.cast(ProcessWait);

            var status: c_int = 0;
            const rc = posix.system.waitpid(data.handle, &status, 0);
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .CHILD => comp.setError(error.ProcessNotFound),
                    else => comp.setError(error.Unexpected),
                }
            } else {
                // Decode wait status (WEXITSTATUS and WTERMSIG equivalent)
                const ustatus: u32 = @bitCast(status);
                const exit_code: u8 = @intCast((ustatus >> 8) & 0xff);
                const signal_num: u8 = @intCast(ustatus & 0x7f);
                comp.setResult(.process_wait, .{
                    .code = exit_code,
                    .signal = if (signal_num != 0) signal_num else null,
                });
            }

            return .completed;
        },
        else => {
            std.debug.panic("unexpected completion type in complete: {}", .{comp.op});
        },
    }
}
