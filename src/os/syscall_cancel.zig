// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Cooperative cancellation of blocking syscalls running on thread-pool workers.
//!
//! A blocking syscall (e.g. `getrandom`) executes on a pool worker. To cancel it,
//! another thread sends `SIGURG` to the worker, interrupting the syscall with
//! `EINTR`. A no-op handler is installed *without* `SA_RESTART`, so the syscall
//! returns instead of being restarted; the syscall site then checks its token and
//! returns `error.Canceled`.
//!
//! The token is owned by the task, not the worker thread: the worker binds it
//! (records `pthread_self()` + a threadlocal pointer) while running the task's
//! function and unbinds afterwards. Because cancellation targets the token rather
//! than "whatever thread is running", a stale signal can at worst land on a worker
//! now running a *different* task with a *different* token, where it yields a
//! harmless spurious `EINTR` that the syscall's retry loop swallows. No wrong
//! cancellation is possible.
//!
//! On Windows the canceller calls `CancelSynchronousIo` on the worker's thread
//! handle instead, which fails the blocked call with `ERROR_OPERATION_ABORTED`,
//! the Windows counterpart of `EINTR`. A stale cancel aborts whatever I/O the
//! worker is in at that moment, which retries just like on a stale signal. It
//! only interrupts I/O, not waits, so on Windows the futex waits that use
//! `Syscall.beginWait` are not interruptible. The thread handle is opened once
//! per worker by `bindThread`.
//!
//! On WASI and single-threaded builds this degrades to no-ops, and the thread
//! pool's queue-based cancellation is unaffected.

const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const thread = @import("thread.zig");
const time = @import("time.zig");
const Duration = @import("../time.zig").Duration;
const windows = @import("windows.zig");

/// Whether syscall cancellation is supported on this target.
pub const enabled = builtin.os.tag != .wasi and !builtin.single_threaded;

/// Whether cancellation interrupts syscalls with `SIGURG`, which breaks any
/// blocking syscall, waits included. Otherwise (Windows) only I/O is
/// interruptible.
pub const uses_signal = enabled and builtin.os.tag != .windows;

/// `error.Canceled` unifies structurally with `common.Cancelable` (Zig errors are
/// interned by name), so callers can mix the two freely.
pub const Cancelable = error{Canceled};

/// State machine for a single token. All transitions are a CAS on `Token.state`.
///
///   idle ──start()──▶ blocked ──finish()──▶ idle
///    │                   │
///  cancel()           cancel()
///    ▼                   ▼
/// canceled        blocked_canceling ──checkCancel()/finish()──▶ canceled
///
/// `canceled` is terminal for the run: `start()` on it returns `error.Canceled`,
/// so a function with several syscalls aborts at the next one.
pub const State = enum(u8) {
    /// Worker bound to this token, not currently inside a cancelable syscall.
    idle,
    /// Worker is inside a cancelable syscall.
    blocked,
    /// Cancel requested while blocked; the canceller resends `SIGURG` until the
    /// worker observes it (state leaves `blocked_canceling`).
    blocked_canceling,
    /// Cancel pending/acknowledged. Aborts the current and any future syscall.
    canceled,
};

/// Per-worker binding. Set by `Token.enter`, read by the syscall site.
threadlocal var current: ?*Token = null;

/// Windows: this thread's handle for `CancelSynchronousIo`, opened by
/// `bindThread`. `null` on a thread that was never bound, where tokens still
/// work but a blocked call runs to completion.
threadlocal var thread_handle: ?windows.HANDLE = null;

/// Prepare the calling thread to run cancelable syscalls. Call once when a
/// worker thread starts, paired with `unbindThread` before it exits. Only
/// Windows needs it, to open the thread handle `CancelSynchronousIo` takes.
pub fn bindThread() void {
    if (!enabled or uses_signal) return;
    std.debug.assert(thread_handle == null);
    var handle: windows.HANDLE = undefined;
    const process = windows.GetCurrentProcess();
    if (windows.DuplicateHandle(process, windows.GetCurrentThread(), process, &handle, windows.THREAD_TERMINATE, windows.FALSE, 0) != windows.FALSE) {
        thread_handle = handle;
    }
}

/// Release what `bindThread` opened. Call before the worker thread exits, after
/// its last `Token.exit`.
pub fn unbindThread() void {
    if (!enabled or uses_signal) return;
    if (thread_handle) |handle| _ = windows.CloseHandle(handle);
    thread_handle = null;
}

