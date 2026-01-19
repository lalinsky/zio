// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Work-stealing queue for task scheduling.
//!
//! This is a lock-free FIFO queue optimized for work-stealing schedulers,
//! based on Go's runtime scheduler queue design and used by Tokio.
//!
//! Key characteristics:
//! - Fixed-size circular buffer (no dynamic growth)
//! - FIFO semantics: push at tail, pop/steal from head
//! - Single-producer (owner thread can push/pop)
//! - Multi-consumer (any thread can steal ~half the queue)
//! - Lock-free using atomic operations
//!
//! This differs from Chase-Lev deques which are LIFO for the owner.
//! Here, the owner is also FIFO, which provides better fairness.

const std = @import("std");
const builtin = @import("builtin");

/// Work-stealing queue for task scheduling.
///
/// This is a fixed-size, lock-free FIFO queue designed for work-stealing schedulers.
/// The owner thread can push and pop tasks, while other threads can steal approximately
/// half of the queue's tasks to balance load.
///
/// **Semantics:**
/// - `push()`: Owner adds task at tail (FIFO)
/// - `pop()`: Owner removes task from head (FIFO)
/// - `steal()`: Any thread steals ~half the tasks from head (FIFO)
///
/// **Memory ordering:**
/// - Uses acquire/release semantics for proper synchronization
/// - Head is atomic (multi-threaded access for stealing)
/// - Tail is atomic but only modified by owner (can be unsafely loaded by owner)
///
/// **Type requirements:**
/// - T: any type that can be stored in the queue
/// - capacity: must be a power of 2 for efficient modulo operations
///
/// **Usage:**
/// ```zig
/// const Queue = WorkStealingQueue(Task, 256);
/// var my_queue: Queue = .{};  // or Queue.empty
/// var victim_queue: Queue = .{};
///
/// // Owner thread
/// my_queue.push(task);
/// if (my_queue.pop()) |task| { ... }
///
/// // Stealer thread (steal from victim into my queue)
/// victim_queue.steal(&my_queue);
/// if (my_queue.pop()) |task| { ... }
/// ```
pub fn WorkStealingQueue(comptime T: type, comptime capacity: u32) type {
    // Ensure capacity is power of 2 for efficient masking
    if (!std.math.isPowerOfTwo(capacity)) {
        @compileError("WorkStealingQueue capacity must be a power of 2");
    }

    return struct {
        const Self = @This();

        /// Fixed-size circular buffer of tasks (stored inline)
        buffer: [capacity]T = undefined,

        /// Head position (where tasks are popped/stolen from)
        /// Modified by owner during pop, and by stealers during steal
        head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        /// Tail position (where tasks are pushed to)
        /// Only modified by owner thread
        tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        /// Mask for efficient modulo operation (capacity - 1)
        const MASK: u32 = capacity - 1;

        /// Empty queue constant for convenient initialization
        pub const empty: Self = .{};

        /// Returns the current number of tasks in the queue.
        ///
        /// **Note:** This is a snapshot and may be stale immediately.
        /// Only use for metrics/debugging, not for control flow.
        ///
        /// Memory ordering: Uses .acquire to observe recent modifications.
        pub fn size(self: *const Self) u32 {
            // .acquire: observe recent push/pop/steal operations
            const head_pos = self.head.load(.acquire);
            const tail_pos = self.tail.load(.acquire);

            // Wrapping subtraction handles circular buffer correctly
            return tail_pos -% head_pos;
        }

        /// Returns true if the queue is empty.
        ///
        /// **Note:** This is a snapshot and may be stale immediately.
        pub fn isEmpty(self: *const Self) bool {
            return self.size() == 0;
        }

        /// Push a task to the back of the queue.
        ///
        /// **Owner thread only.**
        ///
        /// Returns an error if the queue is full. The caller should handle
        /// overflow by moving tasks to a global injection queue.
        ///
        /// Memory ordering: Uses .release on tail store to publish the task.
        pub fn push(self: *Self, task: T) error{QueueFull}!void {
            // Safety: we're the owner, only we modify tail
            const tail_pos = self.tail.raw;
            const head_pos = self.head.load(.acquire);

            // Check if full
            if (tail_pos -% head_pos >= capacity) {
                return error.QueueFull;
            }

            // Write task to buffer
            const index = tail_pos & MASK;
            self.buffer[index] = task;

            // Publish: make task visible to stealers
            // .release: ensures task write happens-before tail update is visible
            self.tail.store(tail_pos +% 1, .release);
        }

        /// Pop a task from the front of the queue.
        ///
        /// **Owner thread only.**
        ///
        /// Returns null if the queue is empty, or if a concurrent stealer
        /// won the race to claim the last task(s).
        ///
        /// Memory ordering: Uses .acq_rel for head updates to synchronize
        /// with concurrent stealers.
        pub fn pop(self: *Self) ?T {
            var head_pos = self.head.load(.acquire);

            while (true) {
                // Safety: we're the owner, only we modify tail
                const tail_pos = self.tail.raw;

                // Check if empty
                if (head_pos == tail_pos) {
                    return null;
                }

                // Try to claim the task atomically
                // This can race with steal(), so we use CAS
                // .acq_rel: synchronize with concurrent steals
                // .acquire: observe the current head if CAS fails
                if (self.head.cmpxchgWeak(
                    head_pos,
                    head_pos +% 1,
                    .acq_rel,
                    .acquire,
                )) |actual| {
                    // CAS failed, another stealer won - retry with new head
                    head_pos = actual;
                    continue;
                }

                // Successfully claimed the task
                const index = head_pos & MASK;
                return self.buffer[index];
            }
        }

        /// Steal approximately half of the tasks from this queue into another queue.
        ///
        /// **Any thread can call this.**
        ///
        /// Attempts to steal roughly half of the available tasks from the victim queue
        /// (self) and place them directly into the destination queue.
        ///
        /// The destination queue must have sufficient capacity. If the destination is full
        /// or nearly full, fewer tasks (or none) will be stolen.
        ///
        /// Does nothing if:
        /// - Victim queue is empty
        /// - Destination queue is full
        /// - Another stealer is concurrently stealing
        /// - There are no tasks to steal after rounding (e.g., only 1 task)
        ///
        /// Memory ordering: Uses .acq_rel for head updates to synchronize
        /// with owner and other stealers.
        ///
        /// **Safety:** The caller must be the owner of the destination queue.
        pub fn steal(victim: *Self, dest: *Self) void {
            // Check destination capacity
            // Safety: caller owns dest, so only caller modifies dest.tail
            const dest_tail = dest.tail.raw;
            const dest_head = dest.head.load(.acquire);
            const dest_used = dest_tail -% dest_head;
            const dest_space = capacity - dest_used;

            if (dest_space == 0) {
                return; // Destination is full
            }

            var victim_head = victim.head.load(.acquire);

            while (true) {
                const victim_tail = victim.tail.load(.acquire);

                // Calculate available tasks in victim
                const available = victim_tail -% victim_head;

                if (available == 0) {
                    return; // Victim is empty
                }

                // Steal half (rounded down), limited by dest capacity
                // If available = 7, we steal min(3, dest_space)
                var num_to_steal = available - (available / 2);
                if (num_to_steal > dest_space) {
                    num_to_steal = dest_space;
                }

                if (num_to_steal == 0) {
                    return; // Not enough to steal
                }

                // Try to claim tasks atomically from victim by advancing head
                // .acq_rel: synchronize with owner pop() and other steal() calls
                // .acquire: observe current head if CAS fails
                if (victim.head.cmpxchgWeak(
                    victim_head,
                    victim_head +% num_to_steal,
                    .acq_rel,
                    .acquire,
                )) |actual| {
                    // CAS failed, retry with new head
                    victim_head = actual;
                    continue;
                }

                // Successfully claimed tasks [victim_head, victim_head + num_to_steal)
                // Copy them from victim to destination
                var i: u32 = 0;
                while (i < num_to_steal) : (i += 1) {
                    const src_idx = (victim_head +% i) & MASK;
                    const dst_idx = (dest_tail +% i) & MASK;
                    dest.buffer[dst_idx] = victim.buffer[src_idx];
                }

                // Publish tasks in destination
                // .release: ensures task writes happen-before tail update is visible
                // Safety: we own dest, only we modify dest.tail
                dest.tail.store(dest_tail +% num_to_steal, .release);

                return;
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "WorkStealingQueue: basic push and pop" {
    const Queue = WorkStealingQueue(u32, 8);
    var queue: Queue = .{};

    // Initially empty
    try std.testing.expectEqual(0, queue.size());
    try std.testing.expect(queue.isEmpty());

    // Push some tasks
    try queue.push(10);
    try queue.push(20);
    try queue.push(30);

    try std.testing.expectEqual(3, queue.size());

    // Pop tasks (FIFO order)
    try std.testing.expectEqual(10, queue.pop());
    try std.testing.expectEqual(20, queue.pop());
    try std.testing.expectEqual(30, queue.pop());
    try std.testing.expectEqual(null, queue.pop());

    try std.testing.expect(queue.isEmpty());
}

test "WorkStealingQueue: push until full" {
    const Queue = WorkStealingQueue(usize, 4);
    var queue: Queue = .{};

    // Fill the queue
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try queue.push(4);

    try std.testing.expectEqual(4, queue.size());

    // Should fail when full
    try std.testing.expectError(error.QueueFull, queue.push(5));
}

test "WorkStealingQueue: basic steal" {
    const Queue = WorkStealingQueue(u32, 16);
    var victim: Queue = .{};
    var dest: Queue = .{};

    // Push 8 tasks to victim
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try victim.push(i);
    }

    try std.testing.expectEqual(8, victim.size());

    // Steal ~half (should steal 4, leaving 4)
    victim.steal(&dest);

    try std.testing.expectEqual(4, victim.size());
    try std.testing.expectEqual(4, dest.size());

    // Verify stolen tasks in dest (should be 0, 1, 2, 3)
    try std.testing.expectEqual(0, dest.pop());
    try std.testing.expectEqual(1, dest.pop());
    try std.testing.expectEqual(2, dest.pop());
    try std.testing.expectEqual(3, dest.pop());

    // Verify remaining tasks in victim (should be 4, 5, 6, 7)
    try std.testing.expectEqual(4, victim.pop());
    try std.testing.expectEqual(5, victim.pop());
    try std.testing.expectEqual(6, victim.pop());
    try std.testing.expectEqual(7, victim.pop());
    try std.testing.expectEqual(null, victim.pop());
}

test "WorkStealingQueue: steal from empty queue" {
    const Queue = WorkStealingQueue(u32, 8);
    var victim: Queue = .{};
    var dest: Queue = .{};

    victim.steal(&dest);

    try std.testing.expectEqual(0, dest.size());
}

test "WorkStealingQueue: steal with odd number of tasks" {
    const Queue = WorkStealingQueue(u32, 16);
    var victim: Queue = .{};
    var dest: Queue = .{};

    // Push 7 tasks to victim
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        try victim.push(i * 10);
    }

    // Steal: available=7, steal = 7 - (7/2) = 7 - 3 = 4 (leaves 3)
    victim.steal(&dest);

    try std.testing.expectEqual(3, victim.size());
    try std.testing.expectEqual(4, dest.size());

    // Verify stolen tasks in dest (first 4 tasks: 0, 10, 20, 30)
    try std.testing.expectEqual(0, dest.pop());
    try std.testing.expectEqual(10, dest.pop());
    try std.testing.expectEqual(20, dest.pop());
    try std.testing.expectEqual(30, dest.pop());
}

test "WorkStealingQueue: wrapping behavior" {
    const Queue = WorkStealingQueue(u32, 4);
    var queue: Queue = .{};

    // Fill, drain, fill again to test wrapping
    try queue.push(1);
    try queue.push(2);
    _ = queue.pop();
    _ = queue.pop();

    try queue.push(3);
    try queue.push(4);
    try queue.push(5);
    try queue.push(6);

    // Should have 4 tasks
    try std.testing.expectEqual(4, queue.size());

    // Pop all
    try std.testing.expectEqual(3, queue.pop());
    try std.testing.expectEqual(4, queue.pop());
    try std.testing.expectEqual(5, queue.pop());
    try std.testing.expectEqual(6, queue.pop());
    try std.testing.expectEqual(null, queue.pop());
}

test "WorkStealingQueue: concurrent push and steal" {
    const Queue = WorkStealingQueue(usize, 256);
    var victim_queue: Queue = .{};

    const num_items = 200;

    // Owner thread: push items to victim queue
    const owner_thread = try std.Thread.spawn(.{}, struct {
        fn pushItems(q: *Queue) !void {
            var i: usize = 0;
            while (i < num_items) : (i += 1) {
                try q.push(i);
            }
        }
    }.pushItems, .{&victim_queue});

    // Stealer thread: steal items from victim into own queue
    var stealer_queue: Queue = .{};
    const stealer_thread = try std.Thread.spawn(.{}, struct {
        fn stealItems(victim: *Queue, dest: *Queue) void {
            var attempts: usize = 0;
            while (attempts < 20) : (attempts += 1) {
                _ = victim.steal(dest);
                std.Thread.yield() catch {};
            }
        }
    }.stealItems, .{ &victim_queue, &stealer_queue });

    owner_thread.join();
    stealer_thread.join();

    // Count stolen items
    var stolen_count: usize = 0;
    while (stealer_queue.pop()) |_| {
        stolen_count += 1;
    }

    // Drain remaining from victim
    var popped_count: usize = 0;
    while (victim_queue.pop()) |_| {
        popped_count += 1;
    }

    const total = stolen_count + popped_count;
    try std.testing.expectEqual(num_items, total);
}

test "WorkStealingQueue: multiple stealers" {
    const Queue = WorkStealingQueue(usize, 256);
    var victim: Queue = .{};

    // Push many tasks to victim
    const num_items = 200;
    var i: usize = 0;
    while (i < num_items) : (i += 1) {
        try victim.push(i);
    }

    // Multiple stealers, each with their own queue
    const num_stealers = 4;
    var stealer_queues: [num_stealers]Queue = undefined;
    for (&stealer_queues) |*q| {
        q.* = .{};
    }

    var threads: [num_stealers]std.Thread = undefined;

    for (0..num_stealers) |j| {
        threads[j] = try std.Thread.spawn(.{}, struct {
            fn stealItems(victim_q: *Queue, dest_q: *Queue) void {
                while (!victim_q.isEmpty()) {
                    victim_q.steal(dest_q);
                }
            }
        }.stealItems, .{ &victim, &stealer_queues[j] });
    }

    // Wait for all stealers
    for (threads) |t| {
        t.join();
    }

    // Count stolen items from all stealer queues
    var total_stolen: usize = 0;
    for (&stealer_queues) |*q| {
        while (q.pop()) |_| {
            total_stolen += 1;
        }
    }

    // Drain any remaining from victim
    var remaining: usize = 0;
    while (victim.pop()) |_| {
        remaining += 1;
    }

    const total = total_stolen + remaining;
    try std.testing.expectEqual(num_items, total);
}
