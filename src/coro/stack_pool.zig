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

/// A node in the free list, stored at the base of an unused stack.
const FreeNode = struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
    stack_info: StackInfo,
    timestamp: Timestamp,
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
    carved: usize,
};

pub const Config = struct {
    /// Maximum size of stacks in this pool (in bytes).
    /// This is the total virtual address space reserved for each stack.
    maximum_size: usize,

    /// Initial committed size of stacks in this pool (in bytes).
    /// This is the amount of physical memory initially committed.
    committed_size: usize,

    /// Maximum number of unused stacks to keep in the pool.
    /// When this limit is exceeded, the oldest stack is freed.
    max_unused_stacks: usize = 16,

    /// Maximum age of an unused stack.
    /// Stacks older than this will be freed on the next release() call.
    /// .zero means no age limit.
    /// Only applies to individually mapped stacks; slab slots are never
    /// evicted or decommitted (recycling was measured too expensive).
    max_age: Duration = .zero,

    /// Number of slab slots to carve and commit up front (at runtime init),
    /// so that a burst of early spawns skips the cold-allocation cost.
    /// Ignored when slab allocation is compiled out.
    prewarm: usize = 0,
};

pub const StackPool = struct {
    config: Config,
    mutex: os.Mutex,
    head: ?*FreeNode,
    tail: ?*FreeNode,
    pool_size: usize,
    // Slab state: chain of arenas (newest first; only the newest still has
    // uncarved slots) and a LIFO of released slab slots. Slab slots bypass
    // the max_unused_stacks/max_age policy entirely: releasing one is a
    // pointer push, reusing one costs no syscalls, and the memory is only
    // returned at deinit.
    slabs: ?*Slab,
    arena_free: ?*FreeNode,
    slot_size: usize,

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
            .arena_free = null,
            .slot_size = @max(aligned_max + stack.page_size, stack.page_size * 2),
        };
    }

    pub fn deinit(self: *StackPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all stacks in the pool
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
        self.arena_free = null;
    }

    /// Acquires a stack from the pool, or allocates a new one if the pool is empty.
    /// All stacks from this pool have the configured maximum_size and committed_size.
    pub fn acquire(self: *StackPool) error{OutOfMemory}!StackInfo {
        // Try to get from pool under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (slab_enabled) {
                // Released slab slots first: LIFO, still committed, still
                // cache-warm, zero syscalls.
                if (self.arena_free) |node| {
                    self.arena_free = node.next;
                    return node.stack_info;
                }
            }

            if (self.head) |node| {
                const stack_info = node.stack_info;
                self.removeNode(node);
                return stack_info;
            }

            if (slab_enabled) {
                // Cold path: carve a fresh slot (one mprotect), creating a
                // new slab if the current one is exhausted. Done under the
                // lock — carving is rare and the bookkeeping needs it anyway.
                if (self.carveSlotLocked()) |stack_info| {
                    return stack_info;
                }
                // Slab reservation failed (address space exhausted?); fall
                // through to an individual mapping.
            }
        }

        // Pool was empty, allocate new stack outside the lock
        var stack_info: StackInfo = undefined;
        try stack.stackAlloc(&stack_info, self.config.maximum_size, self.config.committed_size);
        return stack_info;
    }

    /// Carve and commit the next slot out of the newest slab, growing the
    /// slab chain when needed. Returns null if reservation or commit fails
    /// (the caller falls back to individual mappings). Must run under mutex.
    fn carveSlotLocked(self: *StackPool) ?StackInfo {
        const slab = blk: {
            if (self.slabs) |s| {
                if (s.carved < slab_slots) break :blk s;
            }
            const len = stack.page_size + slab_slots * self.slot_size;
            const mem = stack.slabReserve(len) catch return null;
            const s: *Slab = @ptrCast(@alignCast(mem.ptr));
            s.* = .{ .next = self.slabs, .memory = mem, .carved = 0 };
            self.slabs = s;
            break :blk s;
        };

        const offset = stack.page_size + slab.carved * self.slot_size;
        const slot: []align(stack.page_size) u8 = @alignCast(slab.memory[offset .. offset + self.slot_size]);
        var stack_info: StackInfo = undefined;
        stack.stackInitSlot(&stack_info, slot, self.config.committed_size) catch return null;
        slab.carved += 1;
        return stack_info;
    }

    /// Whether this allocation is a slab slot. Must run under mutex (the
    /// slab chain is mutated by carveSlotLocked).
    fn inArenaLocked(self: *StackPool, ptr: [*]align(stack.page_size) u8) bool {
        const addr = @intFromPtr(ptr);
        var slab = self.slabs;
        while (slab) |s| : (slab = s.next) {
            const base = @intFromPtr(s.memory.ptr);
            if (addr >= base and addr < base + s.memory.len) return true;
        }
        return false;
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
            self.mutex.unlock();
            self.release(stack_info, .zero);
        }
    }

    /// Releases a stack back to the pool.
    /// Expired stacks are removed before adding the new stack to avoid depleting the pool.
    /// If the pool is full, frees the oldest stack and adds this one.
    /// If the stack's committed region is too small to store the FreeNode, the stack is freed instead.
    pub fn release(self: *StackPool, stack_info: StackInfo, timestamp: Timestamp) void {
        // Check if the stack has enough committed space to store the FreeNode
        // The FreeNode is stored at the base of the stack (aligned backward)
        const node_addr = std.mem.alignBackward(usize, stack_info.base - @sizeOf(FreeNode), @alignOf(FreeNode));

        if (slab_enabled) {
            self.mutex.lock();
            if (self.inArenaLocked(stack_info.allocation_ptr)) {
                // Slab slots always commit at least one page, so the node fits.
                std.debug.assert(node_addr >= stack_info.limit);
                const node: *FreeNode = @ptrFromInt(node_addr);
                node.* = .{
                    .prev = null,
                    .next = self.arena_free,
                    .stack_info = stack_info,
                    .timestamp = timestamp,
                };
                self.arena_free = node;
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
        }

        // Verify the FreeNode fits within the committed region (between limit and base)
        if (node_addr < stack_info.limit) {
            // Stack is too small to hold the FreeNode, free it instead of pooling
            stack.stackFree(stack_info);
            return;
        }

        // Recycle the stack memory (MADV_FREE on POSIX) - no lock needed
        // NOTE: this turns out to be tooo expensive to be worth it
        // stack.stackRecycle(stack_info);

        // Store the FreeNode at the base of the stack
        const node = @as(*FreeNode, @ptrFromInt(node_addr));
        node.* = .{
            .prev = null,
            .next = null,
            .stack_info = stack_info,
            .timestamp = timestamp,
        };

        // Collect stacks to free in a temporary singly-linked list
        // Limit how many we free per call to bound latency
        const max_free_per_release = 4;
        var to_free_head: ?*FreeNode = null;
        var to_free_count: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Remove expired stacks from the front of the list (up to limit)
            // Do this before adding the new stack to avoid the situation where we'd
            // remove all stacks (including the one we're about to add) and end up with an empty pool
            if (self.config.max_age.value > 0) {
                while (self.head) |expired| {
                    if (to_free_count >= max_free_per_release) break;
                    const age = expired.timestamp.durationTo(timestamp);
                    if (age.value > self.config.max_age.value) {
                        self.removeNode(expired);
                        expired.next = to_free_head;
                        to_free_head = expired;
                        to_free_count += 1;
                    } else {
                        // List is ordered by timestamp, so we can stop
                        break;
                    }
                }
            }

            // If pool is at capacity and under limit, remove the oldest stack
            if (self.pool_size >= self.config.max_unused_stacks and to_free_count < max_free_per_release) {
                if (self.head) |oldest| {
                    self.removeNode(oldest);
                    oldest.next = to_free_head;
                    to_free_head = oldest;
                    to_free_count += 1;
                }
            }

            // Add to the tail of the list (most recently released)
            self.addNode(node);
        }

        // Free collected stacks - no lock held
        while (to_free_head) |free_node| {
            const next = free_node.next;
            stack.stackFree(free_node.stack_info);
            to_free_head = next;
        }
    }

    /// Evicts up to `limit` expired stacks from the pool.
    /// Intended to be called periodically from a timer to reclaim idle stacks.
    pub fn cleanup(self: *StackPool, now: Timestamp, limit: usize) void {
        if (self.config.max_age.value == 0) return;

        var to_free_head: ?*FreeNode = null;
        var to_free_count: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head) |node| {
                if (to_free_count >= limit) break;
                const age = node.timestamp.durationTo(now);
                if (age.value > self.config.max_age.value) {
                    self.removeNode(node);
                    node.next = to_free_head;
                    to_free_head = node;
                    to_free_count += 1;
                } else {
                    break;
                }
            }
        }

        while (to_free_head) |free_node| {
            const next = free_node.next;
            stack.stackFree(free_node.stack_info);
            to_free_head = next;
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
        .max_unused_stacks = 4,
    });
    defer pool.deinit();

    // Acquire a stack
    const stack1 = try pool.acquire();
    try std.testing.expect(stack1.base != 0);
    try std.testing.expect(stack1.base > stack1.limit); // Stack grows downward

    // Release it back, acquire again - should reuse the same stack
    pool.release(stack1, .zero);
    const stack2 = try pool.acquire();
    try std.testing.expectEqual(stack1.base, stack2.base);

    // Return it so pool.deinit() reclaims it (slab slots must not be
    // stackFree'd individually).
    pool.release(stack2, .zero);
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
        try std.testing.expect(pool.inArenaLocked(info.allocation_ptr));
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

    // Release everything; re-acquire returns the same slots (LIFO) with no
    // new carving.
    for (infos) |info| pool.release(info, .zero);
    const carved_before = pool.slabs.?.carved;
    for (0..total) |_| {
        const info = try pool.acquire();
        pool.release(info, .zero);
    }
    try std.testing.expectEqual(carved_before, pool.slabs.?.carved);
}

