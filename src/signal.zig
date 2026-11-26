// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! OS signal watchers.
//!
//! ## Signal safety
//!
//! The Unix handler runs in signal context, on whatever thread the kernel
//! picked, possibly in the middle of zio's own scheduler or wait-queue code on
//! that same thread. So it touches nothing that takes a lock, or that the
//! interrupted code could be halfway through updating. For each watcher of
//! the signal it:
//!
//! - adds the delivery to the watcher's state word and marks it dirty (one
//!   CAS),
//! - claims and signals the waiters parked in the watcher's thread slots,
//!   whose wake is a futex wake on a thread (an atomic and a syscall),
//!
//! and then notifies every executor's `ev.Async` (an atomic and an eventfd
//! write or kevent trigger). Task waiters sit in the watcher's wait queue,
//! which the handler never touches: the first executor to run the
//! notification wakes them from its loop, in ordinary thread context.
//!
//! On Windows the console control handler already runs on a thread of its
//! own, so it wakes every waiter directly.

const std = @import("std");
const builtin = @import("builtin");
const posix = @import("os/posix.zig");
const os = @import("os/root.zig");
const ev = @import("ev/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const Group = @import("group.zig").Group;
const common = @import("common.zig");
const Cancelable = common.Cancelable;
const Timeoutable = common.Timeoutable;
const Timeout = @import("time.zig").Timeout;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("utils/wait_queue.zig").WaitNode;
const AutoCancel = @import("autocancel.zig").AutoCancel;
const w = @import("os/windows.zig");
const Waiter = @import("common.zig").Waiter;

pub const SignalKind = switch (builtin.os.tag) {
    .windows => enum(u8) {
        interrupt = w.CTRL_C_EVENT,
        terminate = w.CTRL_CLOSE_EVENT,
    },
    else => enum(u8) {
        interrupt = @backingInt(posix.SIG.INT),
        terminate = @backingInt(posix.SIG.TERM),
        hangup = @backingInt(posix.SIG.HUP),
        alarm = @backingInt(posix.SIG.ALRM),
        child = @backingInt(posix.SIG.CHLD),
        pipe = @backingInt(posix.SIG.PIPE),
        quit = @backingInt(posix.SIG.QUIT),
        user1 = @backingInt(posix.SIG.USR1),
        user2 = @backingInt(posix.SIG.USR2),
        _,
    },
};

const NO_SIGNAL = 255;
const MAX_HANDLERS = 32;

/// Waiters per watcher that the handler can wake itself. A thread waiter
/// beyond these goes to the wait queue, where only an executor wakes it.
const THREAD_SLOTS = 4;

/// A watcher's state, in one atomic word so that the handler's delivery and
/// the watcher's slot being reused order against each other.
const EntryState = packed struct(u64) {
    /// The signal watched, or `NO_SIGNAL` for a free slot.
    kind: u8 = NO_SIGNAL,
    /// Set with each delivery, cleared by the executor that wakes the task
    /// waiters for it.
    dirty: bool = false,
    _reserved: u23 = 0,
    /// Deliveries not yet consumed by a wait.
    count: u32 = 0,
};

const HandlerEntry = struct {
    state: std.atomic.Value(EntryState) = .init(.{}),
    /// Task waiters. Never touched by the handler: executors wake them.
    waiters: WaitQueue(WaitNode) = .empty,
    /// Waiters whose wake lands on a thread. The handler claims and signals
    /// them itself; see `wakesThread`.
    thread_waiters: [THREAD_SLOTS]std.atomic.Value(?*Waiter) = @splat(.init(null)),

    /// Record a delivery of `signum` if this entry watches it. Signal-safe.
    fn deliver(self: *HandlerEntry, signum: u8) bool {
        var old = self.state.load(.monotonic);
        while (true) {
            if (old.kind != signum) return false;
            var new = old;
            new.count +|= 1;
            new.dirty = true;
            // seq_cst: pairs with a registration's recheck (see `Signal.arm`).
            old = self.state.cmpxchgWeak(old, new, .seq_cst, .monotonic) orelse return true;
        }
    }

    /// Consume the pending deliveries, returning how many there were.
    fn take(self: *HandlerEntry) u32 {
        var old = self.state.load(.monotonic);
        while (old.count != 0) {
            var new = old;
            new.count = 0;
            old = self.state.cmpxchgWeak(old, new, .acquire, .monotonic) orelse return old.count;
        }
        return 0;
    }

    /// Return deliveries taken by `take` that could not be used.
    fn putBack(self: *HandlerEntry, n: u32) void {
        var old = self.state.load(.monotonic);
        while (true) {
            var new = old;
            new.count +|= n;
            old = self.state.cmpxchgWeak(old, new, .release, .monotonic) orelse return;
        }
    }

    fn hasPending(self: *HandlerEntry) bool {
        return self.state.load(.seq_cst).count != 0;
    }

    /// Clear the dirty flag, returning whether it was set.
    fn takeDirty(self: *HandlerEntry) bool {
        var old = self.state.load(.monotonic);
        while (old.dirty) {
            var new = old;
            new.dirty = false;
            old = self.state.cmpxchgWeak(old, new, .acquire, .monotonic) orelse return true;
        }
        return false;
    }

    /// Register `waiter` for the next delivery.
    ///
    /// First settles a delivery that is still marked dirty: its count may
    /// already have been consumed through a fast path, and a dispatch that
    /// ran after this registration would then wake the waiter for a signal
    /// it already returned for. The waiters queued before that delivery are
    /// woken here instead, as the dispatch would have. A delivery that lands
    /// after this marks the entry dirty again, and the caller's recheck of
    /// the count covers it.
    fn register(self: *HandlerEntry, waiter: *Waiter) void {
        if (self.takeDirty()) self.wakeQueued();

        if (wakesThread(waiter)) {
            for (&self.thread_waiters) |*slot| {
                // seq_cst: pairs with the handler's delivery CAS; see `Signal.arm`.
                if (slot.cmpxchgStrong(null, waiter, .seq_cst, .monotonic) == null) return;
            }
        }
        self.waiters.push(&waiter.node);
    }

    /// Undo `register`. Returns false if a wake already claimed the waiter:
    /// its signal is then on the way.
    fn unregister(self: *HandlerEntry, waiter: *Waiter) bool {
        for (&self.thread_waiters) |*slot| {
            if (slot.load(.monotonic) == waiter) {
                return slot.cmpxchgStrong(waiter, null, .acq_rel, .monotonic) == null;
            }
        }
        return self.waiters.remove(&waiter.node);
    }

    /// Claim and signal the waiters in the thread slots. Signal-safe: every
    /// waiter there wakes a thread, never a task.
    fn wakeThreadWaiters(self: *HandlerEntry) void {
        for (&self.thread_waiters) |*slot| {
            const waiter = slot.load(.seq_cst) orelse continue;
            if (slot.cmpxchgStrong(waiter, null, .acq_rel, .monotonic) == null) waiter.signal();
        }
    }

    /// Pop and signal the queued waiters. Not signal-safe.
    fn wakeQueued(self: *HandlerEntry) void {
        while (self.waiters.pop()) |node| Waiter.fromNode(node).signalExternal();
    }

    /// Wake every waiter. Not signal-safe.
    fn wakeAll(self: *HandlerEntry) void {
        self.wakeThreadWaiters();
        self.wakeQueued();
    }
};

/// Whether a signal to `waiter` wakes a thread rather than a task, and so is
/// safe to send from a signal handler.
fn wakesThread(waiter: *const Waiter) bool {
    const direct: *const Waiter = switch (waiter.mode) {
        .direct => waiter,
        .select => |*s| s.parent,
    };
    return direct.directTask() == null;
}

const RegistryUnix = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = @splat(.{}),
    /// Serializes install, uninstall, executor (de)registration and the
    /// executors' dispatch. Never taken by the handler.
    mutex: os.Mutex = .init(),
    /// Watchers per signal; the OS handler is installed while nonzero.
    installed: [256]u8 = @splat(0),
    /// The handlers our own replaced, restored by the last uninstall.
    prev_handlers: [256]posix.Sigaction = undefined,
    /// Executors to notify, linked through `ExecutorHook.next`.
    executors: std.atomic.Value(?*ExecutorHookUnix) = .init(null),
    /// Handlers currently running, on any thread. Whoever unlinks something
    /// the handler may be using waits for this to drain before reusing it.
    active_handlers: std.atomic.Value(u32) = .init(0),

    fn install(self: *RegistryUnix, kind: SignalKind) !*HandlerEntry {
        const signum: u8 = @backingInt(kind);

        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = for (&self.handlers) |*entry| {
            if (entry.state.load(.monotonic).kind == NO_SIGNAL) break entry;
        } else return error.TooManySignalHandlers;

        std.debug.assert(!entry.waiters.hasWaiters());
        entry.state.store(.{ .kind = signum }, .release);

        if (self.installed[signum] == 0) {
            var sa = posix.Sigaction{
                .handler = .{ .handler = signalHandlerUnix },
                .mask = posix.sigemptyset(),
                .flags = posix.SA.RESTART,
            };
            posix.sigaction(signum, &sa, &self.prev_handlers[signum]);
        }
        self.installed[signum] += 1;

        return entry;
    }

    fn uninstall(self: *RegistryUnix, kind: SignalKind, entry: *HandlerEntry) void {
        const signum: u8 = @backingInt(kind);

        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(entry.state.load(.monotonic).kind == signum);
        // seq_cst: once `active_handlers` reads zero below, no handler still
        // running saw this entry as watching `signum`.
        entry.state.store(.{}, .seq_cst);

        self.installed[signum] -= 1;
        if (self.installed[signum] == 0) {
            posix.sigaction(signum, &self.prev_handlers[signum], null);
        }

        // A handler that delivered to this entry may still be about to claim
        // its thread slots; let it finish before a new owner can fill them.
        while (self.active_handlers.load(.seq_cst) != 0) os.thread.yield();
    }

    /// Wake the task waiters of every entry with a delivery since the last
    /// call. Runs on an executor, from its loop.
    fn dispatch(self: *RegistryUnix) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.handlers) |*entry| {
            if (entry.takeDirty()) entry.wakeQueued();
        }
    }
};

