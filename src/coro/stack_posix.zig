// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! POSIX coroutine stack allocation.
//!
//! Contains the low-level mmap-based stack primitives, the SIGSEGV/SIGBUS
//! automatic-growth machinery, and the slab-based `PosixStackPool`. The
//! platform-neutral facade lives in `stack.zig`; valgrind bookkeeping for the
//! standalone alloc/free/extend API is applied there.

const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../os/posix.zig");
const fs = @import("../os/fs.zig");
const coroutines = @import("coroutines.zig");
const os = @import("../os/root.zig");

const stack = @import("stack.zig");
const StackInfo = stack.StackInfo;
const StackExtendMode = stack.StackExtendMode;
const StackPoolConfig = stack.StackPoolConfig;

const Allocator = std.mem.Allocator;
const Timestamp = @import("../time.zig").Timestamp;
const log = @import("../common.zig").log;

// Signal type changed from c_int to enum in Zig 0.16
const is_pre_016 = builtin.zig_version.major == 0 and builtin.zig_version.minor < 16;
const SigInt = if (is_pre_016) c_int else posix.SIG;

// Stack growth signal handler state.
threadlocal var altstack_installed: bool = false;
threadlocal var altstack_mem: ?[]u8 = null;
var signal_handler_refcount: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var old_sigsegv_action: posix.Sigaction = undefined;
var old_sigbus_action: posix.Sigaction = undefined;

// ---------------------------------------------------------------------------
// Stack growth
// ---------------------------------------------------------------------------

/// Extend the committed stack region.
/// Mode .grow: Grow by 1.5x current size in 64KB chunks
/// Mode .full: Commit all remaining uncommitted stack
pub fn stackExtend(info: *StackInfo, mode: StackExtendMode) error{StackOverflow}!void {
    const guard_end = @intFromPtr(info.allocation_ptr) + std.heap.pageSize();

    // Calculate new limit based on mode
    const new_limit = switch (mode) {
        .grow => blk: {
            const chunk_size = 64 * 1024;
            const growth_factor_num = 3;
            const growth_factor_den = 2;

            // Calculate current committed size
            const current_committed = info.base - info.limit;

            // Calculate new committed size (1.5x current)
            const new_committed_size = (current_committed * growth_factor_num) / growth_factor_den;
            const additional_size = new_committed_size - current_committed;
            const size_to_commit = std.mem.alignForward(usize, additional_size, chunk_size);

            // Check if we have enough uncommitted space
            if (size_to_commit > info.limit) {
                return error.StackOverflow;
            }
            break :blk info.limit - size_to_commit;
        },
        .full => guard_end, // Commit all the way to guard page
    };

    // Check we don't overflow into guard page
    if (new_limit < guard_end) {
        return error.StackOverflow;
    }

    // Already at or past target
    if (new_limit >= info.limit) {
        return;
    }

    // Commit the memory region
    const ps = std.heap.pageSize();
    const commit_start = std.mem.alignBackward(usize, new_limit, ps);
    const commit_size = info.limit - commit_start;
    const addr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(commit_start);
    posix.mprotect(addr[0..commit_size], posix.PROT.READ | posix.PROT.WRITE) catch {
        return error.StackOverflow;
    };

    // Update limit to new bottom of committed region
    info.limit = commit_start;
}

// ---------------------------------------------------------------------------
// Automatic stack growth via SIGSEGV/SIGBUS handler
// ---------------------------------------------------------------------------

