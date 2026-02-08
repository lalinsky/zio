// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level thread wait primitives for blocking contexts.
//!
//! This module provides futex-like wait/wake operations for synchronizing
//! threads in blocking (non-async) contexts.

const std = @import("std");
const builtin = @import("builtin");

const Duration = @import("../time.zig").Duration;
const Timeout = @import("../time.zig").Timeout;
const WaitNode = @import("../runtime/WaitNode.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;

const sys = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .freebsd => @import("freebsd.zig"),
    .openbsd => @import("openbsd.zig"),
    .netbsd => @import("netbsd.zig"),
    .dragonfly => @import("dragonfly.zig"),
    else => |t| if (t.isDarwin()) @import("darwin.zig") else @compileError("Unsupported OS: " ++ @tagName(t)),
};

/// Number of waiters to wake
pub const WakeCount = enum {
    /// Wake one waiter
    one,
    /// Wake all waiters
    all,
};

/// Low-level futex operations for thread synchronization.
///
/// Provides platform-specific wait/wake primitives that operate on atomic values.
/// This is an internal implementation detail - use the `Notify` type instead.
///
/// Methods:
/// - `wait(ptr, current)`: Block indefinitely if *ptr == current
/// - `timedWait(ptr, current, timeout)`: Block with timeout if *ptr == current, returns error.Timeout
/// - `wake(ptr, count)`: Wake waiting threads (one or all)
///
/// The implementation is selected at compile time based on the target OS.
const Futex = switch (builtin.os.tag) {
    .linux => FutexLinux,
    .windows => FutexWindows,
    .freebsd => FutexFreeBSD,
    .openbsd => FutexOpenBSD,
    .dragonfly => FutexDragonFly,
    else => |t| if (t.isDarwin()) FutexDarwin else void,
};

/// Thread notification primitive.
///
/// A higher-level abstraction over platform wait primitives that owns its state.
/// Use this instead of raw wait/wake functions when you need to own the state.
///
/// **Important**: Only one thread should wait on this at a time.
/// For multi-waiter scenarios, use the raw wait/wake functions instead.
///
/// Example usage:
/// ```zig
/// var notify: Notify = .init();
///
/// // Waiting thread
/// notify.wait(1); // Wait indefinitely
/// // or
/// notify.timedWait(1, .fromSeconds(1)) catch |err| {
///     // Handle timeout
/// };
///
/// // Signaling thread
/// notify.signal();
/// ```
pub const Notify = switch (builtin.os.tag) {
    .netbsd => NotifyNetBSD,
    else => NotifyFutex,
};

/// Mutex for thread synchronization.
///
/// A blocking mutex that uses platform-specific optimal primitives:
/// - Windows: SRWLOCK (Slim Reader/Writer Lock)
/// - Darwin/macOS: os_unfair_lock
/// - NetBSD: Waiter-based with WaitQueue
/// - Other platforms: futex-based implementation
///
/// Example usage:
/// ```zig
/// var mutex: Mutex = .init();
/// defer mutex.deinit();
///
/// mutex.lock();
/// defer mutex.unlock();
/// // critical section
/// ```
pub const Mutex = switch (builtin.os.tag) {
    .windows => MutexWindows,
    .freebsd => MutexFreeBSD,
    .netbsd => MutexEvent,
    else => |t| if (t.isDarwin()) MutexDarwin else MutexFutex,
};

/// Condition variable for thread synchronization.
///
/// A blocking condition variable that uses platform-specific primitives:
/// - Windows: CONDITION_VARIABLE
/// - Other platforms: Waiter-based with WaitQueue
///
/// Condition variables allow threads to wait for certain conditions to become true
/// while cooperating with other threads. They are always used in conjunction with
/// a Mutex to protect the shared state being checked.
///
/// Example usage:
/// ```zig
/// var mutex: Mutex = .init();
/// var cond: Condition = .init();
/// var ready = false;
///
/// // Waiter thread
/// mutex.lock();
/// while (!ready) {
///     cond.wait(&mutex);
/// }
/// mutex.unlock();
///
/// // Signaler thread
/// mutex.lock();
/// ready = true;
/// mutex.unlock();
/// cond.signal();
/// ```
pub const Condition = switch (builtin.os.tag) {
    .windows => ConditionWindows,
    .freebsd => ConditionFreeBSD,
    else => if (Futex == void) ConditionNotify else ConditionFutex,
};

/// ResetEvent is a thread-safe bool which can be set to true/false.
/// Threads can block until the event is set.
pub const ResetEvent = struct {
    mutex: Mutex,
    cond: Condition,
    is_set: bool,

    pub fn init() ResetEvent {
        return .{
            .mutex = Mutex.init(),
            .cond = Condition.init(),
            .is_set = false,
        };
    }

    pub fn deinit(self: *ResetEvent) void {
        self.mutex.deinit();
        self.cond.deinit();
    }

    pub fn isSet(self: *ResetEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_set;
    }

    pub fn wait(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.is_set) {
            self.cond.wait(&self.mutex);
        }
    }

    pub fn set(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_set = true;
        self.cond.broadcast();
    }

    pub fn reset(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_set = false;
    }
};