const RegistryWindows = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = @splat(.{}),
    /// Serializes install, uninstall and the console control handler, which
    /// runs on a thread of its own.
    mutex: os.Mutex = .init(),
    /// Total number of watchers. Only one global console control handler for
    /// all signals.
    total_handlers: usize = 0,

    fn install(self: *RegistryWindows, kind: SignalKind) !*HandlerEntry {
        const signum: u8 = @backingInt(kind);

        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = for (&self.handlers) |*entry| {
            if (entry.state.load(.monotonic).kind == NO_SIGNAL) break entry;
        } else return error.TooManySignalHandlers;

        if (self.total_handlers == 0) {
            if (w.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, w.TRUE) == w.FALSE) {
                return error.SetConsoleCtrlHandlerFailed;
            }
        }
        self.total_handlers += 1;

        std.debug.assert(!entry.waiters.hasWaiters());
        entry.state.store(.{ .kind = signum }, .release);
        return entry;
    }

    fn uninstall(self: *RegistryWindows, kind: SignalKind, entry: *HandlerEntry) void {
        const signum: u8 = @backingInt(kind);

        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(entry.state.load(.monotonic).kind == signum);
        entry.state.store(.{}, .release);

        self.total_handlers -= 1;
        if (self.total_handlers == 0) {
            _ = w.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, w.FALSE);
        }
    }
};