/// Task-owned cancellation token. Created by the code that submits the blocking
/// work (on the stack for `blockInPlace`, or as a field of `AnyBlockingTask`).
pub const Token = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// `pthread_self()` (or on Windows, the `bindThread` handle) of the bound
    /// worker; `null` when no worker is bound. Published before `state` can
    /// become `blocked`, so it is always valid when the canceller observes
    /// `blocked` via an acquiring CAS.
    handle: std.atomic.Value(?Handle) = .init(null),

    // When disabled the field is never accessed, but it still has to have a
    // defined in-memory layout: `std.atomic.Value` is an extern struct, and only
    // a *pointer* optional has a guaranteed layout (null pointer), so the
    // disabled placeholder must be a pointer type, not `void`/an integer.
    // (`std.c.pthread_t` and `HANDLE` are pointers, which is why the enabled
    // cases work.)
    const Handle = if (uses_signal) std.c.pthread_t else if (enabled) windows.HANDLE else *anyopaque;

    /// Bind the calling worker thread to this token. Call immediately before
    /// running the task's function.
    pub fn enter(self: *Token) void {
        if (!enabled) return;
        self.handle.store(if (uses_signal) std.c.pthread_self() else thread_handle, .monotonic);
        current = self;
    }

    /// Unbind the calling worker. Call immediately after the task's function
    /// returns. At this point `state` is never `blocked*` (the last syscall ran
    /// `finish()` before returning).
    pub fn exit(self: *Token) void {
        if (!enabled) return;
        current = null;
        self.handle.store(null, .monotonic);
    }

    /// Canceller side: request cancellation. Returns `true` if the worker is
    /// blocked in a syscall and therefore needs to be signaled (the caller must
    /// then drive `signal()` with backoff until it returns `false`).
    pub fn cancel(self: *Token) bool {
        if (!enabled) return false;
        var s = self.state.load(.monotonic);
        while (true) {
            const next: State = switch (s) {
                .idle => .canceled, // will surface at the next start()
                .blocked => .blocked_canceling, // needs a signal to break the syscall
                .blocked_canceling, .canceled => return false, // already requested
            };
            if (self.state.cmpxchgWeak(s, next, .acq_rel, .monotonic)) |actual| {
                s = actual;
                continue;
            }
            return next == .blocked_canceling;
        }
    }

    /// Canceller side: send `SIGURG` to the bound worker if it is still blocked in
    /// the canceled syscall. Returns `true` if a signal was sent (the signal can
    /// be lost in the gap between `start()` and the kernel entering the syscall,
    /// so the caller should call again after a short backoff), or `false` once the
    /// worker has observed the cancellation.
    pub fn signal(self: *Token) bool {
        if (!enabled) return false;
        // Only meaningful while the worker is blocked-and-canceling; any other
        // state means it already woke up (or never was blocked).
        if (self.state.load(.acquire) != .blocked_canceling) return false;
        const handle = self.handle.load(.monotonic) orelse return false;
        if (!uses_signal) {
            if (windows.CancelSynchronousIo(handle) != windows.FALSE) return false;
            // NOT_FOUND: the worker has not entered the call yet, so try again.
            return windows.GetLastError() == .NOT_FOUND;
        }
        _ = std.c.pthread_kill(handle, sig);
        return true;
    }

    /// True while the worker is blocked in the canceled syscall and has not yet
    /// acknowledged the cancellation — i.e. the `SIGURG` may still need
    /// re-sending. Used to decide whether a work belongs on the loop's
    /// cancel-resend list.
    pub fn isCanceling(self: *Token) bool {
        if (!enabled) return false;
        return self.state.load(.acquire) == .blocked_canceling;
    }
};