const FutexLinux = struct {
    const linux = std.os.linux;

    fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const rc = sys.futex(
                &ptr.raw,
                sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
                expected,
                null,
                null,
                0,
            );
            switch (linux.E.init(rc)) {
                .TIMEDOUT => unreachable,
                .INTR => continue,
                else => return,
            }
        }
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout: Duration) error{Timeout}!void {
        const timeout_ts = timeout.toTimespec();

        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const rc = sys.futex(
                &ptr.raw,
                sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
                expected,
                &timeout_ts,
                null,
                0,
            );
            switch (linux.E.init(rc)) {
                .TIMEDOUT => return error.Timeout,
                .INTR => continue,
                else => return,
            }
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(i32),
        };
        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAKE | sys.FUTEX_PRIVATE_FLAG,
            n,
            null,
            null,
            0,
        );
    }
};

// ============================================================================
// Windows implementation
// ============================================================================

const FutexWindows = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32) void {
        // RtlWaitOnAddress atomically checks if *ptr == current before sleeping
        _ = sys.RtlWaitOnAddress(
            &ptr.raw,
            &current,
            @sizeOf(u32),
            null,
        );
        // Return value doesn't matter - we handle spurious wakeups in the caller's loop
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), current: u32, timeout: Duration) error{Timeout}!void {
        // RtlWaitOnAddress takes timeout in 100ns units (negative = relative)
        const ns = timeout.toNanoseconds();
        const units_100ns = ns / 100;
        const i64_val = std.math.cast(i64, units_100ns) orelse std.math.maxInt(i64);
        var timeout_li: sys.LARGE_INTEGER = -i64_val; // Negative means relative timeout

        // RtlWaitOnAddress atomically checks if *ptr == current before sleeping
        const rc = sys.RtlWaitOnAddress(
            &ptr.raw,
            &current,
            @sizeOf(u32),
            &timeout_li,
        );

        if (rc == .TIMEOUT) {
            return error.Timeout;
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        switch (count) {
            .one => sys.RtlWakeAddressSingle(&ptr.raw),
            .all => sys.RtlWakeAddressAll(&ptr.raw),
        }
    }
};

// ============================================================================
// macOS/Darwin implementation
// ============================================================================

const FutexDarwin = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
        _ = sys.__ulock_wait(
            sys.UL_COMPARE_AND_WAIT | sys.ULF_NO_ERRNO,
            &ptr.raw,
            expected,
            0, // 0 means infinite wait
        );
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout: Duration) error{Timeout}!void {
        const us = timeout.toMicroseconds();
        const timeout_us: u32 = @max(1, std.math.cast(u32, us) orelse std.math.maxInt(u32));

        const rc = sys.__ulock_wait(
            sys.UL_COMPARE_AND_WAIT | sys.ULF_NO_ERRNO,
            &ptr.raw,
            expected,
            timeout_us,
        );

        if (rc < 0) {
            const err: std.posix.E = @enumFromInt(-rc);
            if (err == .TIMEDOUT) return error.Timeout;
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const flags: u32 = switch (count) {
            .one => sys.UL_COMPARE_AND_WAIT | sys.ULF_NO_ERRNO,
            .all => sys.UL_COMPARE_AND_WAIT | sys.ULF_NO_ERRNO | sys.ULF_WAKE_ALL,
        };
        _ = sys.__ulock_wake(flags, &ptr.raw, 0);
    }
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FutexFreeBSD = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const rc = sys._umtx_op(
                &ptr.raw,
                sys.UMTX_OP_WAIT_UINT_PRIVATE,
                expected,
                null,
                null,
            );
            if (rc == -1) {
                const err = std.posix.errno(rc);
                if (err == .INTR) continue;
            }
            return;
        }
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout: Duration) error{Timeout}!void {
        const timeout_ts = timeout.toTimespec();

        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const result = sys._umtx_op(
                &ptr.raw,
                sys.UMTX_OP_WAIT_UINT_PRIVATE,
                expected,
                null,
                @ptrCast(@constCast(&timeout_ts)),
            );

            if (result == -1) {
                const err = std.posix.errno(result);
                switch (err) {
                    .TIMEDOUT => return error.Timeout,
                    .INTR => continue,
                    else => return,
                }
            }
            return;
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_ulong = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = sys._umtx_op(
            &ptr.raw,
            sys.UMTX_OP_WAKE_PRIVATE,
            n,
            null,
            null,
        );
    }
};

/// FreeBSD umutex-based mutex.
///
/// Uses FreeBSD's native UMTX_OP_MUTEX_* operations which provide
/// kernel-assisted locking with automatic priority inheritance support.
const MutexFreeBSD = struct {
    mutex: sys.umutex = .{
        .m_owner = sys.UMUTEX_UNOWNED,
        .m_flags = 0,
        .m_ceilings = .{ 0, 0 },
        .m_rb_lnk = 0,
        .m_spare = .{ 0, 0 },
    },

    pub fn init() MutexFreeBSD {
        return .{};
    }

    pub fn deinit(self: *MutexFreeBSD) void {
        _ = self;
    }

    pub fn lock(self: *MutexFreeBSD) void {
        // UMTX_OP_MUTEX_LOCK blocks until the mutex is acquired
        _ = sys._umtx_op(&self.mutex, sys.UMTX_OP_MUTEX_LOCK, 0, null, null);
    }

    pub fn unlock(self: *MutexFreeBSD) void {
        // UMTX_OP_MUTEX_UNLOCK releases the mutex and wakes one waiter if any
        _ = sys._umtx_op(&self.mutex, sys.UMTX_OP_MUTEX_UNLOCK, 0, null, null);
    }

    pub fn tryLock(self: *MutexFreeBSD) bool {
        // UMTX_OP_MUTEX_TRYLOCK returns 0 on success, EBUSY if already locked
        const result = sys._umtx_op(&self.mutex, sys.UMTX_OP_MUTEX_TRYLOCK, 0, null, null);
        return result == 0;
    }
};