const Registry = if (builtin.os.tag == .windows) RegistryWindows else RegistryUnix;

var registry: Registry = .{};

/// Per-executor hook through which the signal handler gets task waiters
/// woken. Every executor attaches one to its loop for its whole life.
const ExecutorHookUnix = struct {
    async: ev.Async = .init(),
    next: std.atomic.Value(?*ExecutorHookUnix) = .init(null),

    /// Arm the hook on `loop` and make it visible to the handler. Must be
    /// called on the loop's thread.
    pub fn attach(self: *ExecutorHookUnix, loop: *ev.Loop) void {
        self.* = .{};
        self.async.c.callback = dispatchCallback;
        self.async.c.flags.rearm = true;
        loop.add(&self.async.c);

        registry.mutex.lock();
        defer registry.mutex.unlock();
        self.next.store(registry.executors.load(.monotonic), .monotonic);
        registry.executors.store(self, .seq_cst);
    }

    /// Unlink the hook, and wait until no handler can still be notifying it.
    /// After this the hook may be freed once its loop is deinitialized.
    pub fn detach(self: *ExecutorHookUnix) void {
        {
            registry.mutex.lock();
            defer registry.mutex.unlock();
            var link = &registry.executors;
            while (link.load(.monotonic)) |hook| : (link = &hook.next) {
                if (hook == self) {
                    // seq_cst: pairs with the handler's `active_handlers`
                    // increment and list loads.
                    link.store(self.next.load(.monotonic), .seq_cst);
                    break;
                }
            }
        }
        while (registry.active_handlers.load(.seq_cst) != 0) os.thread.yield();
    }

    fn dispatchCallback(_: *ev.Loop, _: *ev.Completion) void {
        registry.dispatch();
    }
};