/// Setup automatic stack growth via SIGSEGV handler for this thread.
/// Idempotent - safe to call multiple times per thread. On first call (any
/// thread) installs the global handler; on every call sets up the alternate
/// signal stack for this thread.
///
/// Internal: exposed to callers through `PosixStackPool.setup`.
fn setupStackGrowth() !void {
    const altstack_size = posix.SIGSTKSZ;

    // Setup alternate stack for this thread if not already done
    if (!altstack_installed) {
        const mem = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.pageSize()), altstack_size);
        errdefer std.heap.page_allocator.free(mem);

        var stack_t = posix.stack_t{
            .flags = 0,
            .sp = mem.ptr,
            .size = altstack_size,
        };

        try posix.sigaltstack(&stack_t, null);

        altstack_mem = mem;
        altstack_installed = true;
    }

    // Install global signal handler (once per process)
    const prev_refcount = signal_handler_refcount.fetchAdd(1, .acquire);
    if (prev_refcount == 0) {
        var sa = posix.Sigaction{
            .handler = .{ .sigaction = stackFaultHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO | posix.SA.ONSTACK,
        };

        posix.sigaction(posix.SIG.SEGV, &sa, &old_sigsegv_action);

        // macOS sends SIGBUS for PROT_NONE access, not SIGSEGV
        if (builtin.os.tag.isDarwin()) {
            posix.sigaction(posix.SIG.BUS, &sa, &old_sigbus_action);
        }
    }
}

/// Cleanup stack growth handler state for this thread.
/// Should be called when a thread exits if setupStackGrowth() was called.
///
/// Internal: exposed to callers through `PosixStackPool.teardown`.
fn cleanupStackGrowth() void {
    if (altstack_installed) {
        var disable_stack = posix.stack_t{
            .flags = posix.SS.DISABLE,
            .sp = null,
            .size = 0,
        };
        posix.sigaltstack(&disable_stack, null) catch {
            // Best effort - can't do much if this fails
        };

        if (altstack_mem) |mem| {
            std.heap.page_allocator.free(mem);
            altstack_mem = null;
        }

        altstack_installed = false;
    }

    // Decrement refcount; if this was the last thread, uninstall the handler
    const prev_refcount = signal_handler_refcount.fetchSub(1, .release);
    if (prev_refcount == 1) {
        posix.sigaction(posix.SIG.SEGV, &old_sigsegv_action, null);
        if (builtin.os.tag.isDarwin()) {
            posix.sigaction(posix.SIG.BUS, &old_sigbus_action, null);
        }
    }
}

/// Extract fault address from siginfo_t in a platform-agnostic way
inline fn getFaultAddress(info: *const posix.siginfo_t) usize {
    return @intFromPtr(switch (builtin.os.tag) {
        .linux => info.fields.sigfault.addr,
        .macos, .ios, .tvos, .watchos, .visionos => info.addr,
        .freebsd, .dragonfly => info.addr,
        .netbsd => info.info.reason.fault.addr,
        .illumos => info.reason.fault.addr,
        else => @compileError("Stack growth not supported on this platform"),
    });
}

/// Invoke the previous signal handler or use default behavior, allowing proper
/// handler chaining instead of unconditionally aborting.
fn invokePreviousHandler(sig: SigInt, info: *const posix.siginfo_t, ctx: ?*anyopaque) noreturn {
    const old_sa = if (sig == posix.SIG.SEGV) &old_sigsegv_action else &old_sigbus_action;

    if ((old_sa.flags & posix.SA.SIGINFO) != 0) {
        if (old_sa.handler.sigaction) |sa| {
            sa(sig, info, ctx);
        }
    } else {
        if (old_sa.handler.handler) |h| {
            // SIG_DFL = 0, SIG_IGN = 1 (POSIX-universal sentinel values)
            if (@intFromPtr(h) <= 1) {
                // Restore the previous handler and re-raise the signal
                posix.sigaction(sig, old_sa, null);
                _ = posix.raise(sig) catch {};
            } else {
                h(sig);
            }
        }
    }

    std.process.abort();
}

