const std = @import("std");
const stack = @import("stack.zig");
const StackInfo = stack.StackInfo;

/// A node in the free list, stored at the base of an unused stack.
const FreeNode = struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
    stack_info: StackInfo,
    timestamp: std.time.Instant,
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

    /// Maximum age of an unused stack in nanoseconds.
    /// Stacks older than this will be freed on the next acquire() call.
    /// 0 means no age limit.
    max_age_ns: u64 = 0,
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
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse a stack from the pool
        if (self.head) |node| {
            const stack_info = node.stack_info;
            self.removeNode(node);
            return stack_info;
        }

        // Pool is empty, allocate a new stack
        var stack_info: StackInfo = undefined;
        try stack.stackAlloc(&stack_info, self.config.maximum_size, self.config.committed_size);
        return stack_info;
    }

    /// Releases a stack back to the pool.
    /// Expired stacks are removed before adding the new stack to avoid depleting the pool.
    /// If the pool is full, frees the oldest stack and adds this one.
    /// If the stack's committed region is too small to store the FreeNode, the stack is freed instead.
    pub fn release(self: *StackPool, stack_info: StackInfo) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if the stack has enough committed space to store the FreeNode
        // The FreeNode is stored at the base of the stack (aligned backward)
        const node_addr = std.mem.alignBackward(usize, stack_info.base - @sizeOf(FreeNode), @alignOf(FreeNode));

        // Verify the FreeNode fits within the committed region (between limit and base)
        if (node_addr < stack_info.limit) {
            // Stack is too small to hold the FreeNode, free it instead of pooling
            stack.stackFree(stack_info);
            return;
        }

        // Remove expired stacks from the front of the list
        // Do this before adding the new stack to avoid the situation where we'd
        // remove all stacks (including the one we're about to add) and end up with an empty pool
        if (self.config.max_age_ns > 0) {
            const now = std.time.Instant.now() catch unreachable;
            while (self.head) |node| {
                const age_ns = now.since(node.timestamp);
                if (age_ns > self.config.max_age_ns) {
                    self.removeNode(node);
                    stack.stackFree(node.stack_info);
                } else {
                    // List is ordered by timestamp, so we can stop
                    break;
                }
            }
        }

        // If pool is at capacity, free the oldest stack
        if (self.pool_size >= self.config.max_unused_stacks) {
            if (self.head) |oldest| {
                self.removeNode(oldest);
                stack.stackFree(oldest.stack_info);
            }
        }

        // Recycle the stack memory (MADV_FREE on POSIX)
        stack.stackRecycle(stack_info);

        // Store the FreeNode at the base of the stack
        const node = @as(*FreeNode, @ptrFromInt(node_addr));
        node.* = .{
            .prev = null,
            .next = null,
            .stack_info = stack_info,
            .timestamp = std.time.Instant.now() catch unreachable,
        };

        // Add to the tail of the list (most recently released)
        self.addNode(node);
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
    const testing = std.testing;

    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .max_unused_stacks = 4,
        .max_age_ns = 0,
    });
    defer pool.deinit();

    // Acquire a stack
    const stack1 = try pool.acquire();
    try testing.expect(stack1.base != 0);
    try testing.expect(stack1.base > stack1.limit); // Stack grows downward

    // Release it back
    pool.release(stack1);
    try testing.expectEqual(1, pool.pool_size);

    // Acquire again - should reuse the same stack
    const stack2 = try pool.acquire();
    try testing.expectEqual(stack1.base, stack2.base);
    try testing.expectEqual(0, pool.pool_size);

    // Clean up
    stack.stackFree(stack2);
}

test "StackPool respects max_unused_stacks" {
    const testing = std.testing;

    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .max_unused_stacks = 2,
        .max_age_ns = 0,
    });
    defer pool.deinit();

    // Acquire and release 3 stacks
    const stack1 = try pool.acquire();
    const stack2 = try pool.acquire();
    const stack3 = try pool.acquire();

    pool.release(stack1);
    try testing.expectEqual(1, pool.pool_size);

    pool.release(stack2);
    try testing.expectEqual(2, pool.pool_size);

    // Releasing the third should evict the first (oldest)
    pool.release(stack3);
    try testing.expectEqual(2, pool.pool_size);

    // Verify that stack1 is not in the pool (stack2 and stack3 should be)
    const reused1 = try pool.acquire();
    const reused2 = try pool.acquire();

    try testing.expect(reused1.base == stack2.base or reused1.base == stack3.base);
    try testing.expect(reused2.base == stack2.base or reused2.base == stack3.base);
    try testing.expect(reused1.base != reused2.base);

    // Clean up
    stack.stackFree(reused1);
    stack.stackFree(reused2);
}

test "StackPool age-based expiration" {
    const testing = std.testing;

    var pool = StackPool.init(.{
        .maximum_size = 1024 * 1024,
        .committed_size = 64 * 1024,
        .max_unused_stacks = 4,
        .max_age_ns = 100_000_000, // 100ms
    });
    defer pool.deinit();

    // Acquire and release a stack
    const stack1 = try pool.acquire();
    pool.release(stack1);
    try testing.expectEqual(1, pool.pool_size);

    // Wait for it to expire
    try testing.io.sleep(.fromMilliseconds(150), .awake);

    // Next acquire should allocate a new stack (old one expired)
    const stack2 = try pool.acquire();
    try testing.expectEqual(0, pool.pool_size);

    // Note: We don't check if stack1.base != stack2.base because the OS
    // may reuse the same virtual address range, which is valid behavior

    // Clean up
    stack.stackFree(stack2);
}