const ExecutorHookWindows = struct {
    pub fn attach(_: *ExecutorHookWindows, _: *ev.Loop) void {}
    pub fn detach(_: *ExecutorHookWindows) void {}
};

pub const ExecutorHook = if (builtin.os.tag == .windows) ExecutorHookWindows else ExecutorHookUnix;

const SavedErrno = if (builtin.link_libc) c_int else void;

fn saveErrno() SavedErrno {
    return if (builtin.link_libc) std.c._errno().* else {};
}

fn restoreErrno(saved: SavedErrno) void {
    if (builtin.link_libc) std.c._errno().* = saved;
}

/// The Unix signal handler. Signal-safe: see the module documentation.
fn signalHandlerUnix(sig: posix.SIG) callconv(.c) void {
    const saved_errno = saveErrno();
    defer restoreErrno(saved_errno);

    _ = registry.active_handlers.fetchAdd(1, .seq_cst);
    defer _ = registry.active_handlers.fetchSub(1, .release);

    const signum: u8 = @intCast(@backingInt(sig));
    var delivered = false;
    for (&registry.handlers) |*entry| {
        if (entry.deliver(signum)) {
            entry.wakeThreadWaiters();
            delivered = true;
        }
    }
    if (!delivered) return;

    var hook = registry.executors.load(.seq_cst);
    while (hook) |h| : (hook = h.next.load(.seq_cst)) {
        h.async.notify();
    }
}

fn consoleCtrlHandlerWindows(ctrl_type: w.DWORD) callconv(.winapi) w.BOOL {
    // Map Windows control events to SignalKind values
    const signal_value: u8 = switch (ctrl_type) {
        w.CTRL_C_EVENT => @backingInt(SignalKind.interrupt),
        w.CTRL_CLOSE_EVENT => @backingInt(SignalKind.terminate),
        else => return w.FALSE, // Not handled
    };

    // This runs on a thread of its own, not in signal context: wake the
    // waiters directly.
    registry.mutex.lock();
    defer registry.mutex.unlock();

    var found_handler = false;
    for (&registry.handlers) |*entry| {
        if (entry.deliver(signal_value)) {
            entry.wakeAll();
            found_handler = true;
        }
    }

    // Return TRUE if we handled it, FALSE to pass to default handler
    return if (found_handler) w.TRUE else w.FALSE;
}