/// FreeBSD ucond-based condition variable.
///
/// Uses FreeBSD's native UMTX_OP_CV_* operations which provide
/// kernel-assisted condition variables with automatic signal-before-wait race handling.
const ConditionFreeBSD = struct {
    cond: sys.ucond = .{
        .c_has_waiters = 0,
        .c_flags = 0,
        .c_clockid = 0,
        .c_spare = .{0},
    },

    pub fn init() ConditionFreeBSD {
        return .{};
    }

    pub fn deinit(self: *ConditionFreeBSD) void {
        _ = self;
    }

    /// Wait for a signal. The mutex must be held when calling this.
    /// The mutex is atomically released and the thread blocks.
    /// When signaled, the mutex is automatically reacquired before returning.
    pub fn wait(self: *ConditionFreeBSD, mutex: *Mutex) void {
        // UMTX_OP_CV_WAIT atomically releases the mutex and waits
        // The kernel ensures no signal is lost between unlock and wait
        _ = sys._umtx_op(&self.cond, sys.UMTX_OP_CV_WAIT, 0, &mutex.mutex, null);
    }

    /// Wait for a signal with a timeout.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *ConditionFreeBSD, mutex: *Mutex, timeout: Timeout) error{Timeout}!void {
        if (timeout == .none) {
            return self.wait(mutex);
        }

        const deadline = timeout.toDeadline();
        const remaining = deadline.durationFromNow();
        if (remaining.value <= 0) {
            return error.Timeout;
        }

        const timeout_ts = remaining.toTimespec();

        // UMTX_OP_CV_WAIT with relative timeout (no CVWAIT_ABSTIME flag)
        const result = sys._umtx_op(
            &self.cond,
            sys.UMTX_OP_CV_WAIT,
            0, // No flags = relative timeout
            &mutex.mutex,
            @ptrCast(@constCast(&timeout_ts)),
        );

        // Check if we timed out
        if (result == -1 and std.posix.errno(result) == .TIMEDOUT) {
            return error.Timeout;
        }
    }

    /// Wake one waiting thread.
    pub fn signal(self: *ConditionFreeBSD) void {
        _ = sys._umtx_op(&self.cond, sys.UMTX_OP_CV_SIGNAL, 0, null, null);
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *ConditionFreeBSD) void {
        _ = sys._umtx_op(&self.cond, sys.UMTX_OP_CV_BROADCAST, 0, null, null);
    }
};

// ============================================================================
// OpenBSD implementation
// ============================================================================

const FutexOpenBSD = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const rc = sys.futex(
                &ptr.raw,
                sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
                @intCast(expected),
                null,
                null,
            );
            if (rc == -1) {
                const err = std.posix.errno(rc);
                if (err == .INTR) continue;
            }
            return;
        }
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout: Duration) error{Timeout}!void {
        const timeout_ts = timeout.toTimespec();

        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const result = sys.futex(
                &ptr.raw,
                sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
                @intCast(expected),
                &timeout_ts,
                null,
            );

            if (result == -1) {
                const err = std.posix.errno(result);
                switch (err) {
                    .TIMEDOUT => return error.Timeout,
                    .INTR => continue,
                    else => return,
                }
            }
            return;
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAKE | sys.FUTEX_PRIVATE_FLAG,
            n,
            null,
            null,
        );
    }
};

// ============================================================================
// DragonFly BSD implementation
// ============================================================================

const FutexDragonFly = struct {
    fn wait(ptr: *const std.atomic.Value(u32), expected: u32) void {
        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const rc = sys.umtx_sleep(
                &ptr.raw,
                @intCast(expected),
                0, // 0 means infinite wait
            );
            if (rc == -1) {
                const err = std.posix.errno(rc);
                if (err == .INTR) continue;
            }
            return;
        }
    }

    fn timedWait(ptr: *const std.atomic.Value(u32), expected: u32, timeout: Duration) error{Timeout}!void {
        const us = timeout.toMicroseconds();
        const timeout_us: c_int = @max(1, std.math.cast(c_int, us) orelse std.math.maxInt(c_int));

        while (true) {
            if (ptr.load(.monotonic) != expected) return;

            const result = sys.umtx_sleep(
                &ptr.raw,
                @intCast(expected),
                timeout_us,
            );

            if (result == -1) {
                const err = std.posix.errno(result);
                switch (err) {
                    .TIMEDOUT, .WOULDBLOCK => return error.Timeout,
                    .INTR => continue,
                    else => return,
                }
            }
            return;
        }
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: c_int = switch (count) {
            .one => 1,
            .all => std.math.maxInt(c_int),
        };
        _ = sys.umtx_wakeup(&ptr.raw, n);
    }
};

// ============================================================================
// Waiter implementations
// ============================================================================

