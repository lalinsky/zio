// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const zio_options = @import("zio_options");
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

/// Number of stack slots carved from one slab reservation (build option
/// `stack-slab-slots`; 0 disables slab allocation and every stack gets its
/// own mapping as before).
pub const slab_slots: usize = zio_options.stack_slab_slots;

/// Slab allocation reserves slab_slots * (maximum_size + guard) of address
/// space per slab, which is only affordable on 64-bit targets. Windows keeps
/// RtlCreateUserStack (TEB integration), and OpenBSD requires MAP_STACK
/// mappings that cannot start as PROT_NONE reservations.
pub const slab_enabled = slab_slots > 0 and @sizeOf(usize) == 8 and switch (builtin.os.tag) {
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
    /// The pool tracks a demand watermark: the peak number of stacks
    /// simultaneously in use since the previous evaluation (but never below
    /// `prewarm`). On each evaluation, free capacity beyond that watermark is
    /// returned to the OS: whole slabs whose every slot is unused are
    /// unmapped first, then individually mapped stacks, oldest first.
    /// Between evaluations, releasing and reusing stacks never makes a
    /// syscall. `.zero` disables shrinking entirely; the pool then holds its
    /// high-water mark until deinit.
    shrink_interval: Duration = .fromSeconds(60),

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
    /// Slab chain, newest first. Acquire prefers the first slab with a free
    /// slot, so load concentrates at the head and older slabs drain toward
    /// empty, where the shrink pass can unmap them wholesale.
    slabs: ?*Slab,
    slot_size: usize,
    /// Stacks currently acquired (both kinds).
    in_use: usize,
    /// Peak of `in_use` since the last shrink evaluation: the demand
    /// watermark that decides how much free capacity the next evaluation
    /// keeps.
    epoch_peak: usize,
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
            .slot_size = @max(aligned_max + stack.page_size, stack.page_size * 2),
            .in_use = 0,
            .epoch_peak = 0,
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
        var slab = self.slabs;
        while (slab) |s| {
            const next = s.next;
            stack.slabFree(s.memory);
            slab = next;
        }
        self.slabs = null;
    }

    /// Acquires a stack from the pool, or allocates a new one if the pool is empty.
    /// All stacks from this pool have the configured maximum_size and committed_size.
    pub fn acquire(self: *StackPool) error{OutOfMemory}!StackInfo {
        // Try to get from pool under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (slab_enabled) {
                // Released slab slots first: still committed, still
                // cache-warm, zero syscalls. First slab with a free slot
                // wins, concentrating load near the head of the chain.
                var slab = self.slabs;
                while (slab) |s| : (slab = s.next) {
                    if (s.free) |node| {
                        s.free = node.next;
                        s.in_use += 1;
                        self.noteAcquireLocked();
                        return node.stack_info;
                    }
                }
            }

            if (self.head) |node| {
                const stack_info = node.stack_info;
                self.removeNode(node);
                self.noteAcquireLocked();
                return stack_info;
            }

            if (slab_enabled) {
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

        self.mutex.lock();

        if (slab_enabled) {
            if (self.slabOfLocked(stack_info.allocation_ptr)) |slab| {
                // Slab slots always commit at least one page, so the node fits.
                std.debug.assert(node_addr >= stack_info.limit);
                const node: *FreeNode = @ptrFromInt(node_addr);
                node.* = .{
                    .prev = null,
                    .next = slab.free,
                    .stack_info = stack_info,
                };
                slab.free = node;
                slab.in_use -= 1;
                self.in_use -= 1;
                self.mutex.unlock();
                return;
            }
        }

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

    /// Bound on individually mapped stacks freed per shrink pass, so a pass
    /// after a large burst does not stall an executor on thousands of
    /// munmaps. Whole-slab frees are not bounded; there are few slabs and
    /// each unmap retires many slots at once.
    const max_stack_frees_per_shrink = 64;

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

            if (self.last_shrink.value != 0 and
                self.last_shrink.durationTo(now).value < self.config.shrink_interval.value)
            {
                return;
            }
            self.last_shrink = now;

            const floor = @max(self.epoch_peak, if (slab_enabled) self.config.prewarm else 0);
            self.epoch_peak = self.in_use;

            // Committed capacity = live stacks + everything parked on free
            // lists. Anything beyond the watermark is up for release.
            var free_capacity: usize = self.pool_size;
            var slab = self.slabs;
            while (slab) |s| : (slab = s.next) {
                free_capacity += s.carved - s.in_use;
            }
            var excess = (self.in_use + free_capacity) -| floor;

            // Unmap empty slabs first: one syscall retires a whole arena.
            // Strictly within the excess, so capacity never dips below the
            // watermark (a mostly-empty slab bigger than the excess stays).
            if (slab_enabled) {
                var prev: ?*Slab = null;
                var cur = self.slabs;
                while (cur) |s| {
                    const next = s.next;
                    if (s.in_use == 0 and s.carved <= excess) {
                        if (prev) |p| p.next = next else self.slabs = next;
                        excess -= s.carved;
                        s.next = slabs_to_free;
                        slabs_to_free = s;
                    } else {
                        prev = s;
                    }
                    cur = next;
                }
            }

            // Then individually mapped stacks, oldest first.
            var freed: usize = 0;
            while (excess > 0 and freed < max_stack_frees_per_shrink) {
                const node = self.head orelse break;
                self.removeNode(node);
                node.next = stacks_to_free;
                stacks_to_free = node;
                excess -= 1;
                freed += 1;
            }
        }

        // Return memory to the OS outside the lock.
        while (slabs_to_free) |s| {
            const next = s.next;
            stack.slabFree(s.memory);
            slabs_to_free = next;
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
                if (s.carved < slab_slots) break :blk s;
            }
            const len = stack.page_size + slab_slots * self.slot_size;
            const mem = stack.slabReserve(len) catch return null;
            const s: *Slab = @ptrCast(@alignCast(mem.ptr));
            s.* = .{ .next = self.slabs, .memory = mem, .carved = 0, .in_use = 0, .free = null };
            self.slabs = s;
            break :blk s;
        };

        const offset = stack.page_size + slab.carved * self.slot_size;
        const slot: []align(stack.page_size) u8 = @alignCast(slab.memory[offset .. offset + self.slot_size]);
        var stack_info: StackInfo = undefined;
        stack.stackInitSlot(&stack_info, slot, self.config.committed_size) catch return null;
        slab.carved += 1;
        slab.in_use += 1;
        return stack_info;
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
        if (!slab_enabled) return;

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
    if (!slab_enabled) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
    });
    defer pool.deinit();

    // Acquire more slots than one slab holds to force a second slab.
    const total = slab_slots + 2;
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