/// OS signal watcher.
///
/// Signal allows tasks to wait for OS signals (Unix) or console control events (Windows).
/// Multiple watchers can be registered for the same signal type, and all watchers will
/// be notified when the signal is received.
///
/// Signal watchers use an internal counter to track received signals, preventing signal
/// loss between wait operations. If a signal is received while no task is waiting, the
/// next wait operation will return immediately.
///
/// Waiting works from tasks and from plain threads. Up to four threads can
/// wait on one watcher at a time; further threads are only woken when an
/// executor of some runtime runs its event loop. That includes a task waiting
/// inside a no-suspend region, which blocks its executor's thread: with no
/// free slot, it depends on another executor to wake it.
///
/// Example:
/// ```zig
/// var sig = try Signal.init(.interrupt);
/// defer sig.deinit();
/// try sig.wait();  // Blocks until SIGINT is received
/// ```
pub const Signal = struct {
    kind: SignalKind,
    entry: *HandlerEntry,

    // Future protocol - allows Signal to be used with select()
    pub const Result = void;

    /// Initializes a new signal watcher for the specified signal kind.
    /// Multiple watchers can be registered for the same signal type.
    ///
    /// When the first watcher for a signal type is initialized, the OS signal handler
    /// is installed and the previous handler is saved.
    ///
    /// Returns error.TooManySignalHandlers if MAX_HANDLERS (32) concurrent watchers are already registered.
    pub fn init(kind: SignalKind) !Signal {
        const entry = try registry.install(kind);
        return .{ .kind = kind, .entry = entry };
    }

    /// Deinitializes the signal watcher and releases its resources.
    ///
    /// When the last watcher for a signal type is deinitialized, the previous OS signal
    /// handler is restored.
    pub fn deinit(self: *Signal) void {
        registry.uninstall(self.kind, self.entry);
        self.entry = undefined;
    }

    /// Waits for the signal to be received.
    /// If the signal was already received (counter > 0), returns immediately.
    /// Otherwise, suspends the current task until the signal is received.
    ///
    /// This function can be called multiple times - each call will wait for a new signal.
    /// The internal counter is reset after each wait, ensuring signals are not lost.
    ///
    /// Returns error.Canceled if the task is cancelled while waiting (including due to timeout expiry).
    pub fn wait(self: *Signal) Cancelable!void {
        var waiter: Waiter = .init();
        defer waiter.deinit();

        if (!self.arm(&waiter)) return;

        waiter.wait(1, .allow_cancel) catch |err| {
            self.disarm(&waiter);
            return err;
        };

        // Consume the counter
        _ = self.entry.take();
    }

    /// Waits for the signal to be received with a timeout.
    /// If the signal was already received (counter > 0), returns immediately.
    /// Otherwise, suspends the current task until either:
    /// - The signal is received (returns successfully)
    /// - The timeout expires (returns error.Timeout)
    /// - The task is cancelled (returns error.Canceled)
    ///
    /// This function can be called multiple times - each call will wait for a new signal.
    /// The internal counter is reset after each wait, ensuring signals are not lost.
    ///
    /// Arguments:
    /// - timeout: Timeout
    pub fn waitTimeout(self: *Signal, timeout: Timeout) (Timeoutable || Cancelable)!void {
        var waiter: Waiter = .init();
        defer waiter.deinit();

        if (!self.arm(&waiter)) return;

        // Set up timeout timer
        var timer = AutoCancel.init;
        defer timer.clear();
        timer.set(timeout);

        waiter.wait(1, .allow_cancel) catch |err| {
            self.disarm(&waiter);

            // Check if this auto-cancel triggered, otherwise it was user cancellation
            if (timer.check(err)) return error.Timeout;
            return err;
        };

        // Consume the counter
        _ = self.entry.take();
    }

    /// Alias for `waitTimeout`. Deprecated, will be removed in a future release.
    pub const timedWait = waitTimeout;

    /// Register `waiter` for the next delivery, unless one is already
    /// pending: then consume it and return false, with nothing registered.
    fn arm(self: *Signal, waiter: *Waiter) bool {
        while (true) {
            if (self.entry.take() > 0) return false;
            self.entry.register(waiter);
            // A delivery that landed before the registration was visible
            // found nobody to wake. The registration and this load are
            // seq_cst (or ordered through the wait queue's lock, which the
            // dispatching executor takes after seeing the delivery), so
            // either this sees the delivery or its wake finds the waiter.
            if (!self.entry.hasPending()) return true;
            // Already claimed by a wake: its signal is on the way.
            if (!self.entry.unregister(waiter)) return true;
        }
    }

    /// Undo `arm` after an interrupted wait, waiting out a wake that already
    /// claimed the waiter.
    fn disarm(self: *Signal, waiter: *Waiter) void {
        if (!self.entry.unregister(waiter)) waiter.wait(1, .no_cancel);
    }

    /// Registers a waiter to be notified when the signal is received, or
    /// claims the select if one already was.
    /// This is part of the Future protocol for select().
    pub fn asyncWait(self: *Signal, waiter: *Waiter) common.AsyncWaitState {
        // Unhook any previous registration so a re-poll never
        // double-registers; one that is already gone was claimed and signaled
        // by a wake. A direct waiter is never re-polled, so it never has a
        // registration to unhook.
        const had_registration = !waiter.isDirect() and self.entry.unregister(waiter);

        while (true) {
            const n = self.entry.take();
            if (n > 0) {
                switch (waiter.tryClaim()) {
                    .won => return if (had_registration) .ready else .ready_signaled,
                    .busy => unreachable,
                    .lost => {
                        // A lost arm may not consume: the count is additive, so
                        // put it back and re-broadcast to waiters that may have
                        // gone back to sleep while we held it.
                        self.entry.putBack(n);
                        self.entry.wakeAll();
                        return .decided;
                    },
                }
            }

            self.entry.register(waiter);
            // Same recheck as `arm`.
            if (!self.entry.hasPending()) break;
            if (!self.entry.unregister(waiter)) break;
        }
        return if (had_registration) .queued else .requeued;
    }

    /// Cancels a pending wait operation by removing the waiter.
    /// This is part of the Future protocol for select().
    /// Returns true if removed, false if already removed by completion (wake in-flight).
    pub fn asyncCancelWait(self: *Signal, waiter: *Waiter) bool {
        // Simply remove - no need to wake another waiter since signals broadcast to all
        return self.entry.unregister(waiter);
    }

    /// Gets the result value.
    /// This is part of the Future protocol for select().
    pub fn getResult(self: *Signal) void {
        // Consume the counter to ensure signal is acknowledged
        _ = self.entry.take();
    }
};