/// A scoped, cancelable syscall region. Obtained by `begin()`, closed by
/// `finish()` (idempotent, so it pairs with `defer`); on `EINTR` call
/// `checkCancel()` to decide between retry and `error.Canceled`. A `null` token
/// means "not on a cancelable worker" — every method is then a no-op and the
/// syscall runs uncancelably.
pub const Syscall = struct {
    token: ?*Token,

    /// Enter a cancelable syscall region: `idle → blocked`. Returns
    /// `error.Canceled` immediately if a cancel is already pending, so we never
    /// even enter the syscall.
    pub fn begin() Cancelable!Syscall {
        if (!enabled) return .{ .token = null };
        const tok = current orelse return .{ .token = null };
        var s = tok.state.load(.monotonic);
        while (true) {
            switch (s) {
                .idle => {
                    if (tok.state.cmpxchgWeak(.idle, .blocked, .release, .monotonic)) |actual| {
                        s = actual;
                        continue;
                    }
                    return .{ .token = tok };
                },
                .canceled => return error.Canceled,
                .blocked, .blocked_canceling => unreachable, // cancelable syscalls do not nest
            }
        }
    }

    /// Call when the syscall returns `EINTR` (`ERROR_OPERATION_ABORTED` on
    /// Windows). If this token was canceled, finish
    /// the region and return `error.Canceled`; otherwise the interrupt was
    /// spurious (or meant for another token) and the caller should retry.
    pub fn checkCancel(self: Syscall) Cancelable!void {
        const tok = self.token orelse return;
        var s = tok.state.load(.monotonic);
        while (true) {
            switch (s) {
                .blocked => return, // spurious; retry the syscall
                .blocked_canceling => {
                    if (tok.state.cmpxchgWeak(.blocked_canceling, .canceled, .acq_rel, .monotonic)) |actual| {
                        s = actual;
                        continue;
                    }
                    return error.Canceled;
                },
                .idle, .canceled => unreachable,
            }
        }
    }

    /// Like `begin`, for a blocking wait (a futex) rather than I/O. On Windows a
    /// wait cannot be interrupted, so this only reports a cancel that is already
    /// pending, and the wait runs uncancelable.
    pub fn beginWait() Cancelable!Syscall {
        if (uses_signal) return begin();
        try checkCanceled();
        return .{ .token = null };
    }

    /// Close the syscall region on success or any non-`EINTR` error:
    /// `blocked → idle`, or `blocked_canceling → canceled` (cancel still pending,
    /// surfaces at the next `start()`).
    ///
    /// Idempotent: closing an already-closed region (`idle`/`canceled`) is a
    /// no-op, so `finish()` is safe as a `defer` even when `checkCancel()` has
    /// already finalized the region on the `Canceled` path.
    pub fn finish(self: Syscall) void {
        const tok = self.token orelse return;
        var s = tok.state.load(.monotonic);
        while (true) {
            const next: State = switch (s) {
                .blocked => .idle,
                .blocked_canceling => .canceled,
                .idle, .canceled => return,
            };
            if (tok.state.cmpxchgWeak(s, next, .acq_rel, .monotonic)) |actual| {
                s = actual;
                continue;
            }
            return;
        }
    }
};

/// Check whether the current worker's bound task already has a cancellation
/// pending, without entering a cancelable syscall region. Returns
/// `error.Canceled` if so, otherwise a no-op.
///
/// Intended for blocking calls that a `SIGURG` cannot interrupt (e.g. glibc
/// `getaddrinfo`, which restarts internally). We can't break out of such a call
/// once it is running, but we can still honor a cancel that arrived while the
/// work sat in the pool queue by checking right before we start it.
pub fn checkCanceled() Cancelable!void {
    if (!enabled) return;
    const tok = current orelse return;
    // Outside a begin()/finish() region the state is only ever `idle` or
    // `canceled`, so a plain load is enough to decide.
    if (tok.state.load(.monotonic) == .canceled) return error.Canceled;
}

const sig = if (uses_signal) std.c.SIG.URG else {};

// A mutex serializes the entire (count-check + prev_action-read/write + sigaction)
// critical section so that concurrent install/uninstall calls cannot corrupt
// prev_action or double-install/uninstall the handler.
var install_mutex: thread.Mutex = .init();
var install_count: usize = 0;
var prev_action: posix.Sigaction = undefined;

/// Install the process-global no-op `SIGURG` handler (refcounted; safe to call
/// from each thread pool). The handler does nothing — its only job is to make
/// blocking syscalls return `EINTR`, which requires the handler to be installed
/// *without* `SA_RESTART`.
pub fn installHandler() void {
    if (!uses_signal) return;
    install_mutex.lock();
    defer install_mutex.unlock();
    if (install_count != 0) {
        install_count += 1;
        return;
    }
    var act: posix.Sigaction = .{
        .handler = .{ .handler = noopHandler },
        .mask = posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: interrupted syscalls must return EINTR
    };
    posix.sigaction(posix.SIG.URG, &act, &prev_action);
    install_count = 1;
}

