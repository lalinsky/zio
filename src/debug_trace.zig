//! DEBUG (iocp-debug branch only): a tiny lock-free ring buffer for tracing the
//! completion/group/cancel lifecycle, dumped by a watchdog when the #530 hang is
//! detected. Volume-bounded (only the last N events survive), so it can sit in
//! hot paths. Do not merge.

const std = @import("std");

pub const enabled = true;

pub const Kind = enum(u8) {
    complete, // markCompletedFromBackend: backend reported an op done
    mc_finish, // markCompleted: finished inline (in_queue was clear)
    mc_defer, // markCompleted: deferred to cancel queue (in_queue set)
    finish, // finishCompletion entry (the per-child decrement happens here)
    cancel_local, // cancelLocal entry
    cancel_fin, // cancelLocal defer: finished (completed was set)
    cancel_nofin, // cancelLocal defer: did NOT finish (completed clear)
    cancel_enq, // cross-thread cancel enqueued to target loop
    group_dec, // groupCallback: remaining decrement (val = prev)
    group_finish, // groupCallback: group completed (prev==1)
    timer_set, // setTimer: insert/reset (val = deadline)
    timer_clear, // clearTimer (val = was_active)
    timer_fire, // checkTimers: deadline passed, about to markCompleted (val = deadline)
    // task scheduling (ptr = task)
    park, // processCleanup: task transitioned to .waiting
    park_prewoken, // processCleanup: awaken token consumed, rescheduled locally
    signal, // Waiter.signal: direct waiter signalled (val = notify count)
    sched_local, // scheduleTask -> local ready queue
    sched_migrate, // scheduleTask -> migrate to current executor
    sched_remote, // scheduleTask -> remote queue + wake (val = home loop)
    sched_token, // scheduleTask -> task .ready, set awaken token (no schedule)
    sched_main, // scheduleTask -> main task, loop.wake
    sched_finished, // scheduleTask -> task already finished
    // Waiter linking (ptr=waiter, loop=task unless noted)
    wait_io, // waitForIo: park on a completion (val=completion)
    wait_join, // waitInternal: park on a future/awaitable (val=future)
    wcb, // Waiter.callback fired for a completion (val=completion, loop=0)
    mark_complete, // Awaitable.markComplete entry (ptr=awaitable, val=has_waiter)
    sock_open, // net.socket created a handle (ptr=handle)
    sock_close, // net.close closed a handle (ptr=handle)
    pc_entry, // processCompletion top: op=c.op, ptr=overlapped, val=completion
    acc_submit, // submitAccept after AcceptEx: ptr=overlapped, val=accept_socket, loop=completion
    acc_cancel, // iocp.cancel net_accept: ptr=overlapped, loop=completion
    io_submit, // any net submit: op=c.op, ptr=overlapped, val=sync(1)/pending(0)/err(2), loop=completion
    pc_detail, // processCompletion: op=c.op, ptr=overlapped, val=entry.Internal(NTSTATUS), loop=bytesTransferred
    pc_ovl, // OVERLAPPED struct contents: ptr=overlapped, val=ovl.Internal, loop=ovl.hEvent
};

const Event = struct {
    seq: u64 = 0,
    kind: Kind = .complete,
    op: u16 = 0,
    ptr: usize = 0,
    val: u64 = 0,
    loop: usize = 0,
};

/// DEBUG (#530): a socket handle the test marks as "must not be closed mid-run"
/// (the listening socket). net.close panics if it sees this handle closed, so the
/// panic stack trace reveals the buggy close path.
pub var protected: usize = 0;

/// DEBUG (#530): open-socket tracker to catch a double-close / close-of-not-open
/// (a stale close of a reused fd). Fixed open-addressing set under a mutex.
var sock_lock = std.atomic.Value(bool).init(false);
fn lockSock() void {
    while (sock_lock.swap(true, .acquire)) {}
}
fn unlockSock() void {
    sock_lock.store(false, .release);
}
const SET_N = 16384;
var open_set: [SET_N]usize = @splat(0); // 0 = empty slot

pub fn sockOpen(h: usize) void {
    if (!enabled or h == 0) return;
    lockSock();
    defer unlockSock();
    var i = h % SET_N;
    var probes: usize = 0;
    while (open_set[i] != 0) : (probes += 1) {
        if (open_set[i] == h) return; // already present (shouldn't happen)
        if (probes >= SET_N) return; // full; give up silently
        i = (i + 1) % SET_N;
    }
    open_set[i] = h;
}

/// Returns true if `h` was open (and removes it); false = double-close.
pub fn sockClose(h: usize) bool {
    if (!enabled or h == 0) return true;
    lockSock();
    defer unlockSock();
    var i = h % SET_N;
    var probes: usize = 0;
    while (open_set[i] != 0) : (probes += 1) {
        if (open_set[i] == h) {
            open_set[i] = 0;
            // Re-cluster: rehash the following cluster so probe chains stay valid.
            var j = (i + 1) % SET_N;
            while (open_set[j] != 0) {
                const v = open_set[j];
                open_set[j] = 0;
                var k = v % SET_N;
                while (open_set[k] != 0) k = (k + 1) % SET_N;
                open_set[k] = v;
                j = (j + 1) % SET_N;
            }
            return true;
        }
        if (probes >= SET_N) break;
        i = (i + 1) % SET_N;
    }
    return false; // not found = double-close / close of never-opened
}

const N = 32768;
var buf: [N]Event = undefined;
var idx: std.atomic.Value(u64) = .init(0);

/// Focus on the wake chain only — recording every completion/group/timer/cancel
/// event perturbs timing enough to change the bug's manifestation (Heisenbug).
fn wanted(kind: Kind) bool {
    return switch (kind) {
        // Focused on the accept-completion lifecycle for #530.
        .sock_open, .sock_close, .pc_entry, .acc_submit, .acc_cancel, .io_submit, .pc_detail, .pc_ovl => true,
        else => false,
    };
}

pub inline fn rec(kind: Kind, op: u16, ptr: usize, val: u64, loop: usize) void {
    if (!enabled) return;
    if (!wanted(kind)) return;
    const i = idx.fetchAdd(1, .monotonic);
    buf[i % N] = .{ .seq = i, .kind = kind, .op = op, .ptr = ptr, .val = val, .loop = loop };
}

/// DEBUG (#530): monotonic generation stamped into each AcceptEx's OVERLAPPED
/// (Offset/OffsetHigh, unused by AcceptEx) at submit and read back at completion.
/// Never reused, unlike the overlapped's address. Lets us prove whether one
/// AcceptEx submission produces two completions vs two submissions aliasing.
pub var accept_gen = std.atomic.Value(u64).init(1);

var dumped = std.atomic.Value(bool).init(false);

pub fn dump() void {
    if (!enabled) return;
    // Only the first caller dumps (a crash + watchdog could both call).
    if (dumped.swap(true, .acq_rel)) return;
    // Write directly to stderr (std.debug.print locks + writes unbuffered) so the
    // dump survives a hard crash where log/buffered output would be lost.
    const total = idx.load(.monotonic);
    const count = @min(total, @as(u64, N));
    const start = total - count;
    std.debug.print("=== TRACE DUMP: last {d} of {d} events ===\n", .{ count, total });
    var s = start;
    while (s < total) : (s += 1) {
        const e = buf[s % N];
        std.debug.print("T#{d} {s} op={d} c=0x{x} val={d} loop=0x{x}\n", .{ e.seq, @tagName(e.kind), e.op, e.ptr, e.val, e.loop });
    }
    std.debug.print("=== END TRACE DUMP ===\n", .{});
}
