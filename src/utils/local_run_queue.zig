// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Per-executor local run queue: a bounded ring buffer, modeled on Go's `runq`
//! (src/runtime/proc.go) and Tokio's multi-thread local queue.
//!
//! FIFO: the owner pushes to the tail and pops from the head; stealers take half
//! from the head (phase 2). Because it's a fixed array of task pointers, push and
//! pop are just index moves — no per-task atomic on an intrusive `next`, and the
//! FIFO order avoids the LIFO "a yielder jumps ahead of ready tasks" unfairness a
//! stack has.
//!
//! When the ring is full, half of it plus the new task spill to an `OverflowQueue`
//! (Go's `runqputslow` → global queue). Which overflow queue is chosen by the
//! `enable_task_migration` flag, via the `overflow` pointer set at init:
//!   * migration on  -> the shared runtime global queue (load-balanced across all).
//!   * migration off -> this executor's own queue (tasks never leave home).
//!
//! Concurrency (stealable queues): `head` is CAS'd by the owner pop and (phase 2)
//! stealers; `tail` is written only by the owning thread (store-release) and read
//! plain by the owner, acquire by stealers. When the queue is built non-stealable
//! (task migration compiled out) it is single-owner, so the cursors are plain and
//! `steal` is a compile error. `T` must have a `next: ?*T` field (for the overflow
//! list) and, in debug, `in_list: bool` (managed by the overflow queue, not ring).

const std = @import("std");
const builtin = @import("builtin");
const SimpleQueue = @import("simple_queue.zig").SimpleQueue;
const OsMutex = @import("../os/thread.zig").Mutex;

/// Thread-safe FIFO overflow queue: a mutex-guarded intrusive list plus an atomic
/// length so the drain fast-path can skip the lock when empty. `count` is mutated
/// only while holding the mutex, so it always equals the queue length whenever the
/// lock is free; lock-free readers (isEmpty/len) may see a momentarily stale value
/// but never one that lets a drainer's fetchSub underflow.
pub fn OverflowQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        queue: SimpleQueue(T) = .empty,
        mutex: OsMutex = .init(),
        count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Push a single task (cross-thread wake). Thread-safe.
        pub fn push(self: *Self, node: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.push(node);
            _ = self.count.fetchAdd(1, .release);
        }

        /// Push a batch (ring overflow) under one lock acquisition.
        pub fn pushSlice(self: *Self, nodes: []*T) void {
            if (nodes.len == 0) return;
            self.mutex.lock();
            defer self.mutex.unlock();
            for (nodes) |n| self.queue.push(n);
            _ = self.count.fetchAdd(nodes.len, .release);
        }

        /// Pop up to `out.len` tasks into `out`; returns how many were taken.
        pub fn popBatch(self: *Self, out: []*T) usize {
            if (self.count.load(.acquire) == 0) return 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                out[i] = self.queue.pop() orelse break;
            }
            if (i > 0) _ = self.count.fetchSub(i, .release);
            return i;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count.load(.acquire) == 0;
        }

        pub fn len(self: *const Self) usize {
            return self.count.load(.acquire);
        }
    };
}