/// Signal handler for automatic stack growth (SIGSEGV on Linux/BSD, SIGBUS on macOS).
/// Extends the stack if the fault is within a coroutine's uncommitted region; real
/// faults are propagated to the previous handler.
fn stackFaultHandler(sig: SigInt, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    const fault_addr = getFaultAddress(info);

    const current_ctx = coroutines.current_context orelse {
        // Not in a coroutine context - propagate to previous handler
        invokePreviousHandler(sig, info, ctx);
    };

    const stack_info = &current_ctx.stack_info;

    // Check if allocation_ptr is null (not our stack)
    if (@intFromPtr(stack_info.allocation_ptr) == 0) {
        invokePreviousHandler(sig, info, ctx);
    }

    // Stack layout: [guard_page][uncommitted][committed]
    const stack_base = @intFromPtr(stack_info.allocation_ptr);
    const guard_page_end = stack_base + std.heap.pageSize();
    const uncommitted_start = guard_page_end;
    const uncommitted_end = stack_info.limit;

    // Check if fault is in guard page (true stack overflow)
    if (fault_addr >= stack_base and fault_addr < guard_page_end) {
        abortOnStackOverflow(fault_addr, stack_info);
    }

    // Check if fault is in uncommitted region (automatic growth)
    if (fault_addr >= uncommitted_start and fault_addr < uncommitted_end) {
        stackExtend(stack_info, .grow) catch {
            abortOnStackOverflow(fault_addr, stack_info);
        };
        // Stack extended successfully - return to resume execution
        return;
    }

    // Fault is not in our stack region - propagate to previous handler
    invokePreviousHandler(sig, info, ctx);
}

/// Abort with diagnostic message on stack overflow, using async-signal-safe write().
fn abortOnStackOverflow(fault_addr: usize, stack_info: *const StackInfo) noreturn {
    var buf: [300]u8 = undefined;

    const stack_base = @intFromPtr(stack_info.allocation_ptr);
    const stack_size = stack_info.allocation_len;
    const committed = stack_info.base - stack_info.limit;
    const is_guard_page_fault = fault_addr >= stack_base and fault_addr < stack_base + std.heap.pageSize();

    const msg = std.fmt.bufPrint(
        &buf,
        "Coroutine stack overflow!\n" ++
            "  Fault address:    0x{x}\n" ++
            "  Stack base:       0x{x}\n" ++
            "  Stack size:       {d} KB\n" ++
            "  Committed:        {d} KB\n" ++
            "  Guard page fault: {}\n",
        .{
            fault_addr,
            stack_base,
            stack_size / 1024,
            committed / 1024,
            is_guard_page_fault,
        },
    ) catch "Coroutine stack overflow (error formatting message)\n";

    _ = fs.write(fs.stderr(), msg) catch {};
    std.process.abort();
}

// ---------------------------------------------------------------------------
// Slab-based stack pool
// ---------------------------------------------------------------------------

/// Used when Config.slab_stacks is left at 0.
const default_slab_stacks: usize = 32;

const enable_valgrind = builtin.mode == .Debug and builtin.valgrind_support;