test "Signal: basic signal handling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var signal_received = false;

    const waitForSignal = struct {
        fn call(flag: *bool) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();
            try sig.wait();
            flag.* = true;
        }
    }.call;

    const sendSignal = struct {
        fn call(r: *Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(@backingInt(SignalKind.interrupt));
        }
    }.call;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(waitForSignal, .{&signal_received});
    try group.spawn(sendSignal, .{rt});

    try group.wait();

    try std.testing.expect(signal_received);
}

test "Signal: multiple handlers for same signal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var count = std.atomic.Value(usize).init(0);

    const waitForSignal = struct {
        fn call(cnt: *std.atomic.Value(usize)) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();
            try sig.wait();
            _ = cnt.fetchAdd(1, .monotonic);
        }
    }.call;

    const sendSignal = struct {
        fn call(r: *Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(@backingInt(SignalKind.interrupt));
        }
    }.call;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(waitForSignal, .{&count});
    try group.spawn(waitForSignal, .{&count});
    try group.spawn(waitForSignal, .{&count});
    try group.spawn(sendSignal, .{rt});

    try group.wait();

    try std.testing.expectEqual(3, count.load(.monotonic));
}

test "Signal: waitTimeout timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var sig = try Signal.init(.interrupt);
    defer sig.deinit();

    const result = sig.waitTimeout(.{ .duration = .fromMilliseconds(50) });
    try std.testing.expectError(error.Timeout, result);
}

test "Signal: waitTimeout receives signal before timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var signal_received = false;

    const waitForSignalTimed = struct {
        fn call(flag: *bool) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();
            try sig.waitTimeout(.{ .duration = .fromSeconds(1) });
            flag.* = true;
        }
    }.call;

    const sendSignal = struct {
        fn call(r: *Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(@backingInt(SignalKind.interrupt));
        }
    }.call;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(waitForSignalTimed, .{&signal_received});
    try group.spawn(sendSignal, .{rt});

    try group.wait();

    try std.testing.expect(signal_received);
}

test "Signal: select on multiple signals" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    var signal_received = std.atomic.Value(u8).init(0);

    const waitForSignals = struct {
        fn call(flag: *std.atomic.Value(u8)) !void {
            var sig1 = try Signal.init(.user1);
            defer sig1.deinit();
            var sig2 = try Signal.init(.user2);
            defer sig2.deinit();

            const result = try select(.{ .sig1 = &sig1, .sig2 = &sig2 });
            switch (result) {
                .sig1 => flag.store(@backingInt(SignalKind.user1), .monotonic),
                .sig2 => flag.store(@backingInt(SignalKind.user2), .monotonic),
            }
        }
    }.call;

    const sendSignal = struct {
        fn call(r: *Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(@backingInt(SignalKind.user2));
        }
    }.call;

    var group: Group = .init;
    defer group.cancel();

    try group.spawn(waitForSignals, .{&signal_received});
    try group.spawn(sendSignal, .{rt});

    try group.wait();

    try std.testing.expectEqual(@backingInt(SignalKind.user2), signal_received.load(.monotonic));
}