/// Restore the previous `SIGURG` disposition once the last user uninstalls.
pub fn uninstallHandler() void {
    if (!uses_signal) return;
    install_mutex.lock();
    defer install_mutex.unlock();
    std.debug.assert(install_count > 0);
    install_count -= 1;
    if (install_count != 0) return;
    posix.sigaction(posix.SIG.URG, &prev_action, null);
}

fn noopHandler(_: posix.SIG) callconv(.c) void {}

test "syscall_cancel: signal interrupts a blocking read" {
    if (!uses_signal) return;

    // End-to-end: a worker thread blocks in a real syscall (read on an empty
    // pipe), and another thread cancels it via the token. The read must return
    // EINTR, checkCancel must report Canceled, and the worker must unblock.
    installHandler();
    defer uninstallHandler();

    var token: Token = .{};

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const Worker = struct {
        token: *Token,
        read_fd: std.c.fd_t,
        result: anyerror!void = undefined,
        ready: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.token.enter();
            defer self.token.exit();

            self.result = blk: {
                const sc = Syscall.begin() catch |e| break :blk e;
                defer sc.finish();
                // Signal that we are inside the cancelable region, just before read().
                self.ready.store(true, .release);
                var buf: [1]u8 = undefined;
                while (true) {
                    const rc = std.c.read(self.read_fd, &buf, buf.len);
                    if (rc >= 0) break :blk error.UnexpectedData;
                    switch (std.posix.errno(rc)) {
                        .INTR => {
                            sc.checkCancel() catch |e| break :blk e;
                            continue;
                        },
                        else => |e| break :blk std.posix.unexpectedErrno(e),
                    }
                }
            };
        }
    };

    var w: Worker = .{ .token = &token, .read_fd = fds[0] };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&w});

    // Wait until the worker has entered the cancelable region (after begin() but
    // before read()), then cancel. The first signal may land in the tiny
    // begin()→read() gap, so drive the resend loop until the worker acks.
    while (!w.ready.load(.acquire)) time.sleep(Duration.fromMicroseconds(1));
    if (token.cancel()) {
        while (token.signal()) time.sleep(Duration.fromMilliseconds(1));
    }

    t.join();
    try std.testing.expectError(error.Canceled, w.result);
}

test "syscall_cancel: CancelSynchronousIo interrupts a blocking pipe read" {
    if (!enabled or uses_signal) return;

    // An anonymous pipe from CreatePipe is synchronous, like an inherited stdin,
    // so ReadFile on its empty read end blocks the worker until canceled.
    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    if (windows.CreatePipe(&read_end, &write_end, null, 0) == windows.FALSE) return error.Unexpected;
    defer _ = windows.CloseHandle(read_end);
    defer _ = windows.CloseHandle(write_end);

    var token: Token = .{};

    const Worker = struct {
        token: *Token,
        read_end: windows.HANDLE,
        result: anyerror!void = undefined,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            bindThread();
            defer unbindThread();
            self.token.enter();
            defer self.token.exit();
            defer self.done.store(true, .release);

            self.result = blk: {
                const sc = Syscall.begin() catch |e| break :blk e;
                defer sc.finish();
                var buf: [1]u8 = undefined;
                var n: windows.DWORD = undefined;
                while (true) {
                    if (windows.ReadFile(self.read_end, &buf, buf.len, &n, null) != windows.FALSE) break :blk error.UnexpectedData;
                    switch (windows.GetLastError()) {
                        .OPERATION_ABORTED => {
                            sc.checkCancel() catch |e| break :blk e;
                            continue;
                        },
                        else => break :blk error.Unexpected,
                    }
                }
            };
        }
    };

    var w: Worker = .{ .token = &token, .read_end = read_end };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&w});

    while (token.state.load(.acquire) != .blocked) time.sleep(Duration.fromMicroseconds(1));

    // Resend until the worker finishes. If the cancel never lands, unblock the
    // read with data after 5s, so the test fails instead of hanging.
    _ = token.cancel();
    var waited: usize = 0;
    while (!w.done.load(.acquire)) : (waited += 1) {
        if (waited == 5000) {
            var n: windows.DWORD = undefined;
            _ = windows.WriteFile(write_end, "x", 1, &n, null);
            break;
        }
        _ = token.signal();
        time.sleep(Duration.fromMilliseconds(1));
    }

    t.join();
    try std.testing.expectError(error.Canceled, w.result);
}