/// One mmap reservation carved into `stacks` fixed-size slots.
///
/// Stacks are carved as fixed-size slots out of large mmap reservations
/// ("slabs"), amortizing the per-stack mmap/munmap syscall cost that dominates
/// short-lived workloads (CLI tools): a slab of N stacks costs one mmap instead
/// of N, and munmap is deferred until an entire slab drains.
///
/// The per-slot layout is byte-for-byte identical to the single-stack path
/// above (guard page folded into `maximum_size`), so the growth handler and
/// `stackExtend` operate on slab slots unchanged.
///
/// The usage bitmap *is* the free list: `release()` only clears a bit (no
/// syscalls, no decommit), so a reused slot's pages stay resident and warm
/// `acquire()` is also syscall-free; only the first use of a slot pays one
/// `mprotect` to commit its initial region.
const Slab = struct {
    base: [*]align(std.heap.page_size_min) u8,
    stacks: usize,
    slot_size: usize,
    used: usize,
    /// Timestamp at which `used` last dropped to 0, for age-based reclamation.
    free_since: Timestamp,
    /// 1 = slot in use, 0 = free. Padding bits (>= stacks) are pinned to 1.
    bitmap: []u64,
    /// Per-slot committed boundary. Equals the slot top when never committed;
    /// otherwise tracks how far the stack has grown so reuse skips re-committing.
    limits: []usize,
    /// Per-slot valgrind stack id (0 = unregistered). Empty unless enabled.
    valgrind_ids: []usize,
    next: ?*Slab,

    fn slotBase(self: *const Slab, i: usize) usize {
        return @intFromPtr(self.base) + i * self.slot_size;
    }

    fn slotTop(self: *const Slab, i: usize) usize {
        return self.slotBase(i) + self.slot_size;
    }

    fn contains(self: *const Slab, addr: usize) bool {
        const lo = @intFromPtr(self.base);
        return addr >= lo and addr < lo + self.stacks * self.slot_size;
    }

    fn findFreeSlot(self: *const Slab) ?usize {
        for (self.bitmap, 0..) |word, wi| {
            if (word != ~@as(u64, 0)) {
                // Padding bits are pinned to 1, so the result is always < stacks.
                return wi * 64 + @ctz(~word);
            }
        }
        return null;
    }

    fn setBit(self: *Slab, i: usize) void {
        self.bitmap[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
    }

    fn clearBit(self: *Slab, i: usize) void {
        self.bitmap[i >> 6] &= ~(@as(u64, 1) << @intCast(i & 63));
    }
};

pub const PosixStackPool = struct {
    allocator: Allocator,
    config: StackPoolConfig,
    stacks_per_slab: usize,
    slot_size: usize,
    commit_size: usize,
    mutex: os.Mutex,
    slabs: ?*Slab,

    pub fn init(allocator: Allocator, config: StackPoolConfig) PosixStackPool {
        const stacks_per_slab = if (config.slab_stacks == 0) default_slab_stacks else config.slab_stacks;

        // Guard page is folded into maximum_size: the bottom page of each slot
        // is the guard, so usable stack is (slot_size - page_size). Require at
        // least 2 pages (guard + one usable page).
        const ps = std.heap.pageSize();
        const slot_size = std.mem.alignForward(usize, @max(config.maximum_size, 2 * ps), ps);
        const commit_size = std.mem.alignForward(usize, config.committed_size, ps);
        std.debug.assert(commit_size <= slot_size - ps);

        return .{
            .allocator = allocator,
            .config = config,
            .stacks_per_slab = stacks_per_slab,
            .slot_size = slot_size,
            .commit_size = commit_size,
            .mutex = .init(),
            .slabs = null,
        };
    }

    pub fn deinit(self: *PosixStackPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var cur = self.slabs;
        while (cur) |s| {
            const next = s.next;
            self.destroySlab(s);
            cur = next;
        }
        self.slabs = null;
    }

    /// Install the per-thread automatic stack-growth handler. Must be called
    /// once on every thread that runs coroutines using stacks from this pool,
    /// before the first coroutine runs there. Thread-local / process-global;
    /// independent of any particular pool instance.
    pub fn setup() !void {
        return setupStackGrowth();
    }

    /// Tear down the per-thread stack-growth handler. Call on thread exit if
    /// setup() was called.
    pub fn teardown() void {
        cleanupStackGrowth();
    }

    /// Acquire a stack. Reuses a free slot if one exists (no syscall, or a
    /// single mprotect to commit a never-before-used slot), otherwise reserves
    /// a fresh slab (one mmap for `stacks_per_slab` slots).
    pub fn acquire(self: *PosixStackPool) error{OutOfMemory}!StackInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slab, const slot = self.findFreeSlot() orelse blk: {
            const s = try self.newSlab();
            break :blk .{ s, s.findFreeSlot().? };
        };

        slab.setBit(slot);
        slab.used += 1;
        errdefer {
            slab.clearBit(slot);
            slab.used -= 1;
        }

        return try self.buildStackInfo(slab, slot);
    }

    /// Release a stack back to its slab. Clears one bit; no syscalls, no
    /// decommit. The slab is unmapped lazily in `cleanup`/`deinit`.
    ///
    /// The owning slab is recovered in O(1) from the pool cookie stashed in the
    /// StackInfo at acquire time, rather than scanning the slab list.
    pub fn release(self: *PosixStackPool, stack_info: StackInfo, timestamp: Timestamp) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slab: *Slab = @ptrFromInt(stack_info.pool_cookie);
        const addr = @intFromPtr(stack_info.allocation_ptr);
        std.debug.assert(slab.contains(addr));

        const slot = (addr - @intFromPtr(slab.base)) / slab.slot_size;
        // Persist the grown committed boundary so the next user of this slot
        // reuses the already-resident pages without re-committing.
        slab.limits[slot] = stack_info.limit;
        slab.clearBit(slot);
        slab.used -= 1;
        if (slab.used == 0) slab.free_since = timestamp;
    }

    /// Reclaim up to `limit` fully-drained slabs older than `max_age`.
    /// Intended to be driven from a periodic timer. No-op without an age limit.
    pub fn cleanup(self: *PosixStackPool, now: Timestamp, limit: usize) void {
        if (self.config.max_age.value == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        var removed: usize = 0;
        var prev: ?*Slab = null;
        var cur = self.slabs;
        while (cur) |s| {
            const next = s.next;
            const expired = s.used == 0 and s.free_since.durationTo(now).value > self.config.max_age.value;
            if (removed < limit and expired) {
                if (prev) |p| p.next = next else self.slabs = next;
                self.destroySlab(s);
                removed += 1;
            } else {
                prev = s;
            }
            cur = next;
        }
    }

    fn findFreeSlot(self: *PosixStackPool) ?struct { *Slab, usize } {
        var cur = self.slabs;
        while (cur) |s| : (cur = s.next) {
            if (s.used < s.stacks) {
                if (s.findFreeSlot()) |slot| return .{ s, slot };
            }
        }
        return null;
    }

    fn buildStackInfo(self: *PosixStackPool, slab: *Slab, slot: usize) error{OutOfMemory}!StackInfo {
        const slot_base = slab.slotBase(slot);
        const top = slab.slotTop(slot);
        var limit = slab.limits[slot];

        if (limit == top) {
            // Never-used slot: commit the initial region at the top of the slot.
            const new_limit = top - self.commit_size;
            const region: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(new_limit);
            posix.mprotect(region[0..self.commit_size], posix.PROT.READ | posix.PROT.WRITE) catch |err| {
                log.err("Failed to commit stack slot (size={d}): {}", .{ self.commit_size, err });
                return error.OutOfMemory;
            };
            slab.limits[slot] = new_limit;
            limit = new_limit;
        }

        var info: StackInfo = .{
            .allocation_ptr = @ptrFromInt(slot_base),
            .base = top,
            .limit = limit,
            .allocation_len = slab.slot_size,
            .pool_cookie = @intFromPtr(slab),
        };

        if (enable_valgrind) {
            if (slab.valgrind_ids[slot] == 0) {
                const s: [*]u8 = @ptrFromInt(limit);
                slab.valgrind_ids[slot] = std.valgrind.stackRegister(s[0 .. top - limit]);
            }
            info.valgrind_stack_id = slab.valgrind_ids[slot];
        }

        return info;
    }

    fn newSlab(self: *PosixStackPool) error{OutOfMemory}!*Slab {
        const s = try self.allocator.create(Slab);
        errdefer self.allocator.destroy(s);

        const words = (self.stacks_per_slab + 63) / 64;
        const bitmap = try self.allocator.alloc(u64, words);
        errdefer self.allocator.free(bitmap);
        @memset(bitmap, 0);
        // Pin padding bits (indices >= stacks_per_slab) to 1 so findFreeSlot
        // never returns an out-of-range slot.
        const rem: u6 = @intCast(self.stacks_per_slab & 63);
        if (rem != 0) {
            bitmap[words - 1] = ~((@as(u64, 1) << rem) - 1);
        }

        const limits = try self.allocator.alloc(usize, self.stacks_per_slab);
        errdefer self.allocator.free(limits);

        const valgrind_ids: []usize = if (enable_valgrind)
            try self.allocator.alloc(usize, self.stacks_per_slab)
        else
            &.{};
        errdefer if (enable_valgrind) self.allocator.free(valgrind_ids);
        if (enable_valgrind) @memset(valgrind_ids, 0);

        const len = self.stacks_per_slab * self.slot_size;
        const base = try reserveSlab(len);
        errdefer posix.munmap(base[0..len]) catch {};

        // Fresh slots: limit == top means "nothing committed yet".
        for (limits, 0..) |*l, i| {
            l.* = @intFromPtr(base) + (i + 1) * self.slot_size;
        }

        s.* = .{
            .base = base,
            .stacks = self.stacks_per_slab,
            .slot_size = self.slot_size,
            .used = 0,
            .free_since = .zero,
            .bitmap = bitmap,
            .limits = limits,
            .valgrind_ids = valgrind_ids,
            .next = self.slabs,
        };
        self.slabs = s;
        return s;
    }

    fn destroySlab(self: *PosixStackPool, s: *Slab) void {
        if (enable_valgrind) {
            for (s.valgrind_ids) |id| {
                if (id != 0) std.valgrind.stackDeregister(id);
            }
            self.allocator.free(s.valgrind_ids);
        }
        posix.munmap(s.base[0 .. s.stacks * s.slot_size]) catch {};
        self.allocator.free(s.bitmap);
        self.allocator.free(s.limits);
        self.allocator.destroy(s);
    }

    fn slabCount(self: *const PosixStackPool) usize {
        var n: usize = 0;
        var cur = self.slabs;
        while (cur) |s| : (cur = s.next) n += 1;
        return n;
    }
};