/// Futex-based notify for platforms with futex-like primitives
const NotifyFutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn init() NotifyFutex {
        return .{};
    }

    pub fn wait(self: *NotifyFutex, current: u32) void {
        Futex.wait(&self.state, current);
    }

    pub fn timedWait(self: *NotifyFutex, current: u32, timeout: Duration) error{Timeout}!void {
        return Futex.timedWait(&self.state, current, timeout);
    }

    pub fn signal(self: *NotifyFutex) void {
        _ = self.state.fetchAdd(1, .release);
        Futex.wake(&self.state, .one);
    }
};

/// NetBSD notify using native _lwp_park/_lwp_unpark
///
/// Implementation note: _lwp_park/_lwp_unpark handles signal-before-wait races safely.
/// If _lwp_unpark() is called before the LWP calls _lwp_park(), the kernel sets the
/// LW_UNPARKED flag on the target LWP. When that LWP later calls _lwp_park(), it
/// immediately returns EALREADY without blocking. This means signal() can be called
/// before wait() without losing the wakeup.
///
/// The lwp_id is captured at init() time, so this Notify must be created on the same
/// thread that will call wait(). Other threads can safely call signal().
const NotifyNetBSD = struct {
    state: std.atomic.Value(u32) = .init(0),
    lwp_id: c_int,

    pub fn init() NotifyNetBSD {
        return .{
            .lwp_id = sys._lwp_self(),
        };
    }

    pub fn wait(self: *NotifyNetBSD, current: u32) void {
        _ = self;
        _ = current; // Caller checks state, we just park

        // Safe to call even if signal() was already called - the kernel remembers
        // the unpark and will return EALREADY immediately without blocking.
        _ = sys.___lwp_park60(
            @intFromEnum(std.posix.CLOCK.MONOTONIC),
            0,
            null,
            0, // unpark: don't unpark anyone
            null, // hint
            null, // unparkhint
        );
    }

    pub fn timedWait(self: *NotifyNetBSD, current: u32, timeout: Duration) error{Timeout}!void {
        _ = self;
        _ = current; // Caller checks state, we just park

        const timeout_ts = timeout.toTimespec();

        // Safe to call even if signal() was already called - the kernel remembers
        // the unpark and will return EALREADY immediately without blocking.
        const result = sys.___lwp_park60(
            @intFromEnum(std.posix.CLOCK.MONOTONIC),
            0,
            &timeout_ts,
            0, // unpark: don't unpark anyone
            null, // hint
            null, // unparkhint
        );

        if (result == -1) {
            const err = std.posix.errno(result);
            if (err == .TIMEDOUT) {
                return error.Timeout;
            }
        }
    }

    pub fn signal(self: *NotifyNetBSD) void {
        _ = self.state.fetchAdd(1, .release);
        // Safe to call before wait() - sets LW_UNPARKED flag that park() will check
        _ = sys._lwp_unpark(self.lwp_id, null);
    }
};

// ============================================================================
// Mutex implementations
// ============================================================================