/// `stealable` selects the concurrency model:
///   * true  -> another thread (a phase-2 thief) may race the owner on the ring,
///              so the cursors are touched through atomic builtins.
///   * false -> the ring is owned by a single thread (task migration compiled
///              out), so the cursors are plain scalars and no atomics are emitted;
///              `steal` becomes a compile error since it can never be called.
pub fn LocalRunQueue(comptime T: type, comptime stealable: bool) type {
    return struct {
        const Self = @This();

        /// Ring capacity. Must be a power of two. Go and Tokio use 256.
        pub const capacity: u32 = 256;
        const mask: u32 = capacity - 1;

        buffer: [capacity]*T = undefined,
        // Ring cursors. `head` is advanced by the owner (pop) and, when stealable,
        // by thieves; `tail` is written only by the owner. They are plain scalars —
        // the accessors below apply atomic ordering only in the stealable build, so
        // a single-owner queue pays no atomic cost.
        head: u32 = 0,
        tail: u32 = 0,
        /// Set once, at executor init, to the global or the executor-local queue.
        overflow: *OverflowQueue(T) = undefined,

        // --- cursor accessors --------------------------------------------------
        // Cross-thread reads acquire; the owner publishes `tail` with a release
        // store so a thief's acquire-load of `tail` also sees the buffer slot. The
        // owner reads its own `tail` plainly (`ownTail`) as the sole producer. When
        // `stealable` is false these all collapse to plain loads/stores.

        inline fn loadHead(self: *const Self) u32 {
            return if (stealable) @atomicLoad(u32, &self.head, .acquire) else self.head;
        }
        inline fn loadTail(self: *const Self) u32 {
            return if (stealable) @atomicLoad(u32, &self.tail, .acquire) else self.tail;
        }
        /// Owner-only read of its own `tail` (the owner is the sole producer).
        inline fn ownTail(self: *const Self) u32 {
            return self.tail;
        }
        inline fn storeTail(self: *Self, v: u32) void {
            if (stealable) @atomicStore(u32, &self.tail, v, .release) else self.tail = v;
        }
        /// Advance `head` from `expected` to `new`. Returns true on success. A plain
        /// store when not stealable (uncontended); a CAS against racing thieves
        /// otherwise. `weak` selects cmpxchgWeak (retry loops) vs Strong.
        inline fn casHead(self: *Self, expected: u32, new: u32, comptime weak: bool) bool {
            if (!stealable) {
                self.head = new;
                return true;
            }
            return if (weak)
                @cmpxchgWeak(u32, &self.head, expected, new, .acq_rel, .acquire) == null
            else
                @cmpxchgStrong(u32, &self.head, expected, new, .acq_rel, .acquire) == null;
        }

        pub fn init(overflow: *OverflowQueue(T)) Self {
            return .{ .overflow = overflow };
        }

        /// Owner-only push (FIFO, to the tail). On a full ring, spills half the
        /// ring plus this node to the overflow queue (Go's runqput/runqputslow).
        pub fn push(self: *Self, node: *T) void {
            while (true) {
                const h = self.loadHead(); // synchronize with consumers
                const t = self.ownTail(); // owner is the sole producer
                if (t -% h < capacity) {
                    self.buffer[t & mask] = node;
                    self.storeTail(t +% 1); // publish the slot
                    return;
                }
                if (self.pushOverflow(node, h, t)) return;
                // Ring was full but a steal freed space; retry.
            }
        }

        fn pushOverflow(self: *Self, node: *T, h: u32, t: u32) bool {
            const n = (t -% h) / 2; // == capacity/2 when the ring is full
            var batch: [capacity / 2 + 1]*T = undefined;
            var i: u32 = 0;
            while (i < n) : (i += 1) batch[i] = self.buffer[(h +% i) & mask];
            // Claim the grabbed half; a stealer may have raced the head.
            if (!self.casHead(h, h +% n, false)) return false;
            batch[n] = node;
            self.overflow.pushSlice(batch[0 .. n + 1]);
            return true;
        }

        /// Owner-only pop (FIFO, from the head). CAS because stealers race the head.
        pub fn pop(self: *Self) ?*T {
            while (true) {
                const h = self.loadHead();
                const t = self.ownTail();
                if (h == t) return null; // empty
                const node = self.buffer[h & mask];
                if (self.casHead(h, h +% 1, true)) return node;
                // A stealer took slot h; retry with the new head.
            }
        }

        /// Owner-only pop that first lets the caller inspect the head via `runnable`
        /// (e.g. the per-tick "already ran this tick?" guard) without committing to
        /// the pop. Returns null if empty or if the head isn't runnable (left in
        /// place). The predicate is re-checked against the current head on each
        /// retry, so a racing steal never causes an unchecked node to be popped.
        pub fn popIf(self: *Self, context: anytype, comptime runnable: fn (@TypeOf(context), *T) bool) ?*T {
            while (true) {
                const h = self.loadHead();
                const t = self.ownTail();
                if (h == t) return null; // empty
                const node = self.buffer[h & mask];
                if (!runnable(context, node)) return null; // head not runnable; leave it
                if (self.casHead(h, h +% 1, true)) return node;
                // A stealer took slot h; retry and re-check the new head.
            }
        }

        /// Steal roughly half of `victim`'s tasks into this (the thief's) ring and
        /// return one of them to run immediately; the rest stay in this ring. Runs
        /// on the thief's thread — `self` is the thief's own queue. Mirrors Go's
        /// runqsteal/runqgrab. Returns null if the victim had nothing stealable
        /// (empty, or every claim lost the race) or this ring has no room.
        ///
        /// Only available on a stealable queue: with task migration compiled out no
        /// thief exists, so calling this is a programming error and won't compile.
        pub fn steal(self: *Self, victim: *Self) ?*T {
            if (!stealable) @compileError("steal() is unavailable: this queue was built without task migration / work stealing");
            const dst_tail = self.ownTail(); // the thief owns its own tail
            const dst_space = capacity - (dst_tail -% self.loadHead());
            if (dst_space == 0) return null;

            const stolen: u32 = while (true) {
                const h = victim.loadHead(); // sync with victim's consumers
                const vt = victim.loadTail(); // sync with victim's producer
                var take = vt -% h;
                take -= take / 2; // ceil half
                if (take == 0) return null; // victim empty
                if (take > capacity / 2) continue; // inconsistent h/t read; retry
                if (take > dst_space) take = dst_space; // clamp to the thief's room
                var i: u32 = 0;
                while (i < take) : (i += 1) {
                    self.buffer[(dst_tail +% i) & mask] = victim.buffer[(h +% i) & mask];
                }
                // Commit the claim by advancing the victim's head.
                if (victim.casHead(h, h +% take, false)) break take;
                // Lost the race (an owner pop or another thief); retry the grab.
            };

            // Hand back the last stolen task; publish the rest into the thief's ring.
            const rest = stolen - 1;
            const task = self.buffer[(dst_tail +% rest) & mask];
            if (rest > 0) self.storeTail(dst_tail +% rest);
            return task;
        }

        /// Pull up to `max` tasks from the overflow queue into the ring (owner,
        /// once per tick). Only fills available space, so it never overflows.
        pub fn refill(self: *Self, max: usize) void {
            const t = self.ownTail();
            const h = self.loadHead();
            const space: usize = capacity - (t -% h);
            var buf: [64]*T = undefined;
            const want = @min(space, @min(max, buf.len));
            if (want == 0) return;
            const got = self.overflow.popBatch(buf[0..want]);
            var tt = t;
            for (buf[0..got]) |node| {
                self.buffer[tt & mask] = node;
                tt +%= 1;
            }
            if (got > 0) self.storeTail(tt);
        }

        /// Number of tasks currently in the ring (used for maybeYield fairness).
        pub fn len(self: *const Self) u32 {
            const t = self.loadTail();
            const h = self.loadHead();
            return t -% h;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.loadHead() == self.loadTail();
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestNode = struct {
    // Intrusive fields required by the overflow queue's SimpleQueue.
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
    in_list: bool = false,
    id: usize = 0,
};

const TestQueue = LocalRunQueue(TestNode, true);
const TestLocalQueue = LocalRunQueue(TestNode, false);
const TestOverflow = OverflowQueue(TestNode);

test "LocalRunQueue: FIFO push and pop within capacity" {
    var ov: TestOverflow = .{};
    var q = TestQueue.init(&ov);

    var nodes: [10]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        q.push(n);
    }
    try testing.expect(ov.isEmpty());
    try testing.expectEqual(10, q.len());

    for (0..10) |i| {
        const n = q.pop() orelse return error.Unexpected;
        try testing.expectEqual(i, n.id); // FIFO
    }
    try testing.expect(q.pop() == null);
    try testing.expect(q.isEmpty());
}

test "LocalRunQueue: fills to capacity without overflow" {
    const cap = TestQueue.capacity;
    var ov: TestOverflow = .{};
    var q = TestQueue.init(&ov);

    const nodes = try testing.allocator.alloc(TestNode, cap);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        q.push(n);
    }
    try testing.expect(ov.isEmpty()); // exactly full, nothing spilled
    try testing.expectEqual(cap, q.len());

    var count: usize = 0;
    while (q.pop()) |_| count += 1;
    try testing.expectEqual(cap, count);
}

test "LocalRunQueue: overflow spills to the overflow queue and everything drains" {
    const cap = TestQueue.capacity;
    const total = cap + cap / 2; // 1.5x capacity -> guaranteed spill
    var ov: TestOverflow = .{};
    var q = TestQueue.init(&ov);

    const nodes = try testing.allocator.alloc(TestNode, total);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        q.push(n);
    }
    try testing.expect(!ov.isEmpty()); // spilled

    const seen = try testing.allocator.alloc(bool, total);
    defer testing.allocator.free(seen);
    @memset(seen, false);

    var count: usize = 0;
    while (q.pop()) |n| {
        try testing.expect(!seen[n.id]);
        seen[n.id] = true;
        count += 1;
    }
    var buf: [64]*TestNode = undefined;
    while (true) {
        const got = ov.popBatch(&buf);
        if (got == 0) break;
        for (buf[0..got]) |n| {
            try testing.expect(!seen[n.id]);
            seen[n.id] = true;
            count += 1;
        }
    }
    try testing.expectEqual(total, count);
    for (seen) |s| try testing.expect(s);
}