/// The pool selected for this platform (see stack.zig).
pub const StackPool = PosixStackPool;

/// Reserve `len` bytes of PROT_NONE address space for a slab, mirroring the
/// mmap flags used by the single-stack path above.
fn reserveSlab(len: usize) error{OutOfMemory}![*]align(std.heap.page_size_min) u8 {
    // PROT.MAX declares future RW permissions upfront for NetBSD/FreeBSD policies.
    const prot_flags = posix.PROT.NONE | posix.PROT.MAX(posix.PROT.READ | posix.PROT.WRITE);

    var map_flags = posix.MAP.PRIVATE | posix.MAP.ANONYMOUS;
    if (builtin.os.tag == .linux or builtin.os.tag == .netbsd) {
        map_flags |= posix.MAP.STACK;
    }

    const m = posix.mmap(null, len, prot_flags, map_flags, -1, 0) catch |err| {
        log.err("Failed to mmap stack slab (size={d}): {}", .{ len, err });
        return error.OutOfMemory;
    };

    // Avoid THP bloat on sparse stacks (Linux-specific).
    if (@hasDecl(posix.MADV, "NOHUGEPAGE")) {
        posix.madvise(m, posix.MADV.NOHUGEPAGE) catch {};
    }

    return m.ptr;
}

const testing = std.testing;