/// Futex-based mutex for platforms with futex-like primitives.
///
/// Uses a three-state model:
/// - 0b00 (0): unlocked
/// - 0b01 (1): locked, no waiters
/// - 0b11 (3): locked, with waiters
///
/// The contended state uses 0b11 instead of 0b10 to keep bit 0 set when locked.
/// This enables x86 optimization using `lock bts` instead of `lock cmpxchg` for tryLock.
///
/// This minimizes futex syscalls in the uncontended case.
const MutexFutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    const UNLOCKED: u32 = 0b00;
    const LOCKED: u32 = 0b01;
    const LOCKED_WITH_WAITERS: u32 = 0b11; // must contain the `locked` bit for x86 optimization

    pub fn init() MutexFutex {
        return .{};
    }

    pub fn deinit(self: *MutexFutex) void {
        _ = self;
    }

    pub fn lock(self: *MutexFutex) void {
        // Fast path: try to acquire unlocked mutex
        if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
            return;
        }

        // Slow path: mutex is contended
        self.lockSlow();
    }

    fn lockSlow(self: *MutexFutex) void {
        // First try spinning a bit
        var spin: u32 = 0;
        while (spin < 100) : (spin += 1) {
            const state = self.state.load(.monotonic);
            if (state == UNLOCKED) {
                if (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }

        // Avoid doing an atomic swap below if we already know the state is contended.
        // An atomic swap unconditionally stores which marks the cache-line as modified unnecessarily.
        if (self.state.load(.monotonic) == LOCKED_WITH_WAITERS) {
            Futex.wait(&self.state, LOCKED_WITH_WAITERS);
        }

        // Try to acquire the lock while also telling the existing lock holder that there are threads waiting.
        //
        // Once we sleep on the Futex, we must acquire the mutex using `LOCKED_WITH_WAITERS` rather than `LOCKED`.
        // If not, threads sleeping on the Futex wouldn't see the state change in unlock and potentially deadlock.
        // The downside is that the last mutex unlocker will see `LOCKED_WITH_WAITERS` and do an unnecessary Futex wake
        // but this is better than having to wake all waiting threads on mutex unlock.
        //
        // Acquire barrier ensures grabbing the lock happens before the critical section
        // and that the previous lock holder's critical section happens before we grab the lock.
        while (self.state.swap(LOCKED_WITH_WAITERS, .acquire) != UNLOCKED) {
            Futex.wait(&self.state, LOCKED_WITH_WAITERS);
        }
    }

    pub fn unlock(self: *MutexFutex) void {
        // Unlock the mutex and wake up a waiting thread if any.
        //
        // A waiting thread will acquire with `LOCKED_WITH_WAITERS` instead of `LOCKED`
        // which ensures that it wakes up another thread on the next unlock().
        //
        // Release barrier ensures the critical section happens before we let go of the lock
        // and that our critical section happens before the next lock holder grabs the lock.
        const state = self.state.swap(UNLOCKED, .release);
        std.debug.assert(state != UNLOCKED);

        if (state == LOCKED_WITH_WAITERS) {
            Futex.wake(&self.state, .one);
        }
    }

    pub fn tryLock(self: *MutexFutex) bool {
        // On x86, use `lock bts` instead of `lock cmpxchg` as:
        // - they both seem to mark the cache-line as modified regardless: https://stackoverflow.com/a/63350048
        // - `lock bts` is smaller instruction-wise which makes it better for inlining
        if (builtin.target.cpu.arch.isX86()) {
            const locked_bit = @ctz(LOCKED);
            return self.state.bitSet(locked_bit, .acquire) == 0;
        }

        // Acquire barrier ensures grabbing the lock happens before the critical section
        // and that the previous lock holder's critical section happens before we grab the lock.
        return self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

/// Windows SRWLOCK-based mutex (Vista+).
///
/// SRWLOCK (Slim Reader/Writer Lock) is highly optimized for exclusive access.
/// It's a pointer-sized lock that uses efficient kernel wait mechanisms when contended.
const MutexWindows = struct {
    srwlock: sys.SRWLOCK = sys.SRWLOCK_INIT,

    pub fn init() MutexWindows {
        return .{};
    }

    pub fn deinit(self: *MutexWindows) void {
        _ = self;
        // SRWLOCK doesn't require cleanup
    }

    pub fn lock(self: *MutexWindows) void {
        sys.AcquireSRWLockExclusive(&self.srwlock);
    }

    pub fn unlock(self: *MutexWindows) void {
        sys.ReleaseSRWLockExclusive(&self.srwlock);
    }

    pub fn tryLock(self: *MutexWindows) bool {
        return sys.TryAcquireSRWLockExclusive(&self.srwlock) != 0;
    }
};

/// Darwin/macOS os_unfair_lock-based mutex (10.12+, iOS 10.0+).
///
/// os_unfair_lock is Apple's recommended low-level lock primitive.
/// It's highly optimized, only 32 bits in size, and uses efficient kernel waits when contended.
/// Unlike OSSpinLock (deprecated), it doesn't suffer from priority inversion issues.
const MutexDarwin = struct {
    unfair_lock: sys.os_unfair_lock_s = sys.OS_UNFAIR_LOCK_INIT,

    pub fn init() MutexDarwin {
        return .{};
    }

    pub fn deinit(self: *MutexDarwin) void {
        _ = self;
        // os_unfair_lock doesn't require cleanup
    }

    pub fn lock(self: *MutexDarwin) void {
        sys.os_unfair_lock_lock(&self.unfair_lock);
    }

    pub fn unlock(self: *MutexDarwin) void {
        sys.os_unfair_lock_unlock(&self.unfair_lock);
    }

    pub fn tryLock(self: *MutexDarwin) bool {
        return sys.os_unfair_lock_trylock(&self.unfair_lock);
    }
};

/// Notify-based mutex using WaitQueue.
///
/// Uses the same pattern as zio.Mutex but for blocking OS threads:
/// - Queue state encodes lock status with sentinels
/// - Stack-allocated waiters block on Notify instead of suspending coroutines
/// - FIFO ordering ensures fairness
const MutexEvent = struct {
    /// Stack-allocated waiter that blocks an OS thread
    const Waiter = struct {
        wait_node: WaitNode,
        notify: Notify,

        fn init() Waiter {
            return .{
                .wait_node = .{ .vtable = &.{} },
                .notify = Notify.init(),
            };
        }
    };

    queue: WaitQueue(WaitNode) = .initWithState(.sentinel1),

    const State = WaitQueue(WaitNode).State;
    const locked_once: State = .sentinel0;
    const unlocked: State = .sentinel1;

    pub fn init() MutexEvent {
        return .{};
    }

    pub fn deinit(self: *MutexEvent) void {
        _ = self;
    }

    pub fn tryLock(self: *MutexEvent) bool {
        return self.queue.tryTransition(unlocked, locked_once);
    }

    pub fn lock(self: *MutexEvent) void {
        // Fast path: try to acquire unlocked mutex
        if (self.queue.tryTransition(unlocked, locked_once)) {
            return;
        }

        // Slow path: add to FIFO wait queue
        var waiter = Waiter.init();

        // Try to push to queue, or if mutex is unlocked, acquire it atomically
        const result = self.queue.pushOrTransition(unlocked, locked_once, &waiter.wait_node);
        if (result == .transitioned) {
            // Mutex was unlocked, we acquired it via transition to locked_once
            return;
        }

        // Wait for lock - block on event, handling spurious wakeups
        while (waiter.notify.state.load(.acquire) == 0) {
            waiter.notify.wait(0);
        }

        // Acquire fence: synchronize-with unlock()'s .release in pop()
        _ = self.queue.getState();
    }

    pub fn unlock(self: *MutexEvent) void {
        // Pop one waiter or transition from locked_once to unlocked
        // Last waiter stays in locked_once (inherits the lock)
        if (self.queue.popOrTransition(locked_once, unlocked, locked_once)) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.notify.signal();
        }
    }
};

/// Windows CONDITION_VARIABLE-based condition variable (Vista+).
const ConditionWindows = struct {
    cond: sys.CONDITION_VARIABLE = sys.CONDITION_VARIABLE_INIT,

    pub fn init() ConditionWindows {
        return .{};
    }

    pub fn deinit(self: *ConditionWindows) void {
        _ = self;
        // CONDITION_VARIABLE doesn't require cleanup
    }

    /// Wait for a signal. The mutex must be held when calling this.
    /// The mutex is atomically released and the thread blocks.
    /// When signaled, the mutex is automatically reacquired before returning.
    pub fn wait(self: *ConditionWindows, mutex: *Mutex) void {
        const result = sys.SleepConditionVariableSRW(&self.cond, &mutex.srwlock, sys.INFINITE, 0);
        std.debug.assert(result != sys.FALSE);
    }

    /// Wait for a signal with a timeout.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *ConditionWindows, mutex: *Mutex, timeout: Timeout) error{Timeout}!void {
        if (timeout == .none) {
            return self.wait(mutex);
        }

        const duration = timeout.durationFromNow();
        const ms = @min(duration.toMilliseconds(), std.math.maxInt(sys.DWORD));
        const result = sys.SleepConditionVariableSRW(&self.cond, &mutex.srwlock, @intCast(ms), 0);
        if (result == sys.FALSE) {
            const err = std.os.windows.kernel32.GetLastError();
            if (err == .TIMEOUT) {
                return error.Timeout;
            }
            std.debug.panic("SleepConditionVariableSRW failed with error {}", .{err});
        }
    }

    /// Wake one waiting thread.
    pub fn signal(self: *ConditionWindows) void {
        sys.WakeConditionVariable(&self.cond);
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *ConditionWindows) void {
        sys.WakeAllConditionVariable(&self.cond);
    }
};

/// Futex-based condition variable using a sequence counter.
///
/// Uses a single atomic counter instead of a WaitQueue:
/// - signal() increments the counter and wakes one futex waiter
/// - broadcast() increments the counter and wakes all futex waiters
/// - wait() captures the current sequence, unlocks the mutex, then blocks
///   on the futex until the sequence changes
const ConditionFutex = struct {
    seq: std.atomic.Value(u32) = .init(0),

    pub fn init() ConditionFutex {
        return .{};
    }

    pub fn deinit(self: *ConditionFutex) void {
        _ = self;
    }

    pub fn wait(self: *ConditionFutex, mutex: *Mutex) void {
        const seq = self.seq.load(.monotonic);
        mutex.unlock();
        defer mutex.lock();

        Futex.wait(&self.seq, seq);
    }

    pub fn timedWait(self: *ConditionFutex, mutex: *Mutex, timeout: Timeout) error{Timeout}!void {
        if (timeout == .none) {
            return self.wait(mutex);
        }

        const seq = self.seq.load(.monotonic);
        mutex.unlock();
        defer mutex.lock();

        const remaining = timeout.durationFromNow();
        if (remaining.value <= 0) return error.Timeout;

        try Futex.timedWait(&self.seq, seq, remaining);
    }

    pub fn signal(self: *ConditionFutex) void {
        _ = self.seq.fetchAdd(1, .monotonic);
        Futex.wake(&self.seq, .one);
    }

    pub fn broadcast(self: *ConditionFutex) void {
        _ = self.seq.fetchAdd(1, .monotonic);
        Futex.wake(&self.seq, .all);
    }
};

/// Notify-based condition variable using WaitQueue.
///
/// Uses the same pattern as zio.Condition but for blocking OS threads:
/// - WaitQueue manages the list of waiting threads
/// - Stack-allocated waiters block on Notify instead of suspending coroutines
/// - Works with any Mutex type
const ConditionNotify = struct {
    /// Stack-allocated waiter that blocks an OS thread
    const Waiter = struct {
        wait_node: WaitNode,
        notify: Notify,

        fn init() Waiter {
            return .{
                .wait_node = .{ .vtable = &.{} },
                .notify = Notify.init(),
            };
        }
    };

    wait_queue: WaitQueue(WaitNode) = .empty,

    pub fn init() ConditionNotify {
        return .{};
    }

    pub fn deinit(self: *ConditionNotify) void {
        _ = self;
    }

    /// Wait for a signal. The mutex must be held when calling this.
    /// The mutex is atomically released and the thread blocks.
    /// When signaled, the mutex is automatically reacquired before returning.
    pub fn wait(self: *ConditionNotify, mutex: *Mutex) void {
        var waiter = Waiter.init();

        // Add to wait queue before releasing mutex
        self.wait_queue.push(&waiter.wait_node);

        // Atomically release mutex
        mutex.unlock();

        // Wait for signal - handles spurious wakeups
        while (true) {
            const current = waiter.notify.state.load(.acquire);
            if (current >= 1) break;
            waiter.notify.wait(current);
        }

        // Re-acquire mutex after waking
        mutex.lock();
    }

    /// Wait for a signal with a timeout.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *ConditionNotify, mutex: *Mutex, timeout: Timeout) error{Timeout}!void {
        if (timeout == .none) {
            return self.wait(mutex);
        }

        var waiter = Waiter.init();

        self.wait_queue.push(&waiter.wait_node);

        // Atomically release mutex
        mutex.unlock();

        // Wait for signal or timeout - handles spurious wakeups
        const deadline = timeout.toDeadline();
        while (true) {
            const current = waiter.notify.state.load(.acquire);
            if (current >= 1) break;

            const remaining = deadline.durationFromNow();
            if (remaining.value <= 0) break;

            waiter.notify.timedWait(current, remaining) catch {};
        }

        // Determine winner: can we remove ourselves from queue?
        const timed_out = self.wait_queue.remove(&waiter.wait_node);

        // Re-acquire mutex
        mutex.lock();

        if (timed_out) {
            // We successfully removed ourselves - we timed out
            return error.Timeout;
        }

        // We were already removed by signal() - ensure signal completed
        while (true) {
            const current = waiter.notify.state.load(.acquire);
            if (current >= 1) break;
            waiter.notify.wait(current);
        }
    }

    /// Wake one waiting thread.
    pub fn signal(self: *ConditionNotify) void {
        if (self.wait_queue.pop()) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.notify.signal();
        }
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *ConditionNotify) void {
        while (self.wait_queue.pop()) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.notify.signal();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mutex - basic lock unlock" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();
    var counter = std.atomic.Value(u32).init(0);

    const Context = struct {
        mutex: *Mutex,
        counter: *std.atomic.Value(u32),
    };

    const worker = struct {
        fn run(ctx: *Context) void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                ctx.mutex.lock();
                _ = ctx.counter.fetchAdd(1, .monotonic);
                ctx.mutex.unlock();
            }
        }
    }.run;

    var ctx = Context{ .mutex = &mutex, .counter = &counter };
    const t1 = try std.Thread.spawn(.{}, worker, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, worker, .{&ctx});
    const t3 = try std.Thread.spawn(.{}, worker, .{&ctx});
    defer t1.join();
    defer t2.join();
    defer t3.join();
}

