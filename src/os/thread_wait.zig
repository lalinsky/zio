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
/// This is an internal implementation detail - use the public `wait()` and `wake()`
/// functions or the `Event` type instead.
///
/// Methods:
/// - `wait(ptr, current, timeout)`: Block if *ptr == current, with optional timeout
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

/// Thread synchronization event.
///
/// A higher-level abstraction over platform wait primitives that owns its state.
/// Use this instead of raw wait/wake functions when you need to own the state.
///
/// **Important**: Only one thread should wait on this event at a time.
/// For multi-waiter scenarios, use the raw wait/wake functions instead.
///
/// Example usage:
/// ```zig
/// var event: Event = .init();
///
/// // Waiter thread
/// event.wait(1, null); // Wait indefinitely
/// // or
/// event.wait(1, .fromSeconds(1)); // Wait with 1s timeout
///
/// // Signaler thread
/// event.signal();
/// ```
pub const Event = switch (builtin.os.tag) {
    .netbsd => EventNetBSD,
    else => EventFutex,
};

/// Mutex for thread synchronization.
///
/// A blocking mutex that uses platform-specific optimal primitives:
/// - Windows: SRWLOCK (Slim Reader/Writer Lock)
/// - Darwin/macOS: os_unfair_lock
/// - NetBSD: Event-based with WaitQueue
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
/// - Other platforms: Event-based with WaitQueue
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
    else => ConditionEvent,
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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
            current,
            if (timeout_ts) |*ts| ts else null,
            null,
            0,
        );
        // Ignore errors - spurious wakeups and timeouts are both fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(u32),
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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        // RtlWaitOnAddress takes timeout in 100ns units (negative = relative)
        const timeout_li: ?sys.LARGE_INTEGER = if (timeout) |t| blk: {
            const ns = t.toNanoseconds();
            const units_100ns = ns / 100;
            const i64_val = std.math.cast(i64, units_100ns) orelse std.math.maxInt(i64);
            break :blk -i64_val; // Negative means relative timeout
        } else null;

        // RtlWaitOnAddress atomically checks if *ptr == current before sleeping
        _ = sys.RtlWaitOnAddress(
            &ptr.raw,
            &current,
            @sizeOf(u32),
            if (timeout_li) |*t| t else null,
        );
        // Return value doesn't matter - we handle spurious wakeups in the caller's loop
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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_us: u32 = if (timeout) |t| blk: {
            const us = t.toMicroseconds();
            const clamped = std.math.cast(u32, us) orelse std.math.maxInt(u32);
            break :blk @max(1, clamped);
        } else 0;

        _ = sys.__ulock_wait(
            sys.UL_COMPARE_AND_WAIT,
            &ptr.raw,
            current,
            timeout_us,
        );
        // Ignore errors - spurious wakeups and timeouts are fine
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const flags: u32 = switch (count) {
            .one => sys.UL_COMPARE_AND_WAIT | sys.ULF_WAKE_THREAD,
            .all => sys.UL_COMPARE_AND_WAIT | sys.ULF_WAKE_ALL,
        };

        _ = sys.__ulock_wake(flags, &ptr.raw, 0);
    }
};

// ============================================================================
// FreeBSD implementation
// ============================================================================