test "PosixStackPool: one mmap per slab, overflow spills to a new slab" {
    var pool = PosixStackPool.init(testing.allocator, .{
        .maximum_size = 128 * 1024,
        .committed_size = 8 * 1024,
        .slab_stacks = 4,
    });
    defer pool.deinit();

    var stacks: [5]StackInfo = undefined;
    for (&stacks) |*s| s.* = try pool.acquire();

    // 4 slots fill the first slab; the 5th forces a second slab.
    try testing.expectEqual(@as(usize, 2), pool.slabCount());

    // All slots are distinct, page-aligned, and guard-prefixed.
    for (stacks) |s| {
        const ps = std.heap.pageSize();
        try testing.expectEqual(@as(usize, 0), @intFromPtr(s.allocation_ptr) % ps);
        try testing.expect(s.limit > @intFromPtr(s.allocation_ptr) + ps); // guard below limit
        try testing.expect(s.base - s.limit >= 8 * 1024); // initial commit honored
    }

    for (stacks) |s| pool.release(s, .zero);
}

test "PosixStackPool: warm reuse keeps the grown committed boundary" {
    var pool = PosixStackPool.init(testing.allocator, .{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .slab_stacks = 2,
    });
    defer pool.deinit();

    var a = try pool.acquire();
    const grown_limit = a.limit - 64 * 1024; // pretend the fault handler grew it
    a.limit = grown_limit;
    pool.release(a, .zero);

    const b = try pool.acquire();
    try testing.expectEqual(@intFromPtr(a.allocation_ptr), @intFromPtr(b.allocation_ptr));
    // Reused slot inherits the larger committed region instead of resetting.
    try testing.expectEqual(grown_limit, b.limit);
    pool.release(b, .zero);
}