test "Futex - wake all" {
    if (builtin.single_threaded) return error.SkipZigTest;
    if (Futex == void) return error.SkipZigTest;

    var futex_value = std.atomic.Value(u32).init(0);
    var mutex = Mutex.init();
    defer mutex.deinit();
    var threads_ready = std.atomic.Value(u32).init(0);

    const Context = struct {
        futex: *std.atomic.Value(u32),
        mutex: *Mutex,
        threads_ready: *std.atomic.Value(u32),
    };

    const waiter = struct {
        fn run(ctx: *Context) void {
            ctx.mutex.lock();
            const seq = ctx.futex.load(.monotonic);
            _ = ctx.threads_ready.fetchAdd(1, .release);
            ctx.mutex.unlock();
            Futex.wait(ctx.futex, seq);
            ctx.mutex.lock();
            ctx.mutex.unlock();
        }
    }.run;

    var ctx = Context{ .futex = &futex_value, .mutex = &mutex, .threads_ready = &threads_ready };
    const t1 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    const t3 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer t1.join();
    defer t2.join();
    defer t3.join();

    // Wait for all threads to be ready
    while (threads_ready.load(.acquire) < 3) {
        std.Thread.yield() catch {};
    }

    _ = futex_value.fetchAdd(1, .monotonic);
    Futex.wake(&futex_value, .all);
}

