// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const stack = @import("stack.zig");
const StackInfo = stack.StackInfo;
const Timestamp = @import("../time.zig").Timestamp;
const Duration = @import("../time.zig").Duration;
const os = @import("../os/root.zig");

/// A node in a free list, stored at the base of an unused stack.
const FreeNode = struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
    stack_info: StackInfo,
};

/// Whether this target can back stacks with slab reservations. Slabs reserve
/// slab_slots * (maximum_size + guard) of address space each, which is only
/// affordable on 64-bit targets. Windows keeps RtlCreateUserStack (TEB
/// integration), and OpenBSD requires MAP_STACK mappings that cannot start
/// as PROT_NONE reservations. Whether slabs are actually used is a runtime
/// choice (Config.slab_slots).
pub const slab_supported = @sizeOf(usize) == 8 and switch (builtin.os.tag) {
    .windows, .openbsd, .freestanding, .wasi => false,
    else => true,
};

/// Slab header, stored in the committed first page of the arena itself.
/// Slots follow the header page back to back; each slot's first page is
/// never committed and acts as its guard page, exactly mirroring the layout
/// of a standalone stack mapping.
const Slab = struct {
    next: ?*Slab,
    memory: []align(stack.page_size) u8,
    /// Slots handed out at least once. Only the newest slab still carves.
    carved: usize,
    /// Slots currently acquired by live coroutines.
    in_use: usize,
    /// Released slots of this slab (LIFO). carved - in_use entries.
    free: ?*FreeNode,
    /// Links in the pool's partial list: the slabs with at least one free
    /// slot, so acquire finds one in O(1) instead of scanning the chain.
    /// A slab is linked exactly when `free != null`.
    partial_prev: ?*Slab,
    partial_next: ?*Slab,
};

pub const Config = struct {
    /// Maximum size of stacks in this pool (in bytes).
    /// This is the total virtual address space reserved for each stack.
    maximum_size: usize,

    /// Initial committed size of stacks in this pool (in bytes).
    /// This is the amount of physical memory initially committed.
    committed_size: usize,

    /// How often the pool re-evaluates its size against recent demand.
    ///
    /// The pool keeps a retain target that follows demand with a decay
    /// curve: every interval it becomes the larger of the peak number of
    /// stacks simultaneously in use since the previous evaluation and half
    /// of the previous target (but never below `prewarm`). Free capacity
    /// beyond the target is returned to the OS: whole slabs whose every
    /// slot is unused are unmapped first (a bounded number per pass), then
    /// individually mapped stacks, oldest first. A burst therefore
    /// re-inflates the target instantly, while its capacity drains with a
    /// half-life of one interval instead of falling off a cliff. Between
    /// evaluations, releasing and reusing stacks never makes a syscall.
    /// `.zero` disables shrinking entirely; the pool then holds its
    /// high-water mark until deinit.
    shrink_interval: Duration = .fromSeconds(60),

    /// Number of stack slots carved from one slab reservation. 0 disables
    /// slab allocation and every stack gets its own mapping; ignored on
    /// targets without slab support (see slab_supported).
    slab_slots: usize = 64,

    /// Number of slab slots to carve and commit up front (at runtime init),
    /// so that a burst of early spawns skips the cold-allocation cost. Also
    /// acts as the floor for the demand watermark, so prewarmed capacity is
    /// never shrunk away. Ignored when slab allocation is compiled out.
    prewarm: usize = 0,
};