test "Signal: select with signal already received (fast path)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    var sig = try Signal.init(.user1);
    defer sig.deinit();

    // Send signal first
    try posix.raise(@backingInt(SignalKind.user1));

    // Small delay to ensure signal is processed
    try rt.sleep(.fromMilliseconds(10));

    // Now select should return immediately (fast path)
    const result = try select(.{ .sig = &sig });
    var signal_received = false;
    switch (result) {
        .sig => signal_received = true,
    }

    try std.testing.expect(signal_received);
}

test "Signal: select with signal and task" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    const slowTask = struct {
        fn call(r: *Runtime) !u32 {
            try r.sleep(.fromMilliseconds(100));
            return 42;
        }
    }.call;

    const sendSignal = struct {
        fn call(r: *Runtime) !void {
            try r.sleep(.fromMilliseconds(10));
            try posix.raise(@backingInt(SignalKind.user1));
        }
    }.call;

    var sig = try Signal.init(.user1);
    defer sig.deinit();

    var task = try rt.spawn(slowTask, .{rt});
    defer task.cancel();

    var sender = try rt.spawn(sendSignal, .{rt});
    defer sender.cancel();

    // Signal should win (arrives much sooner)
    const result = try select(.{ .sig = &sig, .task = &task });
    var winner: enum { signal, task } = .task;
    switch (result) {
        .sig => winner = .signal,
        .task => |val| {
            _ = try val;
            winner = .task;
        },
    }

    try sender.join();

    try std.testing.expectEqual(.signal, winner);
}

test "Signal: a delivery that races the commit fence is not lost" {
    // A delivery wakes every waiter. When the select's sweep
    // holds the commit fence for another arm, that signal cannot claim the
    // winner word, and a re-poll afterwards need not recover it: a second
    // waiter can consume the shared counter first. The bounced arm must be
    // recorded instead, matching Signal.wait(), which returns on the signal
    // without requiring the counter.
    const NO_WINNER = common.NO_WINNER;

    var sig = try Signal.init(.interrupt);
    defer sig.deinit();

    var parent = Waiter.initSelectParent();
    defer parent.deinit();
    var winner: std.atomic.Value(usize) = .init(NO_WINNER);
    var gen: std.atomic.Value(u32) = .init(0);
    var pending: std.atomic.Value(usize) = .init(NO_WINNER);
    var waiter = Waiter.initSelect(&parent, &winner, &gen, &pending, 2);

    try std.testing.expectEqual(.requeued, sig.asyncWait(&waiter));

    // Owner's sweep is committing a different arm when the signal arrives.
    winner.store(common.COMMITTING, .seq_cst);
    try std.testing.expect(sig.entry.deliver(@backingInt(SignalKind.interrupt)));
    sig.entry.wakeAll();

    // A peer waiter drains the counter before we get to look again.
    winner.store(NO_WINNER, .seq_cst);
    _ = sig.entry.take();

    // Re-polling cannot see it: the counter is gone.
    try std.testing.expectEqual(.requeued, sig.asyncWait(&waiter));

    // The arm's identity survived, so the select still reports it.
    try std.testing.expectEqual(2, pending.load(.acquire));
    try std.testing.expect(Waiter.promotePending(&winner, &pending));
    try std.testing.expectEqual(2, winner.load(.acquire));

    _ = sig.asyncCancelWait(&waiter);
}

test "Signal: a plain thread is woken without any runtime" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // No runtime, so no executor to dispatch anything: the handler itself
    // must wake a thread waiter.
    var sig = try Signal.init(.user1);
    defer sig.deinit();

    var done: std.atomic.Value(bool) = .init(false);
    const Waiting = struct {
        fn run(s: *Signal, d: *std.atomic.Value(bool)) void {
            s.wait() catch unreachable;
            d.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Waiting.run, .{ &sig, &done });

    // Deliver only once the waiter is parked, so the wake, not the count's
    // fast path, is what gets it out.
    while (sig.entry.thread_waiters[0].load(.acquire) == null) os.thread.yield();
    try posix.raise(@backingInt(SignalKind.user1));

    thread.join();
    try std.testing.expect(done.load(.acquire));
}