test "Notify - basic signal and wait" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var notify = Notify.init();
    var ready = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        notify: *Notify,
        ready: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            // Signal that we're ready to wait
            ctx.ready.store(true, .release);

            // Wait for signal
            var state = ctx.notify.state.load(.monotonic);
            while (!ctx.done.load(.acquire)) {
                ctx.notify.timedWait(state, .fromMilliseconds(100)) catch {};
                state = ctx.notify.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .notify = &notify, .ready = &ready, .done = &done };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Signal the notify
    done.store(true, .release);
    notify.signal();
}

test "Notify - multiple signals" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var notify = Notify.init();
    var counter = std.atomic.Value(u32).init(0);
    var ready = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        notify: *Notify,
        counter: *std.atomic.Value(u32),
        ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            ctx.ready.store(true, .release);
            var state = ctx.notify.state.load(.monotonic);
            while (ctx.counter.load(.acquire) < 3) {
                ctx.notify.timedWait(state, .fromMilliseconds(100)) catch {};
                state = ctx.notify.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .notify = &notify, .counter = &counter, .ready = &ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Send multiple signals
    for (0..3) |_| {
        _ = counter.fetchAdd(1, .release);
        notify.signal();
        std.Thread.yield() catch {};
    }
}

test "Notify - timedWait success (signaled before timeout)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var ready = std.atomic.Value(bool).init(false);
    var notify_ptr = std.atomic.Value(?*Notify).init(null);

    const Context = struct {
        notify_ptr: *std.atomic.Value(?*Notify),
        ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *Context) void {
            // Create Notify on the waiting thread (required for NetBSD)
            var notify = Notify.init();
            ctx.notify_ptr.store(&notify, .release);
            ctx.ready.store(true, .release);
            // Wait with long timeout (1 second), but should be signaled quickly
            notify.timedWait(0, .fromSeconds(1)) catch |err| {
                std.debug.panic("timedWait failed: {}", .{err});
            };
        }
    }.run;

    var ctx = Context{ .notify_ptr = &notify_ptr, .ready = &ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Signal the notify - should wake up without timeout
    notify_ptr.load(.acquire).?.signal();
}