pub const StackPool = struct {
    config: Config,
    mutex: os.Mutex,
    /// Individually mapped stacks (fallback path): doubly linked, oldest at
    /// the head, so shrinking frees the longest-idle ones first.
    head: ?*FreeNode,
    tail: ?*FreeNode,
    pool_size: usize,
    /// Slab chain, newest first: every slab, walked only by carving (head
    /// slab), the shrink pass, and deinit.
    slabs: ?*Slab,
    /// Head of the partial list: slabs with free slots, most recently
    /// released-to first. Acquire pops here in O(1); the LIFO order keeps
    /// load concentrated on recently active slabs, so the rest drain toward
    /// empty, where the shrink pass can unmap them wholesale.
    partial: ?*Slab,
    slot_size: usize,
    /// Stacks currently acquired (both kinds).
    in_use: usize,
    /// Peak of `in_use` since the last shrink evaluation.
    epoch_peak: usize,
    /// The decayed demand watermark: how much total capacity the shrink
    /// pass keeps. Ratchets up to every epoch's peak instantly and halves
    /// per interval on the way down (see Config.shrink_interval).
    retain_target: usize,
    last_shrink: Timestamp,

    pub fn init(config: Config) StackPool {
        // Same slot layout as stackAllocPosix: usable size rounded to pages,
        // plus the (never committed) guard page, at least two pages total.
        const aligned_max = std.mem.alignForward(usize, config.maximum_size, stack.page_size);
        return .{
            .config = config,
            .mutex = .init(),
            .head = null,
            .tail = null,
            .pool_size = 0,
            .slabs = null,
            .partial = null,
            .slot_size = @max(aligned_max + stack.page_size, stack.page_size * 2),
            .in_use = 0,
            .epoch_peak = 0,
            .retain_target = 0,
            .last_shrink = .zero,
        };
    }

    pub fn deinit(self: *StackPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all individually mapped stacks in the pool
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            stack.stackFree(node.stack_info);
            current = next;
        }

        self.head = null;
        self.tail = null;
        self.pool_size = 0;

        // Free whole slab arenas; their FreeNodes and headers live inside.
        if (slab_supported) {
            var slab = self.slabs;
            while (slab) |s| {
                const next = s.next;
                stack.slabFree(s.memory);
                slab = next;
            }
            self.slabs = null;
            self.partial = null;
        }
    }

    /// Acquires a stack from the pool, or allocates a new one if the pool is empty.
    /// All stacks from this pool have the configured maximum_size and committed_size.
    pub fn acquire(self: *StackPool) error{OutOfMemory}!StackInfo {
        // Try to get from pool under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (slab_supported) {
                // Released slab slots first: still committed, still
                // cache-warm, zero syscalls. The partial list's head has one
                // by definition.
                if (self.partial) |s| {
                    const node = s.free.?;
                    s.free = node.next;
                    if (s.free == null) self.unlinkPartial(s);
                    s.in_use += 1;
                    self.noteAcquireLocked();
                    return node.stack_info;
                }
            }

            if (self.head) |node| {
                const stack_info = node.stack_info;
                self.removeNode(node);
                self.noteAcquireLocked();
                return stack_info;
            }

            if (slab_supported and self.config.slab_slots > 0) {
                // Cold path: carve a fresh slot (one mprotect), creating a
                // new slab if the current one is exhausted. Done under the
                // lock — carving is rare and the bookkeeping needs it anyway.
                if (self.carveSlotLocked()) |stack_info| {
                    self.noteAcquireLocked();
                    return stack_info;
                }
                // Slab reservation failed (address space exhausted?); fall
                // through to an individual mapping.
            }
        }

        // Pool was empty, allocate new stack outside the lock
        var stack_info: StackInfo = undefined;
        try stack.stackAlloc(&stack_info, self.config.maximum_size, self.config.committed_size);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.noteAcquireLocked();
        return stack_info;
    }

    fn noteAcquireLocked(self: *StackPool) void {
        self.in_use += 1;
        self.epoch_peak = @max(self.epoch_peak, self.in_use);
    }

    /// Releases a stack back to the pool. Never makes a syscall: slab slots
    /// are pushed onto their slab's free list and individually mapped stacks
    /// onto the pool's list. Returning memory to the OS happens only in the
    /// periodic shrink pass.
    pub fn release(self: *StackPool, stack_info: StackInfo) void {
        // The FreeNode is stored at the base of the stack (aligned backward)
        const node_addr = std.mem.alignBackward(usize, stack_info.base - @sizeOf(FreeNode), @alignOf(FreeNode));

        if (slab_supported) {
            // The owner tag at the top of the stack names the slab this slot
            // was carved from (0 for an individually mapped stack): one read
            // instead of scanning the slab chain.
            const tag = stack.stackReadOwnerTag(stack_info);
            if (tag != 0) {
                const slab: *Slab = @ptrFromInt(tag);
                // Stack overflow into the tag word is impossible (it sits
                // above base), but cheap paranoia in safe builds: the slab
                // must contain this slot.
                self.mutex.lock();
                if (builtin.mode == .debug) {
                    std.debug.assert(self.slabOfLocked(stack_info.allocation_ptr) == slab);
                }
                // Slab slots always commit at least one page, so the node fits.
                std.debug.assert(node_addr >= stack_info.limit);
                const node: *FreeNode = @ptrFromInt(node_addr);
                node.* = .{
                    .prev = null,
                    .next = slab.free,
                    .stack_info = stack_info,
                };
                if (slab.free == null) self.linkPartial(slab);
                slab.free = node;
                slab.in_use -= 1;
                self.in_use -= 1;
                self.mutex.unlock();
                return;
            }
        }

        self.mutex.lock();
        self.in_use -= 1;

        // Verify the FreeNode fits within the committed region (between limit and base)
        if (node_addr < stack_info.limit) {
            // Stack is too small to hold the FreeNode, free it instead of pooling
            self.mutex.unlock();
            stack.stackFree(stack_info);
            return;
        }

        const node: *FreeNode = @ptrFromInt(node_addr);
        node.* = .{
            .prev = null,
            .next = null,
            .stack_info = stack_info,
        };
        self.addNode(node);
        self.mutex.unlock();
    }

    /// Periodic shrink pass: rate-limited to `shrink_interval` internally,
    /// so any executor's timer may drive it. Frees the committed capacity
    /// that the demand watermark says was not needed since the previous
    /// pass; see Config.shrink_interval.
    pub fn shrink(self: *StackPool, now: Timestamp) void {
        if (self.config.shrink_interval.value == 0) return;

        var slabs_to_free: ?*Slab = null;
        var stacks_to_free: ?*FreeNode = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // durationTo saturates to zero when `now` lags behind
            // last_shrink (timestamps come from different loops' caches, and
            // a loop's cached now can be stale), so a backwards timestamp
            // lands in this early return and skips the pass: staleness can
            // only delay shrinking, never speed it up.
            if (self.last_shrink.value != 0 and
                self.last_shrink.durationTo(now).value < self.config.shrink_interval.value)
            {
                return;
            }
            self.last_shrink = now;

            // Decay curve: ratchet up to this epoch's peak immediately, halve
            // per interval on the way down, never below the prewarm floor. A
            // burst's capacity drains with a half-life of one interval
            // instead of vanishing the moment one quiet epoch passes.
            self.retain_target = @max(
                @max(self.epoch_peak, self.retain_target / 2),
                if (slab_supported) self.config.prewarm else 0,
            );
            self.epoch_peak = self.in_use;

            // Committed capacity = live stacks + everything parked on free
            // lists. Anything beyond the retain target is up for release.
            var free_capacity: usize = self.pool_size;
            var slab_count: usize = 0;
            var slab = self.slabs;
            while (slab) |s| : (slab = s.next) {
                free_capacity += s.carved - s.in_use;
                slab_count += 1;
            }
            var excess = (self.in_use + free_capacity) -| self.retain_target;

            // Per-pass work bounds are relative (half of what is currently
            // there, rounded up), matching the decay curve's own shape: the
            // worst pass after a burst scales with the burst, halves every
            // interval after that, and never turns the exponential drain
            // into a linear one the way an absolute cap would.
            var slab_budget = (slab_count + 1) / 2;
            var stack_budget = (self.pool_size + 1) / 2;

            // Unmap empty slabs first: one syscall retires a whole arena.
            // Strictly within the excess, so capacity never dips below the
            // target (a mostly-empty slab bigger than the excess stays).
            if (slab_supported) {
                var prev: ?*Slab = null;
                var cur = self.slabs;
                while (cur) |s| {
                    const next = s.next;
                    if (s.in_use == 0 and s.carved <= excess and slab_budget > 0) {
                        if (prev) |p| p.next = next else self.slabs = next;
                        if (s.free != null) self.unlinkPartial(s);
                        excess -= s.carved;
                        slab_budget -= 1;
                        s.next = slabs_to_free;
                        slabs_to_free = s;
                    } else {
                        prev = s;
                    }
                    cur = next;
                }
            }

            // Then individually mapped stacks, oldest first.
            while (excess > 0 and stack_budget > 0) {
                const node = self.head orelse break;
                self.removeNode(node);
                node.next = stacks_to_free;
                stacks_to_free = node;
                excess -= 1;
                stack_budget -= 1;
            }
        }

        // Return memory to the OS outside the lock.
        if (slab_supported) {
            while (slabs_to_free) |s| {
                const next = s.next;
                stack.slabFree(s.memory);
                slabs_to_free = next;
            }
        }
        while (stacks_to_free) |node| {
            const next = node.next;
            stack.stackFree(node.stack_info);
            stacks_to_free = next;
        }
    }

    /// Carve and commit the next slot out of the newest slab, growing the
    /// slab chain when needed. Returns null if reservation or commit fails
    /// (the caller falls back to individual mappings). Must run under mutex.
    /// The new slot is counted as in use on its slab; the caller accounts
    /// the pool-wide acquire.
    fn carveSlotLocked(self: *StackPool) ?StackInfo {
        const slab = blk: {
            if (self.slabs) |s| {
                if (s.carved < self.config.slab_slots) break :blk s;
            }
            const len = stack.page_size + self.config.slab_slots * self.slot_size;
            const mem = stack.slabReserve(len) catch return null;
            const s: *Slab = @ptrCast(@alignCast(mem.ptr));
            s.* = .{ .next = self.slabs, .memory = mem, .carved = 0, .in_use = 0, .free = null, .partial_prev = null, .partial_next = null };
            self.slabs = s;
            break :blk s;
        };

        const offset = stack.page_size + slab.carved * self.slot_size;
        const slot: []align(stack.page_size) u8 = @alignCast(slab.memory[offset .. offset + self.slot_size]);
        var stack_info: StackInfo = undefined;
        stack.stackInitSlot(&stack_info, slot, self.config.committed_size, @intFromPtr(slab)) catch return null;
        slab.carved += 1;
        slab.in_use += 1;
        return stack_info;
    }

    /// Link a slab at the head of the partial list. Must run under mutex.
    fn linkPartial(self: *StackPool, s: *Slab) void {
        std.debug.assert(s.partial_prev == null and s.partial_next == null and self.partial != s);
        s.partial_next = self.partial;
        if (self.partial) |head| head.partial_prev = s;
        self.partial = s;
    }

    /// Unlink a slab from the partial list. Must run under mutex.
    fn unlinkPartial(self: *StackPool, s: *Slab) void {
        if (s.partial_prev) |prev| prev.partial_next = s.partial_next else self.partial = s.partial_next;
        if (s.partial_next) |next| next.partial_prev = s.partial_prev;
        s.partial_prev = null;
        s.partial_next = null;
    }

    /// The slab this allocation was carved from, or null for an individually
    /// mapped stack. Must run under mutex (the chain is mutated by carving
    /// and shrinking).
    fn slabOfLocked(self: *StackPool, ptr: [*]align(stack.page_size) u8) ?*Slab {
        const addr = @intFromPtr(ptr);
        var slab = self.slabs;
        while (slab) |s| : (slab = s.next) {
            const base = @intFromPtr(s.memory.ptr);
            if (addr >= base and addr < base + s.memory.len) return s;
        }
        return null;
    }

    /// Carve and commit `config.prewarm` slots up front. Called once from
    /// runtime init so that an early spawn burst finds warm slots instead of
    /// paying the cold-allocation cost inside the workload.
    pub fn prewarm(self: *StackPool) error{OutOfMemory}!void {
        if (!slab_supported or self.config.slab_slots == 0) return;

        var i: usize = 0;
        while (i < self.config.prewarm) : (i += 1) {
            self.mutex.lock();
            const stack_info = self.carveSlotLocked() orelse {
                self.mutex.unlock();
                return error.OutOfMemory;
            };
            self.in_use += 1;
            self.mutex.unlock();
            self.release(stack_info);
        }
    }

    /// Removes a node from the doubly linked list and updates pool_size.
    fn removeNode(self: *StackPool, node: *FreeNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            // This is the head
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            // This is the tail
            self.tail = node.prev;
        }

        self.pool_size -= 1;
    }

    /// Adds a node to the tail of the doubly linked list and updates pool_size.
    fn addNode(self: *StackPool, node: *FreeNode) void {
        node.prev = self.tail;
        node.next = null;

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            // List is empty
            self.head = node;
        }

        self.tail = node;
        self.pool_size += 1;
    }
};

