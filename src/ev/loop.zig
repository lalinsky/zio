const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("backend.zig").Backend;
const BackendCapabilities = @import("completion.zig").BackendCapabilities;
const Completion = @import("completion.zig").Completion;
const Group = @import("completion.zig").Group;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const Duration = @import("../time.zig").Duration;
const Timestamp = @import("../time.zig").Timestamp;
const Timeout = @import("../time.zig").Timeout;
const Clock = @import("../time.zig").Clock;
const Queue = @import("queue.zig").Queue;
const Heap = @import("heap.zig").Heap;
const Work = @import("completion.zig").Work;
const DelegatedWork = @import("completion.zig").DelegatedWork;
const FileRead = @import("completion.zig").FileRead;
const NetSend = @import("completion.zig").NetSend;
const NetSendFile = @import("completion.zig").NetSendFile;
const ReadBuf = @import("buf.zig").ReadBuf;
const WriteBuf = @import("buf.zig").WriteBuf;
const os = @import("../os/root.zig");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const time = @import("../os/time.zig");
const net = @import("../os/net.zig");
const common = @import("backends/common.zig");

const log = @import("../common.zig").log;

const in_safe_mode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const in_debug_mode = builtin.mode == .Debug;

/// The loop bound to the current thread (debug builds only), used by
/// `assertOwnThread`. Set by `Loop.init`, cleared by `Loop.deinit`.
threadlocal var current_loop: if (in_debug_mode) ?*Loop else void =
    if (in_debug_mode) null else {};

/// How the NetSendFile fallback lays out its scratch from the (up to two)
/// caller-provided buffers.
const SendfileStrategy = enum {
    /// Ping-pong between the two given buffers (read into one, send the other).
    both,
    /// Halve the larger buffer into two ping-pong buffers (the other is unused).
    split,
    /// Single buffer, serial read-then-send.
    single,
};

/// The larger buffer must be at least this big before halving it for overlap
/// beats just running serially over the whole thing.
const sendfile_min_split = 64 * 1024;

/// Pick a strategy from the two buffers' sizes (see `SendfileStrategy`).
fn chooseSendfileStrategy(len0: usize, len1: usize) SendfileStrategy {
    const small = @min(len0, len1);
    const large = @max(len0, len1);
    // Two buffers ping-ponging beats halving one whenever both are usable, so
    // prefer that. Only fall back to halving the larger when the smaller is too
    // small to be a useful second buffer (less than half the larger) *and* the
    // larger is big enough that two halves still overlap well. An empty smaller
    // buffer (only one buffer available) also lands here.
    if (large >= sendfile_min_split and small < large / 2) return .split;
    if (small > 0) return .both;
    return .single;
}

/// Resolve the two caller buffers into the two working ping-pong buffers. A
/// non-empty bufs[1] means double-buffering; an empty bufs[1] means serial.
fn sendfileLayout(bufs: [2][]u8) [2][]u8 {
    const big = if (bufs[0].len >= bufs[1].len) bufs[0] else bufs[1];
    return switch (chooseSendfileStrategy(bufs[0].len, bufs[1].len)) {
        .both => bufs,
        .split => blk: {
            const half = big.len / 2;
            if (half == 0) break :blk .{ big, &.{} };
            break :blk .{ big[0..half], big[half..] };
        },
        .single => .{ big, &.{} },
    };
}

test chooseSendfileStrategy {
    const S = SendfileStrategy;
    const expectEqual = std.testing.expectEqual;
    const k = 1024;

    // Balanced (incl. equal) pairs -> use both, regardless of size.
    try expectEqual(S.both, chooseSendfileStrategy(64 * k, 64 * k));
    try expectEqual(S.both, chooseSendfileStrategy(1 * k, 1 * k));
    try expectEqual(S.both, chooseSendfileStrategy(64 * k, 48 * k));

    // Small second buffer, but the larger isn't big enough to bother splitting.
    try expectEqual(S.both, chooseSendfileStrategy(32 * k, 1 * k));
    try expectEqual(S.both, chooseSendfileStrategy(1 * k, 32 * k)); // order-independent

    // Large buffer + a much smaller one -> halve the large into balanced halves.
    try expectEqual(S.split, chooseSendfileStrategy(256 * k, 1 * k));
    try expectEqual(S.split, chooseSendfileStrategy(1 * k, 256 * k));

    // Only one buffer (other empty): split if big enough, else serial.
    try expectEqual(S.split, chooseSendfileStrategy(256 * k, 0));
    try expectEqual(S.single, chooseSendfileStrategy(32 * k, 0));
    try expectEqual(S.single, chooseSendfileStrategy(0, 0));
}

test sendfileLayout {
    const expectEqual = std.testing.expectEqual;
    const k = 1024;
    var a: [64 * k]u8 = undefined;
    var b: [64 * k]u8 = undefined;

    // Two balanced buffers -> returned as-is (double-buffer).
    {
        const r = sendfileLayout(.{ a[0 .. 32 * k], b[0 .. 32 * k] });
        try expectEqual(32 * k, r[0].len);
        try expectEqual(32 * k, r[1].len);
        try std.testing.expect(r[0].ptr == a[0..].ptr);
    }
    // One large buffer -> two halves of it.
    {
        const r = sendfileLayout(.{ a[0..], &.{} });
        try expectEqual(32 * k, r[0].len);
        try expectEqual(32 * k, r[1].len);
        try std.testing.expect(r[0].ptr == a[0..].ptr);
        try std.testing.expect(r[1].ptr == a[32 * k ..].ptr);
    }
    // One small buffer -> serial (empty second slot).
    {
        var c: [4 * k]u8 = undefined;
        const r = sendfileLayout(.{ c[0..], &.{} });
        try expectEqual(4 * k, r[0].len);
        try expectEqual(0, r[1].len);
    }
}

pub const LoopGroup = struct {
    shared: Backend.SharedState = .{},
};

pub const RunMode = enum {
    no_wait,
    once,
    until_done,
};

fn timerDeadlineLess(_: void, a: *Timer, b: *Timer) bool {
    return a.deadline.value < b.deadline.value;
}

const TimerHeap = Heap(Timer, void, timerDeadlineLess);

/// Timers are kept in one heap per wall-clock domain, since their deadlines
/// live in different epochs and can only be compared within a clock. The
/// CPU-time clocks are not valid for timers. `Clock` numbers the wall clocks
/// 0..wall_clock_count contiguously, so the enum value is the heap index.
const wall_clock_count = 3;

/// How often `tick` re-sends `SIGURG` to a worker still blocked in a canceled
/// syscall (see `LoopState.cancel_resend`). One signal almost always suffices;
/// this bounds how long a lost first signal delays the interruption.
const resend_interval: Duration = .fromMilliseconds(1);

fn clockIndex(clock: Clock) usize {
    // Where the platform has no distinct suspend-inclusive clock, `.boot` and
    // `.awake` are the same clock, so boot timers share the awake heap (index 0)
    // and are driven by the uncapped awake poll timeout instead of a separate
    // capped/native path.
    const c: Clock = if (clock == .boot and !time.boot_distinct_from_awake) .awake else clock;
    const idx = @intFromEnum(c);
    if (idx >= wall_clock_count) @panic("timers cannot use CPU-time clocks");
    return idx;
}