const RejectCtx = struct { reject_id: usize };
fn notRejected(ctx: RejectCtx, node: *TestNode) bool {
    return node.id != ctx.reject_id;
}

test "LocalRunQueue: popIf leaves a non-runnable head in place" {
    var ov: TestOverflow = .{};
    var q = TestQueue.init(&ov);

    var nodes: [3]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        q.push(n);
    }
    // Head is id 0; reject it -> popIf returns null and leaves it in place.
    try testing.expect(q.popIf(RejectCtx{ .reject_id = 0 }, notRejected) == null);
    try testing.expectEqual(3, q.len());
    // Accept anything -> pops the head (id 0).
    const n = q.popIf(RejectCtx{ .reject_id = 999 }, notRejected) orelse return error.Unexpected;
    try testing.expectEqual(0, n.id);
    try testing.expectEqual(2, q.len());
}

test "LocalRunQueue: non-stealable variant pushes, pops, and overflows" {
    // The single-owner build uses plain cursors (no atomics) and has no steal.
    const cap = TestLocalQueue.capacity;
    const total = cap + cap / 2; // force a spill
    var ov: TestOverflow = .{};
    var q = TestLocalQueue.init(&ov);

    const nodes = try testing.allocator.alloc(TestNode, total);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        q.push(n);
    }
    try testing.expect(!ov.isEmpty()); // spilled to overflow

    var count: usize = 0;
    while (q.pop()) |_| count += 1;
    var buf: [64]*TestNode = undefined;
    while (true) {
        const got = ov.popBatch(&buf);
        if (got == 0) break;
        count += got;
    }
    try testing.expectEqual(total, count);
    try testing.expect(q.isEmpty());
}