const FutexFreeBSD = struct {
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys._umtx_op(
            &ptr.raw,
            sys.UMTX_OP_WAIT_UINT,
            current,
            null,
            if (timeout_ts) |*ts| @ptrCast(@constCast(ts)) else null,
        );
    }

    fn wake(ptr: *const std.atomic.Value(u32), count: WakeCount) void {
        const n: u32 = switch (count) {
            .one => 1,
            .all => std.math.maxInt(u32),
        };
        _ = sys._umtx_op(
            &ptr.raw,
            sys.UMTX_OP_WAKE,
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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        _ = sys.futex(
            &ptr.raw,
            sys.FUTEX_WAIT | sys.FUTEX_PRIVATE_FLAG,
            @intCast(current),
            if (timeout_ts) |*ts| ts else null,
            null,
        );
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
    fn wait(ptr: *const std.atomic.Value(u32), current: u32, timeout: ?Duration) void {
        const timeout_ns = if (timeout) |t| t.toNanoseconds() else 0;
        _ = sys.umtx_sleep(
            &ptr.raw,
            @intCast(current),
            @intCast(timeout_ns),
        );
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
// Event implementations
// ============================================================================

/// Futex-based event for platforms with futex-like primitives
const EventFutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn init() EventFutex {
        return .{};
    }

    pub fn wait(self: *EventFutex, current: u32, timeout: ?Duration) void {
        Futex.wait(&self.state, current, timeout);
    }

    pub fn signal(self: *EventFutex) void {
        _ = self.state.fetchAdd(1, .release);
        Futex.wake(&self.state, .one);
    }
};

/// NetBSD event using native _lwp_park/_lwp_unpark
///
/// Implementation note: _lwp_park/_lwp_unpark handles signal-before-wait races safely.
/// If _lwp_unpark() is called before the LWP calls _lwp_park(), the kernel sets the
/// LW_UNPARKED flag on the target LWP. When that LWP later calls _lwp_park(), it
/// immediately returns EALREADY without blocking. This means signal() can be called
/// before wait() without losing the wakeup.
///
/// The lwp_id is captured at init() time, so this Event must be created on the same
/// thread that will call wait(). Other threads can safely call signal().
const EventNetBSD = struct {
    state: std.atomic.Value(u32) = .init(0),
    lwp_id: c_int,

    pub fn init() EventNetBSD {
        return .{
            .lwp_id = sys._lwp_self(),
        };
    }

    pub fn wait(self: *EventNetBSD, current: u32, timeout: ?Duration) void {
        _ = self;
        _ = current; // Caller checks state, we just park

        const timeout_ts: ?std.posix.timespec = if (timeout) |t| t.toTimespec() else null;

        // Safe to call even if signal() was already called - the kernel remembers
        // the unpark and will return EALREADY immediately without blocking.
        _ = sys.___lwp_park60(
            @intFromEnum(std.posix.CLOCK.MONOTONIC),
            0,
            if (timeout_ts) |*ts| ts else null,
            0, // unpark: don't unpark anyone
            null, // hint
            null, // unparkhint
        );
    }

    pub fn signal(self: *EventNetBSD) void {
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
            Futex.wait(&self.state, LOCKED_WITH_WAITERS, null);
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
            Futex.wait(&self.state, LOCKED_WITH_WAITERS, null);
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

/// Event-based mutex using WaitQueue for platforms with Event support.
///
/// Uses the same pattern as zio.Mutex but for blocking OS threads:
/// - Queue state encodes lock status with sentinels
/// - Stack-allocated waiters block on Events instead of suspending coroutines
/// - FIFO ordering ensures fairness
const MutexEvent = struct {
    /// Stack-allocated waiter that blocks an OS thread
    const Waiter = struct {
        wait_node: WaitNode,
        event: Event,

        fn init() Waiter {
            return .{
                .wait_node = .{ .vtable = &.{} },
                .event = Event.init(),
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
        while (waiter.event.state.load(.acquire) == 0) {
            waiter.event.wait(0, null);
        }

        // Acquire fence: synchronize-with unlock()'s .release in pop()
        _ = self.queue.getState();
    }

    pub fn unlock(self: *MutexEvent) void {
        // Pop one waiter or transition from locked_once to unlocked
        // Last waiter stays in locked_once (inherits the lock)
        if (self.queue.popOrTransition(locked_once, unlocked, locked_once)) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.event.signal();
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

/// Event-based condition variable using WaitQueue.
///
/// Uses the same pattern as zio.Condition but for blocking OS threads:
/// - WaitQueue manages the list of waiting threads
/// - Stack-allocated waiters block on Events instead of suspending coroutines
/// - Works with any Mutex type
const ConditionEvent = struct {
    /// Stack-allocated waiter that blocks an OS thread
    const Waiter = struct {
        wait_node: WaitNode,
        event: Event,

        fn init() Waiter {
            return .{
                .wait_node = .{ .vtable = &.{} },
                .event = Event.init(),
            };
        }
    };

    wait_queue: WaitQueue(WaitNode) = .empty,

    pub fn init() ConditionEvent {
        return .{};
    }

    pub fn deinit(self: *ConditionEvent) void {
        _ = self;
    }

    /// Wait for a signal. The mutex must be held when calling this.
    /// The mutex is atomically released and the thread blocks.
    /// When signaled, the mutex is automatically reacquired before returning.
    pub fn wait(self: *ConditionEvent, mutex: *Mutex) void {
        var waiter = Waiter.init();

        // Add to wait queue before releasing mutex
        self.wait_queue.push(&waiter.wait_node);

        // Atomically release mutex
        mutex.unlock();

        // Wait for signal - handles spurious wakeups
        while (true) {
            const current = waiter.event.state.load(.acquire);
            if (current >= 1) break;
            waiter.event.wait(current, null);
        }

        // Re-acquire mutex after waking
        mutex.lock();
    }

    /// Wait for a signal with a timeout.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *ConditionEvent, mutex: *Mutex, timeout: Timeout) error{Timeout}!void {
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
            const current = waiter.event.state.load(.acquire);
            if (current >= 1) break;

            const remaining = deadline.durationFromNow();
            if (remaining.value <= 0) break;

            waiter.event.wait(current, remaining);
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
            const current = waiter.event.state.load(.acquire);
            if (current >= 1) break;
            waiter.event.wait(current, null);
        }
    }

    /// Wake one waiting thread.
    pub fn signal(self: *ConditionEvent) void {
        if (self.wait_queue.pop()) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.event.signal();
        }
    }

    /// Wake all waiting threads.
    pub fn broadcast(self: *ConditionEvent) void {
        while (self.wait_queue.pop()) |wait_node| {
            const waiter: *Waiter = @fieldParentPtr("wait_node", wait_node);
            waiter.event.signal();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Event - basic signal and wait" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    var ready = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        event: *Event,
        ready: *std.atomic.Value(bool),
        done: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            // Signal that we're ready to wait
            ctx.ready.store(true, .release);

            // Wait for signal
            var state = ctx.event.state.load(.monotonic);
            while (!ctx.done.load(.acquire)) {
                ctx.event.wait(state, .fromMilliseconds(100));
                state = ctx.event.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .event = &event, .ready = &ready, .done = &done };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Signal the event
    done.store(true, .release);
    event.signal();
}

test "Event - multiple signals" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    var counter = std.atomic.Value(u32).init(0);
    var ready = std.atomic.Value(bool).init(false);

    const WaiterContext = struct {
        event: *Event,
        counter: *std.atomic.Value(u32),
        ready: *std.atomic.Value(bool),
    };

    const waiter = struct {
        fn run(ctx: *WaiterContext) void {
            ctx.ready.store(true, .release);
            var state = ctx.event.state.load(.monotonic);
            while (ctx.counter.load(.acquire) < 3) {
                ctx.event.wait(state, .fromMilliseconds(100));
                state = ctx.event.state.load(.monotonic);
            }
        }
    }.run;

    var ctx = WaiterContext{ .event = &event, .counter = &counter, .ready = &ready };
    const thread = try std.Thread.spawn(.{}, waiter, .{&ctx});
    defer thread.join();

    // Wait for waiter to be ready
    while (!ready.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Send multiple signals
    for (0..3) |_| {
        _ = counter.fetchAdd(1, .release);
        event.signal();
        std.Thread.yield() catch {};
    }
}

test "Event - timeout" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var event = Event.init();
    const start = std.time.nanoTimestamp();

    // Wait with timeout, should return after approximately 50ms
    event.wait(0, .fromMilliseconds(50));

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

    try std.testing.expectEqual(@as(u32, 400), counter);
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
            _ = ctx.threads_ready.fetchAdd(1, .release);
            while (!ctx.ready.load(.acquire)) {
                ctx.cond.wait(ctx.mutex);
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

    // Wait for all threads to be ready
    while (threads_ready.load(.acquire) < 3) {
        std.Thread.yield() catch {};
    }

    // Broadcast to all waiters
    mutex.lock();
    ready.store(true, .release);
    mutex.unlock();
    cond.broadcast();
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