test "PosixStackPool: stack slots drive the growth fault handler" {
    try setupStackGrowth();
    defer cleanupStackGrowth();

    var pool = PosixStackPool.init(testing.allocator, .{
        .maximum_size = 256 * 1024,
        .committed_size = 4096, // tiny initial commit, force growth
        .slab_stacks = 2,
    });
    defer pool.deinit();

    var parent_context: coroutines.Context = undefined;
    var coro: coroutines.Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    coro.context.stack_info = try pool.acquire();
    defer pool.release(coro.context.stack_info, .zero);

    const initial_committed = coro.context.stack_info.base - coro.context.stack_info.limit;

    const RecursiveFn = struct {
        noinline fn recurse(c: *coroutines.Coroutine, depth: u32, target: u32) u32 {
            var buffer: [1024]u8 = undefined;
            // volatile pointer forces the 1KB frame to actually exist on the stack
            const p: *volatile [1024]u8 = &buffer;
            p[depth & 0xFF] = @intCast(depth & 0xFF);
            if (depth >= target) return p[0];
            // Use result after volatile read to prevent tail-call optimization
            const result = recurse(c, depth + 1, target);
            return result +% p[depth & 0xFF] -% p[depth & 0xFF];
        }
        fn start(c: *coroutines.Coroutine, target: u32) u32 {
            return recurse(c, 0, target);
        }
    };

    const Closure = coroutines.Closure(RecursiveFn.start);
    var closure = Closure.init(.{100}); // ~100KB, far past the 4KB initial commit
    coro.setup(&Closure.start, &closure);

    while (!closure.finished) coro.step();

    // The slot grew via the SIGSEGV/SIGBUS handler operating on slab memory.
    const final_committed = coro.context.stack_info.base - coro.context.stack_info.limit;
    try testing.expect(final_committed > initial_committed);
}

test "PosixStackPool: stackExtend grows the committed region ~1.5x" {
    var pool = PosixStackPool.init(testing.allocator, .{
        .maximum_size = 512 * 1024,
        .committed_size = 64 * 1024,
        .slab_stacks = 1,
    });
    defer pool.deinit();

    var info = try pool.acquire();
    defer pool.release(info, .zero);

    const initial_limit = info.limit;
    const initial_committed = info.base - info.limit;

    try stackExtend(&info, .grow);

    // Limit moved down and committed size grew by ~1.5x (≥1.4x after rounding).
    try testing.expect(info.limit < initial_limit);
    const new_committed = info.base - info.limit;
    try testing.expect(new_committed >= initial_committed * 14 / 10);

    // Extended region is writable.
    const extended: [*]u8 = @ptrFromInt(info.limit);
    @memset(extended[0..1024], 0xAA);
}