test "LocalRunQueue: steal takes half into the thief and returns one" {
    var ov1: TestOverflow = .{};
    var ov2: TestOverflow = .{};
    var victim = TestQueue.init(&ov1);
    var thief = TestQueue.init(&ov2);

    var nodes: [4]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        victim.push(n);
    }

    // victim holds 0,1,2,3 (head=0). Steal ceil(4/2)=2 (ids 0,1): returns the last
    // stolen (id 1), keeps id 0 in the thief; victim left with 2,3.
    const got = thief.steal(&victim) orelse return error.Unexpected;
    try testing.expectEqual(1, got.id);
    try testing.expectEqual(1, thief.len());
    try testing.expectEqual(2, victim.len());

    try testing.expectEqual(0, (thief.pop() orelse return error.Unexpected).id);
    try testing.expect(thief.pop() == null);
    try testing.expectEqual(2, (victim.pop() orelse return error.Unexpected).id);
    try testing.expectEqual(3, (victim.pop() orelse return error.Unexpected).id);
}

test "LocalRunQueue: steal with an odd count takes the ceil half" {
    var ov1: TestOverflow = .{};
    var ov2: TestOverflow = .{};
    var victim = TestQueue.init(&ov1);
    var thief = TestQueue.init(&ov2);

    var nodes: [7]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        victim.push(n);
    }
    // 7 tasks -> steal 7 - 7/2 = 4 (ids 0..3), return id 3, thief keeps 0,1,2;
    // victim left with 4,5,6.
    const got = thief.steal(&victim) orelse return error.Unexpected;
    try testing.expectEqual(3, got.id);
    try testing.expectEqual(3, thief.len());
    try testing.expectEqual(3, victim.len());
}