test "StackPool basic acquire and release" {
    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
    });
    defer pool.deinit();

    // Acquire a stack
    const stack1 = try pool.acquire();
    try std.testing.expect(stack1.base != 0);
    try std.testing.expect(stack1.base > stack1.limit); // Stack grows downward
    try std.testing.expectEqual(1, pool.in_use);

    // Release it back, acquire again - should reuse the same stack
    pool.release(stack1);
    try std.testing.expectEqual(0, pool.in_use);
    const stack2 = try pool.acquire();
    try std.testing.expectEqual(stack1.base, stack2.base);

    // Return it so pool.deinit() reclaims it (slab slots must not be
    // stackFree'd individually).
    pool.release(stack2);
}

test "StackPool slab: carving spans slabs and slots are distinct" {
    if (!slab_supported) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
    });
    defer pool.deinit();

    // Acquire more slots than one slab holds to force a second slab.
    const total = pool.config.slab_slots + 2;
    const infos = try std.testing.allocator.alloc(StackInfo, total);
    defer std.testing.allocator.free(infos);

    for (infos) |*info| {
        info.* = try pool.acquire();
        // Every slot must be arena-backed while slabs have room.
        pool.mutex.lock();
        defer pool.mutex.unlock();
        try std.testing.expect(pool.slabOfLocked(info.allocation_ptr) != null);
    }

    // All distinct, all writable at base, guard layout intact.
    for (infos, 0..) |a, i| {
        for (infos[i + 1 ..]) |b| {
            try std.testing.expect(a.allocation_ptr != b.allocation_ptr);
        }
        const mem: [*]u8 = @ptrFromInt(a.limit);
        mem[0] = 0xAA;
        mem[a.base - a.limit - 1] = 0xBB;
    }

    // Two slabs exist now.
    try std.testing.expect(pool.slabs != null);
    try std.testing.expect(pool.slabs.?.next != null);

    // Release everything; re-acquire returns slab slots with no new carving.
    for (infos) |info| pool.release(info);
    const carved_before = pool.slabs.?.carved;
    for (0..total) |_| {
        const info = try pool.acquire();
        pool.release(info);
    }
    try std.testing.expectEqual(carved_before, pool.slabs.?.carved);
}