test "StackPool slab: prewarm fills the arena freelist" {
    if (!slab_enabled) return error.SkipZigTest;

    var pool = StackPool.init(.{
        .maximum_size = 256 * 1024,
        .committed_size = 16 * 1024,
        .prewarm = 8,
    });
    defer pool.deinit();

    try pool.prewarm();
    try std.testing.expect(pool.arena_free != null);
    try std.testing.expectEqual(8, pool.slabs.?.carved);

    // Acquires are served from the prewarmed slots without carving more.
    const s1 = try pool.acquire();
    try std.testing.expectEqual(8, pool.slabs.?.carved);
    pool.release(s1, .zero);
}

test "StackPool respects max_unused_stacks" {
    // Policy applies to individually mapped stacks only.
    if (slab_enabled) return error.SkipZigTest;
    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .max_unused_stacks = 2,
    });
    defer pool.deinit();

    // Acquire and release 3 stacks
    const stack1 = try pool.acquire();
    const stack2 = try pool.acquire();
    const stack3 = try pool.acquire();

    pool.release(stack1, .zero);
    try std.testing.expectEqual(1, pool.pool_size);

    pool.release(stack2, .zero);
    try std.testing.expectEqual(2, pool.pool_size);

    // Releasing the third should evict the first (oldest)
    pool.release(stack3, .zero);
    try std.testing.expectEqual(2, pool.pool_size);

    // Verify that stack1 is not in the pool (stack2 and stack3 should be)
    const reused1 = try pool.acquire();
    const reused2 = try pool.acquire();

    try std.testing.expect(reused1.base == stack2.base or reused1.base == stack3.base);
    try std.testing.expect(reused2.base == stack2.base or reused2.base == stack3.base);
    try std.testing.expect(reused1.base != reused2.base);

    // Clean up
    stack.stackFree(reused1);
    stack.stackFree(reused2);
}

test "StackPool age-based expiration" {
    // Policy applies to individually mapped stacks only.
    if (slab_enabled) return error.SkipZigTest;

    const max_age: Duration = .fromMilliseconds(100);

    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .max_unused_stacks = 4,
        .max_age = max_age,
    });
    defer pool.deinit();

    // Acquire and release a stack at timestamp 0
    const stack1 = try pool.acquire();
    pool.release(stack1, .zero);
    try std.testing.expectEqual(1, pool.pool_size);

    // Acquire a new stack and release it with timestamp past expiration
    // This triggers expiration check and should evict stack1
    const stack2 = try pool.acquire();
    try std.testing.expectEqual(0, pool.pool_size);
    pool.release(stack2, .fromMilliseconds(101));
    try std.testing.expectEqual(1, pool.pool_size);

    // Verify the pool contains stack2 (stack1 was expired)
    const reused = try pool.acquire();
    try std.testing.expectEqual(stack2.base, reused.base);

    // Clean up
    stack.stackFree(reused);
}