test "LocalRunQueue: steal from an empty victim returns null" {
    var ov1: TestOverflow = .{};
    var ov2: TestOverflow = .{};
    var victim = TestQueue.init(&ov1);
    var thief = TestQueue.init(&ov2);
    try testing.expect(thief.steal(&victim) == null);
}

test "LocalRunQueue: index cycling past capacity stays correct" {
    var ov: TestOverflow = .{};
    var q = TestQueue.init(&ov);
    var node: TestNode = .{ .id = 7 };
    // Cycle head/tail well past capacity to exercise the & mask indexing.
    for (0..10_000) |_| {
        q.push(&node);
        const n = q.pop() orelse return error.Unexpected;
        try testing.expectEqual(7, n.id);
    }
    try testing.expect(q.isEmpty());
}

test "LocalRunQueue: concurrent push/pop and steal loses or duplicates no task" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const N = 50_000;
    const nodes = try testing.allocator.alloc(TestNode, N);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| n.* = .{ .id = i };

    const seen = try testing.allocator.alloc(std.atomic.Value(u8), N);
    defer testing.allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    var owner_ov: TestOverflow = .{};
    var thief_ov: TestOverflow = .{};
    var owner = TestQueue.init(&owner_ov);
    var thief = TestQueue.init(&thief_ov);

    const Ctx = struct {
        owner: *TestQueue,
        thief: *TestQueue,
        seen: []std.atomic.Value(u8),
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn mark(self: *@This(), n: *TestNode) void {
            _ = self.seen[n.id].fetchAdd(1, .monotonic);
        }
    };
    var ctx = Ctx{ .owner = &owner, .thief = &thief, .seen = seen };

    const stealer = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            while (!c.stop.load(.acquire) or !c.owner.isEmpty()) {
                if (c.thief.steal(c.owner)) |n| c.mark(n);
                while (c.thief.pop()) |n| c.mark(n);
            }
            while (c.thief.pop()) |n| c.mark(n);
        }
    }.run, .{&ctx});

    var i: usize = 0;
    var buf: [64]*TestNode = undefined;
    while (i < N) : (i += 1) {
        owner.push(&nodes[i]);
        if (i % 64 == 0) {
            if (owner.pop()) |n| ctx.mark(n);
        }
        const got = owner_ov.popBatch(&buf);
        for (buf[0..got]) |n| ctx.mark(n);
    }
    ctx.stop.store(true, .release);
    stealer.join();

    // Drain everything that remains anywhere.
    while (owner.pop()) |n| ctx.mark(n);
    while (true) {
        const got = owner_ov.popBatch(&buf);
        if (got == 0) break;
        for (buf[0..got]) |n| ctx.mark(n);
    }
    while (thief.pop()) |n| ctx.mark(n);
    while (true) {
        const got = thief_ov.popBatch(&buf);
        if (got == 0) break;
        for (buf[0..got]) |n| ctx.mark(n);
    }

    for (seen, 0..) |*s, id| {
        const c = s.load(.monotonic);
        if (c != 1) {
            std.debug.print("id {} seen {} times (expected 1)\n", .{ id, c });
            return error.TaskLostOrDuplicated;
        }
    }
}