fn indexClock(index: usize) Clock {
    return @enumFromInt(index);
}

pub fn SimpleStack(comptime T: type) type {
    return struct {
        head: ?*T = null,

        pub fn push(self: *@This(), value: *T) void {
            value.next = self.head;
            self.head = value;
        }

        pub fn pop(self: *@This()) ?*T {
            const head = self.head orelse return null;
            self.head = head.next;
            head.next = null;
            return head;
        }

        pub fn empty(self: *const @This()) bool {
            return self.head == null;
        }
    };
}

pub fn AtomicStack(comptime T: type) type {
    return struct {
        head: std.atomic.Value(?*T) = .init(null),

        pub fn push(self: *@This(), value: *T) void {
            var head = self.head.load(.acquire);
            while (true) {
                value.next = head;
                if (self.head.cmpxchgWeak(head, value, .acq_rel, .acquire)) |prev_value| {
                    head = prev_value;
                    continue;
                }
                break;
            }
        }

        pub fn popAll(self: *@This()) SimpleStack(T) {
            const head = self.head.swap(null, .acq_rel);
            return .{ .head = head };
        }

        pub fn empty(self: *const @This()) bool {
            return self.head.load(.acquire) == null;
        }
    };
}

pub const LoopState = struct {
    loop: *Loop,

    initialized: bool = false,
    running: bool = false,
    stopped: bool = false,

    /// Not-yet-finished completions owned by this loop. The count lives on the
    /// completion's owning loop (`completion.loop`): incremented at the submit
    /// sites, decremented in `finishCompletion` routed through
    /// `completion.loop`, which may run on a different loop's thread (epoll
    /// single-owner servicing, the shared IOCP port) - hence the atomic. The
    /// scheduler's load shedding also reads other loops' counters.
    active: std.atomic.Value(usize) = .init(0),

    wake_requested: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Cached "now" per wall clock, indexed by `clockIndex`. `awake` is
    /// refreshed eagerly once per scan (`updateNow`); `boot`/`real` are
    /// refreshed lazily on first use within a scan and cached for the rest of
    /// it. `tick` is a monotonically increasing scan counter; `now_tick[i]`
    /// records the scan that `now[i]` was last filled, so a mismatch refreshes.
    tick: u64 = 0,
    now: [wall_clock_count]Timestamp = .{ .zero, .zero, .zero },
    now_tick: [wall_clock_count]u64 = .{ 0, 0, 0 },
    timers: [wall_clock_count]TimerHeap = .{
        .{ .context = {} },
        .{ .context = {} },
        .{ .context = {} },
    },

    /// Intrusive list of thread-pool-delegated works whose cancellation has been
    /// requested but whose worker is still blocked in the canceled syscall. Each
    /// `tick` re-sends `SIGURG` to cover a first signal lost in the tiny window
    /// between `Syscall.begin()` and the kernel entering the sleep. Touched only
    /// on this loop's thread (added in `cancelLocal`, swept in `tick`, removed as
    /// the completion is finalized in the `work_completions` drain).
    cancel_resend: ?*Work = null,
    // TODO: Linked timers optimization
    // Instead of mutex-protected cross-thread timer cancellation, link timers to their
    // associated operations. When an operation completes, its linked timer is cleared
    // on the same thread (no mutex). When a timer fires, its linked operation is
    // cancelled on the same thread. This eliminates cross-thread synchronization for
    // the common timeout pattern:
    //   - Add `linked_timer: ?*Timer` to Completion
    //   - Add `linked_completion: ?*Completion` to Timer
    //   - On operation complete: clear linked timer (same thread, direct)
    //   - On timer fire: cancel linked operation (same thread, direct)
    // The cross-thread cancel mechanism remains for general cancellation (task migration,
    // external cancellation), but timeouts become zero-overhead pointer unlinking.
    /// Protects all timer heaps and the cached `now` values. A single lock is
    /// enough: it's local to the loop and effectively uncontended, only ever
    /// held for O(log n) heap ops with callbacks run outside it.
    timer_mutex: os.Mutex = .init(),

    async_handles: Queue(Completion) = .{},

    completions: Queue(Completion) = .{},
    /// Finished standalone completions awaiting user-callback dispatch, when the
    /// loop was created with `do_not_call_callbacks`. Drained by
    /// `Loop.nextDispatched`.
    dispatched: Queue(Completion) = .{},
    work_completions: AtomicStack(Completion) = .{},

    pub const wake_loop: u32 = 1;
    pub const wake_async: u32 = 2;
    pub const wake_cancel: u32 = 4;

    /// Increment this loop's active completion counter. Counted by the loop at
    /// every submit site (backends do no accounting).
    pub fn incrActive(self: *LoopState) void {
        _ = self.active.fetchAdd(1, .monotonic);
    }

    /// Decrement this loop's active completion counter. Callers must invoke
    /// this on the completion's owning loop (`completion.loop`), not on
    /// whichever loop happens to run the finish (see `finishCompletion`).
    pub fn decrActive(self: *LoopState) void {
        _ = self.active.fetchSub(1, .monotonic);
    }

    /// Read this loop's active completion counter (any thread).
    pub fn loadActive(self: *const LoopState) usize {
        return self.active.load(.monotonic);
    }

    /// Called by backends when an operation they accepted completes. Tells the
    /// backend to drop its inflight count (the backend of the loop running the
    /// completion, whose storage covers the op on every backend) and marks the
    /// completion done.
    pub fn markCompletedFromBackend(self: *LoopState, completion: *Completion) void {
        self.loop.backend.decrInflight();
        self.markCompleted(completion);
    }

    pub fn markCompleted(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .running);
        std.debug.assert(completion.has_result);

        // Atomically set completed flag
        var old = completion.cancel_state.load(.acquire);
        while (true) {
            var new = old;
            new.completed = true;
            old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
        }

        // Always set state
        completion.state = .completed;

        // Only call finish if not in cancel queue
        // If in_queue, cancel queue processing will call finishCompletion
        if (!old.in_queue) {
            self.dispatchCompletion(completion);
        }
    }

    /// Finish now, or queue for processCompletions when the completion uses
    /// deferred finishing (rearm implies it).
    pub fn dispatchCompletion(self: *LoopState, completion: *Completion) void {
        if (completion.flags.defer_callback or completion.flags.rearm) {
            self.completions.push(completion);
        } else {
            self.finishCompletion(completion);
        }
    }

    pub fn finishCompletion(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .completed);

        completion.state = .dead;
        // Route the decrement to the loop that owns the completion: `self` here
        // can be a different loop (epoll single-owner servicing, the shared
        // IOCP port, a group finished by the loop that ran its last member).
        completion.loop.?.state.decrActive();

        // Both callbacks below can free `completion`, so whichever may free it must
        // run LAST, with nothing touching `completion` afterward. Cache the owner
        // callback now, before `call` — for a standalone completion `call` wakes a
        // waiter that may free `completion`, so we must not read it afterward.
        // (Rearm handles are exempt from the freeing contract by definition.)
        const owner_callback = completion.group.owner_callback;
        const was_rearm = completion.flags.rearm;

        // Deferred dispatch: a standalone (non-rearm, no owner) completion is
        // queued for the driver to call itself via `nextDispatched`, rather than
        // invoked here. `completion` was just popped from `completions`, so its
        // queue link is free to reuse. Rearm/group completions fall through and
        // run inline, since their machinery must stay synchronous.
        if (self.loop.do_not_call_callbacks and !was_rearm and owner_callback == null) {
            self.dispatched.push(completion);
            return;
        }

        // The completion's own callback runs first: for a group member it reports
        // the member's own result while the member is still alive; for a standalone
        // completion (no owner) it is the last thing we do.
        completion.call(self.loop);

        // Re-add persistent handles. Re-reading the flag lets a callback stop
        // its own handle; the cached value guards it, since only rearm
        // completions are guaranteed still alive here.
        if (was_rearm and completion.flags.rearm) {
            self.loop.add(completion);
        }

        // Then notify the group/queue owner. This can drive the group to completion
        // and free the frame this member lives on (e.g. the last `.gather` member
        // completing the group, whose callback frees the member), so it must run
        // last — `completion` may be dangling after this returns.
        if (owner_callback) |cb| {
            cb(self.loop, completion);
        }
    }

    pub fn markRunning(self: *LoopState, completion: *Completion) void {
        _ = self;
        completion.state = .running;
    }

    /// Advance the scan counter and refresh the awake snapshot. Bumping `tick`
    /// invalidates the lazily-cached boot/real values for the new scan.
    pub fn updateNow(self: *LoopState) void {
        self.tick +%= 1;
        self.now[0] = time.now(.monotonic);
        self.now_tick[0] = self.tick;
    }

    /// Current time on the given clock, indexed by `clockIndex`. `awake` is a
    /// cache hit (primed eagerly by `updateNow`); `boot`/`real` are read fresh
    /// at most once per scan (cheap VDSO `clock_gettime`) and cached. Reading
    /// them per scan rather than per iteration is what lets the poll cap bound
    /// oversleep across suspend/steps.
    fn nowFor(self: *LoopState, clock: Clock) Timestamp {
        const idx = clockIndex(clock);
        if (self.now_tick[idx] != self.tick) {
            self.now[idx] = time.now(clock);
            self.now_tick[idx] = self.tick;
        }
        return self.now[idx];
    }

    pub fn lockTimers(self: *LoopState) void {
        self.timer_mutex.lock();
    }

    pub fn unlockTimers(self: *LoopState) void {
        self.timer_mutex.unlock();
    }

    pub fn setTimer(self: *LoopState, timer: *Timer) void {
        const idx = clockIndex(timer.clock);
        // Rearming a timer that is mid-fire (out of the heap, result set, its
        // markCompleted still pending outside this lock) cannot work: the timer
        // is already completing and inserting it would double-complete it.
        // Callers must rearm from the completion callback (or after it), never
        // concurrently with the fire.
        std.debug.assert(!(timer.c.state == .running and timer.c.has_result));
        // `.running` means the timer is already in its heap (resetting it);
        // anything else means it's newly activated. Don't key this off
        // `deadline.value`, which can legitimately be 0 for an absolute
        // deadline at/at-before the epoch and would then leak/double-fire.
        if (timer.c.state == .running) {
            self.timers[idx].remove(timer);
        } else {
            self.incrActive();
        }
        switch (timer.timeout) {
            .none => timer.deadline = .{ .value = std.math.maxInt(time.TimeInt) },
            .duration => |d| timer.deadline = self.nowFor(timer.clock).addDuration(d),
            .deadline => |ts| timer.deadline = ts,
        }
        timer.c.state = .running;
        self.timers[idx].insert(timer);
    }

    pub fn clearTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.c.state == .running;
        if (was_active) {
            self.timers[clockIndex(timer.clock)].remove(timer);
        }
        timer.deadline = .zero;
    }

    /// Add a canceled-but-blocked work to the cancel-resend list (idempotent).
    /// Loop-thread only. Only works whose worker is blocked-and-canceling belong
    /// here. `key` is the public completion whose finalization drops the entry
    /// (== `&work.c` for a plain `.work` op, or the owning op's completion for a
    /// delegated file op).
    fn addResend(self: *LoopState, work: *Work, key: *Completion) void {
        if (work.resend_key != null) return;
        work.resend_key = key;
        work.resend_next = self.cancel_resend;
        self.cancel_resend = work;
    }

    /// Remove the work owning `completion` from the resend list, if it is on it.
    /// Called as the completion is finalized (before its waiter is signaled) so
    /// the sweep never dereferences a token whose op is about to be freed. The
    /// list is empty in the common case, so this is O(1) then. Loop-thread only.
    fn removeResendByCompletion(self: *LoopState, completion: *Completion) void {
        if (self.cancel_resend == null) return;
        var slot = &self.cancel_resend;
        while (slot.*) |node| {
            if (node.resend_key == completion) {
                slot.* = node.resend_next;
                node.resend_next = null;
                node.resend_key = null;
                return;
            }
            slot = &node.resend_next;
        }
    }

    /// Re-send `SIGURG` to every still-blocked canceling worker, dropping any
    /// that have acknowledged. Called once per `tick`. Loop-thread only.
    fn sweepResend(self: *LoopState) void {
        var slot = &self.cancel_resend;
        while (slot.*) |node| {
            if (node.cancel_token.?.signal()) {
                // Still blocked-and-canceling; keep it and re-check next tick.
                slot = &node.resend_next;
            } else {
                // Worker acknowledged (or the op finished); stop re-sending.
                slot.* = node.resend_next;
                node.resend_next = null;
                node.resend_key = null;
            }
        }
    }
};