test "Signal: a signal storm on an executor thread" {
    // The handler interrupts the executor in the middle of whatever it is
    // doing (run queue pushes and pops, wait queue registrations and
    // removals, its own select sweeps). Nothing it does there may take a
    // lock or touch the scheduler.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var sig = try Signal.init(.user1);
    defer sig.deinit();
    var other = try Signal.init(.user2);
    defer other.deinit();

    const Storm = struct {
        stop: std.atomic.Value(bool) = .init(false),
        pid: linux.pid_t,
        tid: linux.pid_t,

        fn run(self: *@This()) void {
            // Leave the executor room to make progress between deliveries.
            const pause: linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_us };
            while (!self.stop.load(.acquire)) {
                _ = linux.tgkill(self.pid, self.tid, .USR1);
                _ = linux.nanosleep(&pause, null);
            }
        }
    };
    // The main thread runs the runtime's only executor.
    var storm: Storm = .{ .pid = linux.getpid(), .tid = linux.gettid() };
    const storm_thread = try std.Thread.spawn(.{}, Storm.run, .{&storm});
    var storm_running = true;
    defer if (storm_running) {
        storm.stop.store(true, .release);
        storm_thread.join();
    };

    const Churn = struct {
        fn timedWaits(s: *Signal) !void {
            for (0..500) |_| {
                s.waitTimeout(.{ .duration = .fromMicroseconds(50) }) catch |err| switch (err) {
                    error.Timeout => {},
                    else => |e| return e,
                };
            }
        }

        fn selects(s: *Signal, o: *Signal) !void {
            for (0..500) |_| {
                _ = try select(.{ .sig = s, .other = o });
            }
        }

        fn waitForever(s: *Signal) !void {
            while (true) try s.wait();
        }

        fn yields() !void {
            for (0..5000) |_| try @import("runtime.zig").yield();
        }

        fn expectSignal(s: *Signal) !void {
            try s.waitTimeout(.{ .duration = .fromSeconds(5) });
        }
    };

    var group: Group = .init;
    defer group.cancel();
    try group.spawn(Churn.timedWaits, .{&sig});
    try group.spawn(Churn.selects, .{ &sig, &other });
    try group.spawn(Churn.yields, .{});
    try group.spawn(Churn.yields, .{});

    // Waits that get canceled while deliveries race them.
    for (0..20) |_| {
        var forever: Group = .init;
        defer forever.cancel();
        for (0..8) |_| try forever.spawn(Churn.waitForever, .{&sig});
        try rt.sleep(.fromMicroseconds(200));
    }

    try group.wait();

    storm.stop.store(true, .release);
    storm_thread.join();
    storm_running = false;

    // No wake was lost: a waiter parked after the storm still gets one.
    _ = sig.entry.take();
    var waiting = try rt.spawn(Churn.expectSignal, .{&sig});
    defer waiting.cancel();
    try rt.sleep(.fromMilliseconds(10));
    try posix.raise(@backingInt(SignalKind.user1));
    try waiting.join();
}

test "Signal: one delivery wakes a wait once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var sig = try Signal.init(.user1);
    defer sig.deinit();

    // Delivered on this (the executor's) thread, so the executor has not yet
    // run the dispatch for it when the wait below takes it.
    try posix.raise(@backingInt(SignalKind.user1));
    try sig.wait();

    // The delivery is used up: the leftover dispatch must not wake the next
    // wait.
    try std.testing.expectError(error.Timeout, sig.waitTimeout(.{ .duration = .fromMilliseconds(100) }));
}

test "Signal: one delivery wins a select once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const select = @import("select.zig").select;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var sig = try Signal.init(.user1);
    defer sig.deinit();
    var other = try Signal.init(.user2);
    defer other.deinit();

    try posix.raise(@backingInt(SignalKind.user1));
    switch (try select(.{ .sig = &sig, .other = &other })) {
        .sig => {},
        .other => return error.TestUnexpectedResult,
    }

    const Second = struct {
        fn run(s: *Signal, o: *Signal) !void {
            _ = try select(.{ .sig = s, .other = o });
            return error.TestUnexpectedResult;
        }
    };
    var second = try rt.spawn(Second.run, .{ &sig, &other });
    defer second.cancel();
    try rt.sleep(.fromMilliseconds(100));
    second.cancel();
    try std.testing.expectError(error.Canceled, second.join());
}