test "LocalRunQueue: multiple concurrent stealers lose or duplicate no task" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const N = 60_000;
    const n_thieves = 3;
    const nodes = try testing.allocator.alloc(TestNode, N);
    defer testing.allocator.free(nodes);
    for (nodes, 0..) |*n, i| n.* = .{ .id = i };

    const seen = try testing.allocator.alloc(std.atomic.Value(u8), N);
    defer testing.allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    var owner_ov: TestOverflow = .{};
    var owner = TestQueue.init(&owner_ov);

    const Ctx = struct {
        owner: *TestQueue,
        seen: []std.atomic.Value(u8),
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn mark(self: *@This(), n: *TestNode) void {
            _ = self.seen[n.id].fetchAdd(1, .monotonic);
        }
    };
    var ctx = Ctx{ .owner = &owner, .seen = seen };

    var thief_ovs: [n_thieves]TestOverflow = @splat(.{});
    var thieves: [n_thieves]TestQueue = undefined;
    for (&thieves, &thief_ovs) |*t, *o| t.* = TestQueue.init(o);

    const Thief = struct {
        fn run(c: *Ctx, thief: *TestQueue) void {
            while (!c.stop.load(.acquire) or !c.owner.isEmpty()) {
                if (thief.steal(c.owner)) |n| c.mark(n);
                while (thief.pop()) |n| c.mark(n);
            }
            while (thief.pop()) |n| c.mark(n);
        }
    };

    var threads: [n_thieves]std.Thread = undefined;
    for (&threads, &thieves) |*th, *thief| {
        th.* = try std.Thread.spawn(.{}, Thief.run, .{ &ctx, thief });
    }

    var i: usize = 0;
    while (i < N) : (i += 1) owner.push(&nodes[i]);
    ctx.stop.store(true, .release);
    for (&threads) |*th| th.join();

    // Drain everything that remains anywhere.
    var buf: [64]*TestNode = undefined;
    while (owner.pop()) |n| ctx.mark(n);
    while (true) {
        const got = owner_ov.popBatch(&buf);
        if (got == 0) break;
        for (buf[0..got]) |n| ctx.mark(n);
    }
    for (&thieves) |*t| while (t.pop()) |n| ctx.mark(n);
    for (&thief_ovs) |*o| while (true) {
        const got = o.popBatch(&buf);
        if (got == 0) break;
        for (buf[0..got]) |n| ctx.mark(n);
    };

    for (seen, 0..) |*s, id| {
        const c = s.load(.monotonic);
        if (c != 1) {
            std.debug.print("id {} seen {} times (expected 1)\n", .{ id, c });
            return error.TaskLostOrDuplicated;
        }
    }
}

test "OverflowQueue: push and popBatch are FIFO" {
    var ov: TestOverflow = .{};
    var nodes: [5]TestNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .id = i };
        ov.push(n);
    }
    try testing.expectEqual(5, ov.len());

    var buf: [3]*TestNode = undefined;
    try testing.expectEqual(3, ov.popBatch(&buf));
    try testing.expectEqual(0, buf[0].id);
    try testing.expectEqual(2, buf[2].id);
    try testing.expectEqual(2, ov.len());

    var buf2: [10]*TestNode = undefined;
    try testing.expectEqual(2, ov.popBatch(&buf2));
    try testing.expect(ov.isEmpty());
    try testing.expectEqual(0, ov.popBatch(&buf2));
}