test "StackPool slab: releases route acquires to their slab via the partial list" {
    if (!slab_supported) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
    });
    defer pool.deinit();

    // Fill two slabs; infos[0] was carved from the older slab.
    const total = pool.config.slab_slots + 2;
    const infos = try std.testing.allocator.alloc(StackInfo, total);
    defer std.testing.allocator.free(infos);
    for (infos) |*info| info.* = try pool.acquire();

    // Release a single slot from the older slab: its slab becomes the
    // partial head, and the next acquire must return exactly that slot,
    // without scanning or carving.
    pool.release(infos[0]);
    const reused = try pool.acquire();
    try std.testing.expectEqual(infos[0].allocation_ptr, reused.allocation_ptr);
    infos[0] = reused;

    for (infos) |info| pool.release(info);
}

test "StackPool slab: shrink unmaps empty slabs beyond the watermark" {
    if (!slab_supported) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .shrink_interval = .fromSeconds(1),
    });
    defer pool.deinit();

    // Two slabs' worth of concurrent stacks, then all released.
    const total = pool.config.slab_slots + 2;
    const infos = try std.testing.allocator.alloc(StackInfo, total);
    defer std.testing.allocator.free(infos);
    for (infos) |*info| info.* = try pool.acquire();
    for (infos) |info| pool.release(info);

    // First pass: the epoch peak still covers the burst, nothing is freed.
    pool.shrink(.fromSeconds(10));
    try std.testing.expect(pool.slabs != null);
    try std.testing.expect(pool.slabs.?.next != null);

    // Second pass: the retain target halves, which releases the small
    // second slab but keeps the full one (its carved count exceeds the
    // excess) - the decay curve, not a cliff.
    pool.shrink(.fromSeconds(20));
    try std.testing.expect(pool.slabs != null);
    try std.testing.expect(pool.slabs.?.next == null);

    // A pass inside the rate-limit window is a no-op.
    pool.shrink(.fromSeconds(20));
    try std.testing.expect(pool.slabs != null);

    // With demand at zero the target halves each interval and reaches zero,
    // at which point the last slab goes back to the OS too.
    var t: u64 = 30;
    var passes: usize = 0;
    while (pool.slabs != null and passes < 16) : ({
        t += 10;
        passes += 1;
    }) {
        pool.shrink(.fromSeconds(t));
    }
    try std.testing.expect(pool.slabs == null);
}