pub const Loop = struct {
    state: LoopState,
    backend: Backend,

    allocator: std.mem.Allocator,
    thread_pool: ?*ThreadPool = null,

    loop_group: *LoopGroup,
    internal_loop_group: LoopGroup = .{},

    max_wait: Duration = .fromSeconds(60),
    /// Upper bound on the poll wait while a boot/real timer is pending on a
    /// backend without native wall-clock timers. The poll clock (`awake`)
    /// can't track suspend or wall-clock steps, so we re-evaluate boot/real
    /// deadlines at least this often; this bounds how late such a timer can
    /// fire after a suspend/step. Unused once a backend arms them natively.
    wall_clock_cap: Duration = .fromSeconds(10),

    /// Cross-thread cancel queue (lock-free MPSC)
    cancel_queue: std.atomic.Value(?*Completion) = std.atomic.Value(?*Completion).init(null),

    in_add: if (in_safe_mode) bool else void = if (in_safe_mode) false else {},

    /// When true, `tick` does not dispatch finished standalone completions to
    /// their callbacks; it queues them instead, and the driver drains them with
    /// `nextDispatched`, invoking the callbacks itself. This lets an embedder
    /// (e.g. a CPython asyncio event loop) run the blocking poll with the GIL
    /// released and then invoke callbacks with the GIL held. Rearm handles and
    /// group-owner callbacks are unaffected (they still run inline).
    do_not_call_callbacks: bool = false,

    const default_queue_size = 256;

    pub const Options = struct {
        allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_pool: ?*ThreadPool = null,
        loop_group: ?*LoopGroup = null,
        queue_size: u16 = default_queue_size,
        do_not_call_callbacks: bool = false,
    };

    pub fn init(self: *Loop, options: Options) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
            .allocator = options.allocator,
            .thread_pool = options.thread_pool,
            .loop_group = undefined,
            .do_not_call_callbacks = options.do_not_call_callbacks,
        };

        if (options.loop_group) |group| {
            self.loop_group = group;
        } else {
            self.loop_group = &self.internal_loop_group;
        }

        if (options.queue_size == 0) {
            return error.InvalidQueueSize;
        }

        net.ensureWSAInitialized();
        self.state.updateNow();

        try self.backend.init(
            options.allocator,
            options.queue_size,
            &self.loop_group.shared,
        );
        errdefer self.backend.deinit();

        self.state.initialized = true;

        if (in_debug_mode) current_loop = self;
    }

    pub fn deinit(self: *Loop) void {
        self.assertOwnThread();
        if (in_debug_mode) current_loop = null;
        self.backend.deinit();
    }

    /// Debug-only: assert we're on the thread that owns this loop.
    inline fn assertOwnThread(self: *const Loop) void {
        if (in_debug_mode) std.debug.assert(current_loop == self);
    }

    pub fn stop(self: *Loop) void {
        self.state.stopped = true;
    }

    /// Pop the next finished standalone completion awaiting user-callback
    /// dispatch (only populated when created with `do_not_call_callbacks`).
    /// Returns null when drained; the caller invokes `completion.call(loop)`.
    pub fn nextDispatched(self: *Loop) ?*Completion {
        return self.state.dispatched.pop();
    }

    pub fn stopped(self: *const Loop) bool {
        return self.state.stopped;
    }

    /// Whether this loop has nothing left to do: every completion it owns
    /// (`completion.loop == this`) has finished. An op may be *serviced* by
    /// another loop of the group, but the active count stays with the owning
    /// loop until the op finishes, so `done()` cannot report true early.
    /// Completions handed out via `nextDispatched` are already finished and do
    /// not keep the loop running.
    pub fn done(self: *const Loop) bool {
        return self.state.stopped or (self.state.loadActive() == 0 and self.state.completions.empty());
    }

    /// Get the current monotonic timestamp
    pub fn now(self: *const Loop) Timestamp {
        return self.state.now[0];
    }

    /// Wake up the loop from another thread (thread-safe)
    pub fn wake(self: *Loop) void {
        // If we're the first to request a wake since the last poll, do the syscall.
        // Subsequent wakers see true and skip - the syscall is already pending.
        if (self.state.wake_requested.fetchOr(LoopState.wake_loop, .acq_rel) == 0) {
            self.backend.wake(&self.state);
        }
    }

    /// Wake up the loop to process async handles (thread-safe)
    pub fn wakeAsync(self: *Loop) void {
        if (self.state.wake_requested.fetchOr(LoopState.wake_async, .acq_rel) == 0) {
            self.backend.wake(&self.state);
        }
    }

    /// Set or reset a timer with a new timeout (works immediately, no completion required)
    pub fn setTimer(self: *Loop, timer: *Timer, timeout: Timeout) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        // Rearming a fired (completed/dead) timer: drop the stale result so
        // that a running timer with a result set unambiguously means "mid-fire"
        // (the limbo state clearTimer must leave alone).
        if (timer.c.state != .running) {
            timer.c.has_result = false;
            timer.c.err = null;
        }
        // Advance the scan so this timer's deadline is computed against a fresh
        // `now` in its own clock (via `nowFor` in `setTimer`).
        self.state.updateNow();
        timer.c.loop = self;
        timer.timeout = timeout;
        self.state.setTimer(timer);
    }

    /// Clear a timer without completing it (works immediately, no cancellation
    /// completion required). Thread-safe: may be called from a thread that does
    /// not own the loop (a migrated task clearing its sleep timer).
    pub fn clearTimer(self: *Loop, timer: *Timer) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        // A running timer that already has its result is in the fired/canceled
        // limbo window: checkTimers (or cancelLocal) removed it from the heap
        // and set its result under this lock, but its markCompleted runs after
        // unlocking. Touching it here would remove a non-member from the heap
        // (corrupting it), clear the result that markCompleted asserts on, and
        // decrement active a second time (finishCompletion will decrement for
        // the same timer). It is already on its way to completion; leave it be.
        if (timer.c.state == .running and timer.c.has_result) return;
        const was_active = timer.c.state == .running;
        self.state.clearTimer(timer);
        if (was_active) {
            // Reset state so timer can be reused
            timer.c.state = .new;
            timer.c.has_result = false;
            timer.c.err = null;
            self.state.decrActive();
        }
    }

    /// Cancel a completion directly without requiring a Cancel completion struct.
    /// This is a fire-and-forget, idempotent operation - the completion's callback will still be
    /// invoked when the operation completes (either with error.Canceled or its natural result).
    /// Thread-safe: can be called from any thread.
    pub fn cancel(self: *Loop, completion: *Completion) void {
        self.assertOwnThread();

        // Check if completion has been added to a loop
        // (loop is set once by addInternal and never changes)
        const target = completion.loop orelse {
            // Not yet submitted - just set requested, addInternal will handle it
            var old = completion.cancel_state.load(.acquire);
            while (true) {
                if (old.requested) return;
                var new = old;
                new.requested = true;
                old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse return;
            }
            return;
        };

        // Atomically set requested and in_queue flags
        var old = completion.cancel_state.load(.acquire);
        while (true) {
            if (old.requested) return; // Already requested
            if (old.completed) return; // Already completed
            var new = old;
            new.requested = true;
            new.in_queue = true;
            old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
        }

        if (self == target) {
            // Same loop - cancel directly
            self.cancelLocal(completion);
        } else {
            // Push to target's cancel queue (lock-free Treiber stack)
            var head = target.cancel_queue.load(.acquire);
            while (true) {
                completion.cancel_next = head;
                head = target.cancel_queue.cmpxchgWeak(head, completion, .release, .acquire) orelse break;
            }

            if (target.state.wake_requested.fetchOr(LoopState.wake_cancel, .acq_rel) == 0) {
                target.backend.wake(&target.state);
            }
        }
    }

    /// Cancel a completion on the local loop (must be called from the loop's thread)
    fn cancelLocal(self: *Loop, completion: *Completion) void {
        defer {
            // Clear in_queue and call finishCompletion if completed
            var old = completion.cancel_state.load(.acquire);
            while (true) {
                var new = old;
                new.in_queue = false;
                old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
            }
            if (old.completed) {
                self.state.dispatchCompletion(completion);
            }
        }

        // If already completed, skip cancel work (defer will still run)
        if (completion.cancel_state.load(.acquire).completed) {
            return;
        }

        switch (completion.op) {
            .group => {
                const group = completion.cast(Group);
                var node = group.head;
                while (node) |n| {
                    const next = n.next;
                    const c: *Completion = @fieldParentPtr("group", n);
                    self.cancel(c);
                    node = next;
                }
            },
            .timer => {
                const timer = completion.cast(Timer);
                self.state.lockTimers();
                // Set the result under the timer lock: a cross-thread
                // Loop.clearTimer keys "already fired/canceled, hands off" on
                // (.running and has_result) under this lock, so the result must
                // never appear outside it while the timer is running.
                timer.c.setError(error.Canceled);
                self.state.clearTimer(timer);
                self.state.unlockTimers();
                self.state.markCompleted(&timer.c);
            },
            .async => {
                const async_handle = completion.cast(Async);
                async_handle.c.setError(error.Canceled);
                _ = self.state.async_handles.remove(&async_handle.c);
                self.state.markCompleted(&async_handle.c);
            },
            .work => {
                const thread_pool = self.thread_pool orelse unreachable;
                const work = completion.cast(Work);
                thread_pool.cancel(work);
                // If the worker is blocked in the canceled syscall, the first
                // SIGURG (sent by cancel above) can be lost in the begin()->sleep
                // window. Track it so `tick` re-sends until the worker acks; the
                // entry is dropped when this completion finalizes.
                if (work.cancel_token) |token| {
                    if (token.isCanceling()) self.state.addResend(work, completion);
                }
            },
            .net_send_file => {
                const op = completion.cast(NetSendFile);
                if (comptime Backend.capabilities.net_send_file) {
                    self.backend.cancel(&self.state, completion);
                } else {
                    self.netSendFileCancel(op);
                }
            },

            inline else => |op| {
                // File/dir ops that can fallback to thread pool
                if (@hasField(BackendCapabilities, @tagName(op))) {
                    if (!@field(Backend.capabilities, @tagName(op))) {
                        // Pollable streaming ops took the backend poll path, not
                        // the thread pool, so they must be canceled there. The
                        // verdict was cached on the op at submission time.
                        if (comptime (op == .file_read_streaming or op == .file_write_streaming)) {
                            if (completion.cast(op.toType()).pollable orelse false) {
                                self.backend.cancel(&self.state, completion);
                                return;
                            }
                        }
                        // file_set_size may have been submitted natively (the
                        // FTRUNCATE SQE) when the runtime probe found kernel
                        // support, so it must be canceled on the backend, not the
                        // thread pool. The probe verdict is stable for the process,
                        // so re-querying here agrees with the submission decision.
                        if (comptime op == .file_set_size and @hasDecl(Backend, "fileSetSizeSupported")) {
                            if (self.backend.fileSetSizeSupported()) {
                                self.backend.cancel(&self.state, completion);
                                return;
                            }
                        }
                        const thread_pool = self.thread_pool orelse unreachable;
                        const op_data = completion.cast(op.toType());
                        thread_pool.cancel(&op_data.internal.work);
                        // If the worker is blocked in the canceled syscall, the
                        // first SIGURG (sent by cancel above) can be lost in the
                        // begin()->sleep window. Track it so `tick` re-sends until
                        // the worker acknowledges. Only DelegatedWork ops have a
                        // token; the entry is removed when the op finalizes.
                        if (@hasField(@TypeOf(op_data.internal), "token")) {
                            if (op_data.internal.token.isCanceling()) {
                                self.state.addResend(&op_data.internal.work, completion);
                            }
                        }
                    } else {
                        self.backend.cancel(&self.state, completion);
                    }
                } else {
                    // Backend operations (net_*, etc)
                    self.backend.cancel(&self.state, completion);
                }
            },
        }
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        std.debug.assert(self.state.initialized);
        if (self.state.stopped) return;
        switch (mode) {
            .no_wait => try self.tick(false),
            .once => try self.tick(true),
            .until_done => while (!self.done()) {
                try self.tick(true);
            },
        }
    }

    pub fn add(self: *Loop, completion: *Completion) void {
        self.assertOwnThread();
        if (in_safe_mode) {
            if (self.in_add) {
                @panic("recursive call to Loop.add() is not allowed");
            }
            self.in_add = true;
        }
        defer {
            if (in_safe_mode) self.in_add = false;
        }
        self.addInternal(completion);
    }

    fn addInternal(self: *Loop, completion: *Completion) void {
        // If completion is dead (callback was called), reset it to new state for rearming
        if (completion.state == .dead) {
            completion.reset();
        }

        std.debug.assert(completion.state == .new);

        // Set the loop reference for cross-thread cancellation
        @atomicStore(?*Loop, &completion.loop, self, .release);

        if (completion.cancel_state.load(.acquire).requested) {
            // Directly mark it as canceled
            completion.setError(error.Canceled);
            self.state.incrActive();
            completion.state = .running;
            self.state.markCompleted(completion);
            return;
        }

        switch (completion.op) {
            .group => {
                const group = completion.cast(Group);

                // Groups cannot be canceled before submission
                if (group.c.cancel_state.load(.acquire).requested) {
                    @panic("cannot cancel a group before adding it to the loop");
                }

                group.c.state = .running;
                self.state.incrActive();

                if (group.remaining.load(.acquire) == 0) {
                    // Empty group - complete immediately
                    group.c.setResult(.group, {});
                    self.state.markCompleted(&group.c);
                } else {
                    // Add all children to the loop
                    var node = group.head;
                    while (node) |n| {
                        const next = n.next;
                        const c: *Completion = @fieldParentPtr("group", n);
                        self.addInternal(c);
                        node = next;
                    }
                }
                return;
            },
            .timer => {
                const timer = completion.cast(Timer);
                self.state.lockTimers();
                self.state.setTimer(timer);
                self.state.unlockTimers();
                return;
            },
            .async => {
                const async = completion.cast(Async);
                async.c.state = .running;
                self.state.incrActive();

                // Check if already notified before submission
                if (checkAndSetAsyncResult(async)) {
                    // Already pending - complete immediately
                    self.state.markCompleted(&async.c);
                } else {
                    // Not pending - add to queue to wait for notification
                    self.state.async_handles.push(&async.c);
                }
                return;
            },
            .work => {
                const work = completion.cast(Work);
                work.completion_fn = loopWorkComplete;
                work.completion_context = @ptrCast(self);
                work.c.state = .running;
                self.state.incrActive();
                if (self.thread_pool) |thread_pool| {
                    thread_pool.submit(work);
                } else {
                    work.state.store(.completed, .release);
                    work.c.setError(error.NoThreadPool);
                    self.state.markCompleted(&work.c);
                }
                return;
            },
            .net_send_file => {
                const op = completion.cast(NetSendFile);
                completion.state = .running;
                self.state.incrActive();
                if (comptime Backend.capabilities.net_send_file) {
                    self.backend.submit(&self.state, completion);
                } else {
                    netSendFileStart(self, op);
                }
                return;
            },
            else => {
                // Streaming reads/writes on a pollable fd (pipe/socket/FIFO/tty)
                // use the backend readiness poll path instead of the thread pool.
                // Seekable fds (regular files, block devices) fall back to the pool.
                switch (completion.op) {
                    inline .file_read_streaming, .file_write_streaming => |op| {
                        // Classify lazily and cache the verdict on the op, so a
                        // reused op (or the caller) can skip re-probing.
                        const data = completion.cast(op.toType());
                        const pollable = data.pollable orelse blk: {
                            if (builtin.os.tag == .windows) {
                                // A streaming op reaching the lazy path on Windows is a
                                // handle zio did not open/classify (foreign, e.g. inherited
                                // stdio reached via std.Io). Such handles are not associated
                                // with our IOCP port, so the loop cannot drive them — route
                                // to the thread pool's blocking read/write.
                                data.pollable = false;
                                break :blk false;
                            }
                            const p = common.probePollable(data.handle);
                            data.pollable = p;
                            break :blk p;
                        };
                        if (comptime !@field(Backend.capabilities, @tagName(op))) {
                            // Route pollable fds to the backend readiness/overlapped path;
                            // seekable fds (regular files, block devices) to the thread pool.
                            if (pollable) {
                                self.state.incrActive();
                                self.backend.submit(&self.state, completion);
                            } else {
                                self.submitFileOpToThreadPool(completion);
                            }
                            return;
                        }
                    },
                    else => {},
                }

                // Ops a backend can handle natively only on some kernels (probed at
                // runtime): if the backend advertises a runtime query and it says
                // yes, use the native SQE path; otherwise fall through to the
                // capability-based routing below (which sends it to the thread pool).
                switch (completion.op) {
                    .file_set_size => {
                        if (comptime @hasDecl(Backend, "fileSetSizeSupported")) {
                            if (self.backend.fileSetSizeSupported()) {
                                self.state.incrActive();
                                self.backend.submit(&self.state, completion);
                                return;
                            }
                        }
                    },
                    else => {},
                }

                // Regular backend operation
                // Route file/dir ops to thread pool for backends without native support
                switch (completion.op) {
                    inline else => |op| {
                        if (@hasField(BackendCapabilities, @tagName(op))) {
                            if (!@field(Backend.capabilities, @tagName(op))) {
                                self.submitFileOpToThreadPool(completion);
                                return;
                            }
                        }
                    },
                }

                self.state.incrActive();
                self.backend.submit(&self.state, completion);
                return;
            },
        }
    }

    const TimerCheckResult = struct {
        next_timeout: ?Duration,
        fired: bool,
    };

    fn checkTimers(self: *Loop) TimerCheckResult {
        const native_wall = Backend.capabilities.native_wall_timers;

        var fired = false;
        var next_timeout: ?Duration = null;
        // For native boot/real clocks: the earliest pending absolute deadline to
        // hand the backend, plus its capped remaining (computed during the scan
        // under the lock) to fold into the poll timeout if the backend can't arm.
        var wall_deadline: [wall_clock_count]?u64 = .{ null, null, null };
        var wall_remaining: [wall_clock_count]Duration = .{ .zero, .zero, .zero };

        // Advance the scan once and refresh the awake snapshot; this also
        // invalidates the lazily-cached boot/real values for this scan.
        // `now`/`tick` are only ever touched by the owning executor thread
        // (`updateNow` is called here and in `setTimer`, both owner-thread; the
        // cross-thread `clearTimer` never reads them), so no timer lock is needed.
        self.state.updateNow();

        // Each wall-clock domain has its own heap, compared against `now` in
        // that clock. The earliest remaining across all domains becomes the
        // poll timeout; `tick`'s caller caps it at `max_wait`, which bounds how
        // far a boot/real timer can oversleep after a suspend or clock step
        // (the re-read of `now(clock)` on the next scan corrects it).
        for (0..wall_clock_count) |idx| {
            const clock = indexClock(idx);

            // Lock-free fast path: an empty heap has nothing to fire and no
            // deadline to contribute, so skip the timer mutex entirely. A null
            // read is always real (see Heap.isEmpty); a stale non-null just falls
            // through to the locked drain below and re-checks.
            if (self.state.timers[idx].isEmpty()) continue;

            // Process fired timers in batches to avoid holding the lock during
            // callbacks. This prevents deadlock when callbacks set/clear timers.
            while (true) {
                var batch: [4]*Timer = undefined;
                var batch_count: usize = 0;

                self.state.lockTimers();
                // `nowFor` is read inside the loop, so an empty heap reads no
                // clock at all; for boot/real the first read fills the cache.
                while (self.state.timers[idx].peek()) |timer| {
                    const now_clock = self.state.nowFor(clock);
                    if (timer.deadline.value > now_clock.value) {
                        if (native_wall and clock != .awake) {
                            // Backend arms this clock natively; record its
                            // earliest deadline, plus a capped remaining to fold
                            // only if the backend later reports it couldn't arm.
                            wall_deadline[idx] = timer.deadline.value;
                            var remaining = now_clock.durationTo(timer.deadline);
                            if (remaining.value > self.wall_clock_cap.value) {
                                remaining = self.wall_clock_cap;
                            }
                            wall_remaining[idx] = remaining;
                        } else {
                            var remaining = now_clock.durationTo(timer.deadline);
                            // boot/real can't be tracked by the awake poll clock,
                            // so bound the wait to re-evaluate across suspend/steps.
                            if (clock != .awake and remaining.value > self.wall_clock_cap.value) {
                                remaining = self.wall_clock_cap;
                            }
                            if (next_timeout == null or remaining.value < next_timeout.?.value) {
                                next_timeout = remaining;
                            }
                        }
                        break;
                    }
                    timer.c.setResult(.timer, {});
                    self.state.clearTimer(timer);
                    batch[batch_count] = timer;
                    batch_count += 1;
                    if (batch_count >= batch.len) break;
                }
                self.state.unlockTimers();

                // Mark completions outside the lock
                for (batch[0..batch_count]) |timer| {
                    self.state.markCompleted(&timer.c);
                    fired = true;
                }

                // If we didn't fill the batch, we're done with this domain
                if (batch_count < batch.len) break;
            }
        }

        // Hand each boot/real minimum to the backend's native wall-clock timer.
        // syncWallTimer returns false only when it couldn't arm a pending
        // deadline (e.g. SQ full); then fold that clock's capped remaining into
        // the poll timeout so it's still re-evaluated within the cap.
        if (comptime native_wall) {
            // Always arm real; arm boot only where it is a distinct clock —
            // otherwise boot timers live in the awake heap and are never handed
            // to the backend (e.g. Windows/IOCP has no boot-clock timer).
            const wall_idxs = comptime if (time.boot_distinct_from_awake) [_]usize{ 1, 2 } else [_]usize{2};
            for (wall_idxs) |idx| {
                const clock = indexClock(idx);
                if (self.backend.syncWallTimer(clock, wall_deadline[idx])) continue;
                const remaining = wall_remaining[idx];
                if (next_timeout == null or remaining.value < next_timeout.?.value) {
                    next_timeout = remaining;
                }
            }
        }

        return .{ .next_timeout = next_timeout, .fired = fired };
    }

    /// Check if an async handle is pending and set its result if so.
    /// Returns true if the async was pending and had its result set.
    /// Caller is responsible for managing queues and calling markCompleted.
    fn checkAndSetAsyncResult(async_handle: *Async) bool {
        const was_pending = async_handle.pending.swap(0, .acquire);
        if (was_pending != 0) {
            async_handle.c.setResult(.async, {});
            return true;
        }
        return false;
    }

    /// Standard completion callback for user-submitted Work
    pub fn loopWorkComplete(ctx: ?*anyopaque, work: *Work) void {
        const loop: *Loop = @ptrCast(@alignCast(ctx));
        loop.state.work_completions.push(&work.c);
        loop.wake();
    }

    /// Linked work context for file operations
    pub const LinkedWorkContext = struct {
        loop: *Loop,
        linked: *Completion,
    };

    /// Completion callback for internal file ops with linked completion
    pub fn loopLinkedWorkComplete(ctx: ?*anyopaque, work: *Work) void {
        const context: *LinkedWorkContext = @ptrCast(@alignCast(ctx));
        // Propagate cancel error from work to linked completion
        if (work.c.err) |err| {
            if (!context.linked.has_result) {
                context.linked.setError(err);
            }
        }
        context.loop.state.work_completions.push(context.linked);
        context.loop.wake();
    }

    pub fn processAsyncHandles(self: *Loop) void {
        // Check all async handles for pending notifications
        var c = self.state.async_handles.head;
        while (c) |completion| {
            const next = completion.next;
            const async_handle = completion.cast(Async);
            if (checkAndSetAsyncResult(async_handle)) {
                // This handle was notified - remove from queue and complete it
                _ = self.state.async_handles.remove(completion);
                self.state.markCompleted(&async_handle.c);
            }
            c = next;
        }
    }

    pub fn processCompletions(self: *Loop) void {
        var work_completions = self.state.work_completions.popAll();
        while (work_completions.pop()) |completion| {
            // Drop from the cancel-resend list before finalizing: markCompleted
            // wakes the waiter, whose coroutine may then free the op (and its
            // token). Removing here keeps the sweep from touching freed memory.
            self.state.removeResendByCompletion(completion);
            self.state.markCompleted(completion);
        }

        // Drain only what was queued at entry: a rearm completion can
        // re-complete itself from its own callback, and chasing those here
        // would let a notify storm pin the loop. The rest runs next tick
        // (non-blocking; pending completions force a zero poll timeout).
        var snapshot = self.state.completions;
        self.state.completions = .{};
        while (snapshot.pop()) |completion| {
            self.state.finishCompletion(completion);
        }
    }

    /// Process cross-thread cancel requests
    fn processCancelQueue(self: *Loop) void {
        // Atomically swap the entire queue
        var c = self.cancel_queue.swap(null, .acquire);
        while (c) |completion| {
            const next = completion.cancel_next;
            completion.cancel_next = null;

            // cancelLocal handles completed check and clears in_queue
            self.cancelLocal(completion);

            c = next;
        }
    }

    fn submitFileOpToThreadPool(self: *Loop, completion: *Completion) void {
        const tp = self.thread_pool orelse {
            // No thread pool - complete with error
            log.err("No thread pool available for file operation", .{});
            completion.state = .running;
            self.state.incrActive();
            completion.setError(error.Unexpected);
            self.state.markCompleted(completion);
            return;
        };

        completion.state = .running;
        self.state.incrActive();

        switch (completion.op) {
            inline .file_open, .file_create, .file_close, .file_read, .file_write, .file_read_streaming, .file_write_streaming, .file_sync, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .dir_create_dir, .dir_rename, .dir_rename_preserve, .dir_delete_file, .dir_delete_dir, .file_size, .file_stat, .dir_open, .dir_close, .dir_read, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link, .device_io_control, .process_wait => |op| {
                if (@field(Backend.capabilities, @tagName(op))) {
                    unreachable;
                }

                const op_func = switch (op) {
                    .file_open => common.fileOpenWork,
                    .file_create => common.fileCreateWork,
                    .file_close => common.fileCloseWork,
                    .file_read => common.fileReadWork,
                    .file_write => common.fileWriteWork,
                    .file_read_streaming => common.fileReadStreamingWork,
                    .file_write_streaming => common.fileWriteStreamingWork,
                    .file_sync => common.fileSyncWork,
                    .file_set_size => common.fileSetSizeWork,
                    .file_set_permissions => common.fileSetPermissionsWork,
                    .file_set_owner => common.fileSetOwnerWork,
                    .file_set_timestamps => common.fileSetTimestampsWork,
                    .dir_create_dir => common.dirCreateDirWork,
                    .dir_rename => common.dirRenameWork,
                    .dir_rename_preserve => common.dirRenamePreserveWork,
                    .dir_delete_file => common.dirDeleteFileWork,
                    .dir_delete_dir => common.dirDeleteDirWork,
                    .file_size => common.fileSizeWork,
                    .file_stat => common.fileStatWork,
                    .dir_open => common.dirOpenWork,
                    .dir_close => common.dirCloseWork,
                    .dir_set_permissions => common.dirSetPermissionsWork,
                    .dir_set_owner => common.dirSetOwnerWork,
                    .dir_set_file_permissions => common.dirSetFilePermissionsWork,
                    .dir_set_file_owner => common.dirSetFileOwnerWork,
                    .dir_set_file_timestamps => common.dirSetFileTimestampsWork,
                    .dir_sym_link => common.dirSymLinkWork,
                    .dir_read_link => common.dirReadLinkWork,
                    .dir_hard_link => common.dirHardLinkWork,
                    .dir_access => common.dirAccessWork,
                    .dir_read => common.dirReadWork,
                    .dir_real_path => common.dirRealPathWork,
                    .dir_real_path_file => common.dirRealPathFileWork,
                    .file_real_path => common.fileRealPathWork,
                    .file_hard_link => common.fileHardLinkWork,
                    .device_io_control => common.deviceIoControlWork,
                    .process_wait => common.processWaitWork,
                    else => unreachable,
                };

                const op_data = completion.cast(op.toType());
                if (@hasField(@TypeOf(op_data.internal), "allocator")) {
                    op_data.internal.allocator = self.allocator;
                }
                op_data.internal.linked_context = .{
                    .loop = self,
                    .linked = completion,
                };
                op_data.internal.work = Work.init(op_func, null);
                op_data.internal.work.completion_fn = loopLinkedWorkComplete;
                op_data.internal.work.completion_context = @ptrCast(&op_data.internal.linked_context);
                // Ops whose internal is a DelegatedWork carry a cancellation
                // token: bind it to the work so the worker enters/exits it and
                // the blocking syscall becomes SIGURG-cancelable.
                if (@hasField(@TypeOf(op_data.internal), "token")) {
                    op_data.internal.work.cancel_token = &op_data.internal.token;
                }
                tp.submit(&op_data.internal.work);
            },
            else => unreachable,
        }
    }

    // --- NetSendFile generic fallback (double-buffered read/send loop) ---
    //
    // Used when the backend does not implement net_send_file natively. Two
    // buffers ping-pong: at most one FileRead and one NetSend are in flight at a
    // time, into *different* buffers, so a read of the next chunk overlaps the
    // send of the current one. Both children typically complete in the same poll
    // window, so the loop retires a read and a send per wakeup (~2x vs. a strict
    // serial read→send loop). `advance` is the pump: after start and after every
    // child completion it (re)starts a send and/or read as buffers allow, and
    // finishes when nothing is in flight and there is nothing left to read.
    //
    // Order is preserved by `next_read`/`next_send`, which both alternate 0,1,0,1
    // from the same start, so buffers are sent in the order they were read.

    fn netSendFileStart(self: *Loop, op: *NetSendFile) void {
        op.internal = .{};
        op.internal.read_remaining = op.remaining;
        // Lay out the working buffers from the (up to two) caller buffers. When
        // the result's bufs[1] is empty the index flips are suppressed (see
        // netSendFileStartRead / netSendFileOnSend), so the loop runs serially.
        op.internal.bufs = sendfileLayout(op.bufs);
        self.netSendFileAdvance(op);
    }

    fn netSendFileStartRead(self: *Loop, op: *NetSendFile) void {
        const f = &op.internal;
        const idx = f.next_read;
        const want = @min(f.bufs[idx].len, f.read_remaining);
        f.reading = idx;
        if (f.bufs[1].len != 0) f.next_read ^= 1;
        f.read = FileRead.init(op.file, ReadBuf.fromSlice(f.bufs[idx][0..want], &f.read_iov), op.offset);
        f.read.c.userdata = op;
        f.read.c.callback = netSendFileOnRead;
        self.addInternal(&f.read.c);
    }

    fn netSendFileStartSend(self: *Loop, op: *NetSendFile, idx: u1, from: usize) void {
        const f = &op.internal;
        f.sending = idx;
        f.send = NetSend.init(op.handle, WriteBuf.fromSlice(f.bufs[idx][from..f.filled[idx]], &f.send_iov), .{});
        f.send.c.userdata = op;
        f.send.c.callback = netSendFileOnSend;
        self.addInternal(&f.send.c);
    }

    /// Forward a cancel to both in-flight children. Their canceled completions
    /// re-enter `netSendFileAdvance`, which finishes the parent only once both
    /// have drained.
    fn netSendFileCancel(self: *Loop, op: *NetSendFile) void {
        if (op.internal.reading != null) self.cancel(&op.internal.read.c);
        if (op.internal.sending != null) self.cancel(&op.internal.send.c);
    }

    fn netSendFileAdvance(self: *Loop, op: *NetSendFile) void {
        const f = &op.internal;

        // A cancel that arrived between callbacks turns into a parked error.
        if (op.c.cancel_state.load(.acquire).requested and f.pending_err == null) {
            f.pending_err = error.Canceled;
        }

        if (f.pending_err) |err| {
            // Cancel whatever is still in flight; only finish once *both* inner
            // completions are done, so we never complete the parent early.
            self.netSendFileCancel(op);
            if (f.reading == null and f.sending == null) self.netSendFileFinish(op, err);
            return;
        }

        // Start sending the next buffer in order, if it is filled and ready.
        if (f.sending == null and f.filled[f.next_send] > 0) {
            f.sent[f.next_send] = 0;
            self.netSendFileStartSend(op, f.next_send, 0);
        }

        // Start the next read into a free buffer, if more data is wanted.
        const reads_done = f.eof or f.read_remaining == 0;
        if (f.reading == null and !reads_done and
            f.filled[f.next_read] == 0 and f.sending != f.next_read)
        {
            self.netSendFileStartRead(op);
        }

        // Nothing in flight and nothing left to read → done.
        if (f.reading == null and f.sending == null and
            f.filled[0] == 0 and f.filled[1] == 0 and reads_done)
        {
            self.netSendFileFinish(op, null);
        }
    }

    fn netSendFileOnRead(loop: *Loop, child: *Completion) void {
        const op: *NetSendFile = @ptrCast(@alignCast(child.userdata.?));
        const f = &op.internal;
        const idx = f.reading.?;
        f.reading = null;
        const n = child.cast(FileRead).getResult() catch |err| {
            f.eof = true;
            f.pending_err = f.pending_err orelse err;
            return loop.netSendFileAdvance(op);
        };
        if (n == 0) {
            f.eof = true;
        } else {
            f.filled[idx] = n;
            f.read_remaining -= n;
            op.offset += n;
        }
        loop.netSendFileAdvance(op);
    }

    fn netSendFileOnSend(loop: *Loop, child: *Completion) void {
        const op: *NetSendFile = @ptrCast(@alignCast(child.userdata.?));
        const f = &op.internal;
        const idx = f.sending.?;
        const m = child.cast(NetSend).getResult() catch |err| {
            f.sending = null;
            f.pending_err = f.pending_err orelse err;
            return loop.netSendFileAdvance(op);
        };
        f.sent[idx] += m;
        f.total += m;
        if (f.sent[idx] < f.filled[idx]) {
            // Socket short-write: resume draining the same buffer.
            loop.netSendFileStartSend(op, idx, f.sent[idx]);
            return loop.netSendFileAdvance(op);
        }
        // Buffer fully drained; hand it back to the read side.
        f.filled[idx] = 0;
        f.sending = null;
        if (f.bufs[1].len != 0) f.next_send ^= 1;
        loop.netSendFileAdvance(op);
    }

    fn netSendFileFinish(self: *Loop, op: *NetSendFile, err: ?anyerror) void {
        if (err) |e| op.c.setError(e) else op.c.setResult(.net_send_file, op.internal.total);
        self.state.markCompleted(&op.c);
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.done()) return;

        const timer_result = self.checkTimers();

        // Re-send SIGURG to any worker still blocked in a canceled syscall.
        self.state.sweepResend();

        var timeout: Duration = .zero;
        if (wait) {
            // Don't block if we have completions waiting to be processed or timers fired
            if (!self.state.completions.empty() or !self.state.work_completions.empty() or timer_result.fired) {
                timeout = .zero;
            } else if (timer_result.next_timeout) |t| {
                // Use timer timeout, capped at max_wait
                timeout = if (t.value < self.max_wait.value) t else self.max_wait;
            } else {
                // No timers, wait for blocking I/O
                timeout = self.max_wait;
            }
            // While cancellations are pending, keep waking to re-send SIGURG so a
            // lost first signal is retried promptly rather than at max_wait.
            if (self.state.cancel_resend != null and timeout.value > resend_interval.value) {
                timeout = resend_interval;
            }
        }

        // Skip backend poll in no_wait mode if there's nothing to retrieve.
        // This avoids syscall overhead for pure CPU-bound workloads.
        const should_poll = wait or self.backend.hasInflight();
        const wake_flags = self.state.wake_requested.swap(0, .acq_rel);
        const timed_out = if (should_poll) try self.backend.poll(&self.state, if (wake_flags != 0) .zero else timeout) else false;

        // Process async handles if the async bit was set
        if (wake_flags & LoopState.wake_async != 0) {
            self.processAsyncHandles();
        }

        // Process cross-thread cancel requests
        if (wake_flags & LoopState.wake_cancel != 0) {
            self.processCancelQueue();
        }

        // Process any work completions from thread pool
        self.processCompletions();

        // Only check timers again if we timed out (avoids syscall when woken by I/O)
        if (timed_out) {
            _ = self.checkTimers();
        }
    }
};

test {
    _ = @import("tests.zig");
}