test "Notify - timeout" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var notify = Notify.init();

    // Loop to handle spurious wakeups (e.g., stale EALREADY from previous tests)
    const start = std.time.nanoTimestamp();
    while (true) {
        const result = notify.timedWait(0, .fromMilliseconds(50));

        // Check if notify state changed (spurious wakeup if not)
        if (notify.state.load(.acquire) != 0) {
            return error.TestUnexpectedSignal; // Notify was signaled, shouldn't happen
        }

        // State unchanged, check if we got timeout or spurious wakeup
        if (result) |_| {
            // Spurious wakeup, retry
            continue;
        } else |err| {
            // Got timeout
            try std.testing.expectEqual(error.Timeout, err);
            break;
        }
    }

    const elapsed = std.time.nanoTimestamp() - start;
    // Allow some slack for scheduling
    try std.testing.expect(elapsed >= 40 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 200 * std.time.ns_per_ms);
}

test "Mutex - basic lock and unlock" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();

    mutex.lock();
    mutex.unlock();
}

test "Mutex - tryLock" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();

    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

test "Mutex - contention" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();

    var counter: u32 = 0;
    var ready = std.atomic.Value(u32).init(0);

    const Context = struct {
        mutex: *Mutex,
        counter: *u32,
        ready: *std.atomic.Value(u32),
    };

    const worker = struct {
        fn run(ctx: *Context) void {
            _ = ctx.ready.fetchAdd(1, .release);

            // Wait for all threads to be ready
            while (ctx.ready.load(.acquire) < 4) {
                std.Thread.yield() catch {};
            }

            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                ctx.mutex.lock();
                ctx.counter.* += 1;
                ctx.mutex.unlock();
            }
        }
    }.run;

    var ctx = Context{ .mutex = &mutex, .counter = &counter, .ready = &ready };
    var threads: [4]std.Thread = undefined;

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
    }

    for (threads) |t| {
        t.join();
    }

    try std.testing.expectEqual(400, counter);
}

test "Condition - basic wait and signal" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();
    var cond = Condition.init();
    defer cond.deinit();
    var ready = std.atomic.Value(bool).init(false);
    var thread_ready = std.atomic.Value(bool).init(false);

    const Context = struct {
        mutex: *Mutex,
        cond: *Condition,
        ready: *std.atomic.Value(bool),
        thread_ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *Context) void {
            ctx.mutex.lock();
            ctx.thread_ready.store(true, .release);
            while (!ctx.ready.load(.acquire)) {
                ctx.cond.wait(ctx.mutex);
            }
            ctx.mutex.unlock();
        }
    }.run;

    var ctx = Context{ .mutex = &mutex, .cond = &cond, .ready = &ready, .thread_ready = &thread_ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for thread to be ready
    while (!thread_ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Signal the condition
    mutex.lock();
    ready.store(true, .release);
    mutex.unlock();
    cond.signal();
}

test "Condition - broadcast" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();
    var cond = Condition.init();
    defer cond.deinit();
    var ready = std.atomic.Value(bool).init(false);
    var count = std.atomic.Value(u32).init(0);
    var threads_ready = std.atomic.Value(u32).init(0);

    const Context = struct {
        mutex: *Mutex,
        cond: *Condition,
        ready: *std.atomic.Value(bool),
        count: *std.atomic.Value(u32),
        threads_ready: *std.atomic.Value(u32),
    };

    const waiter = struct {
        fn run(ctx: *Context) void {
            ctx.mutex.lock();
            while (!ctx.ready.load(.acquire)) {
                // Signal we're about to block
                _ = ctx.threads_ready.fetchAdd(1, .release);
                ctx.cond.wait(ctx.mutex);
                // If spurious wakeup, decrement and retry
                if (!ctx.ready.load(.acquire)) {
                    _ = ctx.threads_ready.fetchSub(1, .release);
                }
            }
            _ = ctx.count.fetchAdd(1, .acq_rel);
            ctx.mutex.unlock();
        }
    }.run;

    var ctx = Context{ .mutex = &mutex, .cond = &cond, .ready = &ready, .count = &count, .threads_ready = &threads_ready };
    const t1 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    const t3 = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer t1.join();
    defer t2.join();
    defer t3.join();

    // Yield until all threads are about to block
    while (threads_ready.load(.acquire) < 3) {
        std.Thread.yield() catch {};
    }

    // Brief sleep to ensure threads have entered kernel wait
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Broadcast to all waiters
    mutex.lock();
    ready.store(true, .release);
    cond.broadcast();
    mutex.unlock();
}

test "Condition - timedWait timeout" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mutex = Mutex.init();
    defer mutex.deinit();
    var cond = Condition.init();
    defer cond.deinit();
    var timed_out = std.atomic.Value(bool).init(false);
    var thread_ready = std.atomic.Value(bool).init(false);

    const Context = struct {
        mutex: *Mutex,
        cond: *Condition,
        timed_out: *std.atomic.Value(bool),
        thread_ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *Context) void {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.thread_ready.store(true, .release);
            ctx.cond.timedWait(ctx.mutex, .{ .duration = .fromMilliseconds(10) }) catch |err| {
                if (err == error.Timeout) {
                    ctx.timed_out.store(true, .release);
                }
            };
        }
    }.run;

    var ctx = Context{ .mutex = &mutex, .cond = &cond, .timed_out = &timed_out, .thread_ready = &thread_ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});

    // Wait for thread to be ready
    while (!thread_ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Don't signal - let it timeout
    thread.join();

    try std.testing.expect(timed_out.load(.acquire));
}