test "StackPool slab: shrink unmaps empty slabs beyond the watermark" {
    if (!slab_enabled) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .shrink_interval = .fromSeconds(1),
    });
    defer pool.deinit();

    // Two slabs' worth of concurrent stacks, then all released.
    const total = slab_slots + 2;
    const infos = try std.testing.allocator.alloc(StackInfo, total);
    defer std.testing.allocator.free(infos);
    for (infos) |*info| info.* = try pool.acquire();
    for (infos) |info| pool.release(info);

    // First pass: the epoch peak still covers the burst, nothing is freed.
    pool.shrink(.fromSeconds(10));
    try std.testing.expect(pool.slabs != null);
    try std.testing.expect(pool.slabs.?.next != null);

    // Second pass: peak has decayed to the current demand (zero), so every
    // empty slab goes back to the OS.
    pool.shrink(.fromSeconds(20));
    try std.testing.expect(pool.slabs == null);

    // A pass inside the rate-limit window is a no-op even with demand at
    // zero (nothing left to free here, but the guard must hold).
    pool.shrink(.fromSeconds(20));
}

test "StackPool slab: watermark keeps capacity for live stacks" {
    if (!slab_enabled) return error.SkipZigTest;

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
    if (!slab_enabled) return error.SkipZigTest;

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
    // The individually-mapped path backs every stack when slabs are
    // compiled out; with slabs enabled it only serves failure fallbacks, so
    // exercise it directly here.
    if (slab_enabled) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .shrink_interval = .fromSeconds(1),
    });
    defer pool.deinit();

    const stack1 = try pool.acquire();
    const stack2 = try pool.acquire();
    const stack3 = try pool.acquire();
    pool.release(stack1);
    pool.release(stack2);
    pool.release(stack3);
    try std.testing.expectEqual(3, pool.pool_size);

    // Peak covers the burst on the first pass; decays on the second.
    pool.shrink(.fromSeconds(10));
    try std.testing.expectEqual(3, pool.pool_size);
    pool.shrink(.fromSeconds(20));
    try std.testing.expectEqual(0, pool.pool_size);
}