test "StackPool slab: watermark keeps capacity for live stacks" {
    if (!slab_supported) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .shrink_interval = .fromSeconds(1),
    });
    defer pool.deinit();

    // Keep one stack live; burst and release the rest of the slab.
    const held = try pool.acquire();
    const burst = try std.testing.allocator.alloc(StackInfo, 8);
    defer std.testing.allocator.free(burst);
    for (burst) |*info| info.* = try pool.acquire();
    for (burst) |info| pool.release(info);

    // Two decayed passes: the slab holds a live slot, so it must survive.
    pool.shrink(.fromSeconds(10));
    pool.shrink(.fromSeconds(20));
    pool.shrink(.fromSeconds(30));
    try std.testing.expect(pool.slabs != null);
    try std.testing.expectEqual(1, pool.in_use);

    pool.release(held);
}

test "StackPool slab: prewarm fills the freelist and floors the watermark" {
    if (!slab_supported) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .shrink_interval = .fromSeconds(1),
        .prewarm = 8,
    });
    defer pool.deinit();

    try pool.prewarm();
    try std.testing.expect(pool.slabs != null);
    try std.testing.expectEqual(8, pool.slabs.?.carved);
    try std.testing.expectEqual(0, pool.in_use);

    // Acquires are served from the prewarmed slots without carving more.
    const s1 = try pool.acquire();
    try std.testing.expectEqual(8, pool.slabs.?.carved);
    pool.release(s1);

    // The prewarm floor keeps the slab alive through decayed shrink passes.
    pool.shrink(.fromSeconds(10));
    pool.shrink(.fromSeconds(20));
    pool.shrink(.fromSeconds(30));
    try std.testing.expect(pool.slabs != null);
}

test "StackPool fallback: shrink frees idle stacks beyond the watermark" {
    // Disable slabs so the individually-mapped path backs every stack; on
    // targets without slab support this is the only path anyway.
    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .shrink_interval = .fromSeconds(1),
        .slab_slots = 0,
    });
    defer pool.deinit();

    const stack1 = try pool.acquire();
    const stack2 = try pool.acquire();
    const stack3 = try pool.acquire();
    pool.release(stack1);
    pool.release(stack2);
    pool.release(stack3);
    try std.testing.expectEqual(3, pool.pool_size);

    // Peak covers the burst on the first pass; then the target halves per
    // interval (3 -> 1 -> 0), draining the pool over two more passes.
    pool.shrink(.fromSeconds(10));
    try std.testing.expectEqual(3, pool.pool_size);
    pool.shrink(.fromSeconds(20));
    try std.testing.expectEqual(1, pool.pool_size);
    pool.shrink(.fromSeconds(30));
    try std.testing.expectEqual(0, pool.pool_size);
}
