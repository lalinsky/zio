// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const stack = @import("stack.zig");
const StackInfo = stack.StackInfo;
const Timestamp = @import("../time.zig").Timestamp;
const Duration = @import("../time.zig").Duration;

/// A node in the free list, stored at the base of an unused stack.
const FreeNode = struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
    stack_info: StackInfo,
    timestamp: Timestamp,
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
    max_age: Duration = .zero,
};

pub const StackPool = struct {
    config: Config,
    mutex: std.Thread.Mutex,
    head: ?*FreeNode,
    tail: ?*FreeNode,
    pool_size: usize,

    pub fn init(config: Config) StackPool {
        return .{
            .config = config,
            .mutex = .{},
            .head = null,
            .tail = null,
            .pool_size = 0,
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
    }

    /// Acquires a stack from the pool, or allocates a new one if the pool is empty.
    /// All stacks from this pool have the configured maximum_size and committed_size.
    pub fn acquire(self: *StackPool) error{OutOfMemory}!StackInfo {
        // Try to get from pool under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |node| {
                const stack_info = node.stack_info;
                self.removeNode(node);
                return stack_info;
            }
        }

        // Pool was empty, allocate new stack outside the lock
        var stack_info: StackInfo = undefined;
        try stack.stackAlloc(&stack_info, self.config.maximum_size, self.config.committed_size);
        return stack_info;
    }

    /// Releases a stack back to the pool.
    /// Expired stacks are removed before adding the new stack to avoid depleting the pool.
    /// If the pool is full, frees the oldest stack and adds this one.
    /// If the stack's committed region is too small to store the FreeNode, the stack is freed instead.
    pub fn release(self: *StackPool, stack_info: StackInfo, timestamp: Timestamp) void {
        // Check if the stack has enough committed space to store the FreeNode
        // The FreeNode is stored at the base of the stack (aligned backward)
        const node_addr = std.mem.alignBackward(usize, stack_info.base - @sizeOf(FreeNode), @alignOf(FreeNode));

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

    // Release it back
    pool.release(stack1, .zero);
    try std.testing.expectEqual(1, pool.pool_size);

    // Acquire again - should reuse the same stack
    const stack2 = try pool.acquire();
    try std.testing.expectEqual(stack1.base, stack2.base);
    try std.testing.expectEqual(0, pool.pool_size);

    // Clean up
    stack.stackFree(stack2);
}

test "StackPool respects max_unused_stacks" {
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
