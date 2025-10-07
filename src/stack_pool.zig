const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const coroutines = @import("coroutines.zig");
const Stack = coroutines.Stack;
const StackPtr = coroutines.StackPtr;
const stack_alignment = coroutines.stack_alignment;

pub const MIN_STACK_SIZE = 64 * 1024; // 64KB
const NUM_BUCKETS = 8; // 64KB, 128KB, 256KB, 512KB, 1MB, 2MB, 4MB, 8MB
const MAX_POOLED_SIZE = MIN_STACK_SIZE << (NUM_BUCKETS - 1); // 8MB

// Use page alignment for stacks to avoid crossing page boundaries unnecessarily
const stack_alloc_alignment = std.heap.page_size_min;

/// Calculate bucket size from index using bit shift
fn bucketSize(index: usize) usize {
    return std.math.shl(usize, MIN_STACK_SIZE, index);
}

const FreeListNode = struct {
    next: ?*FreeListNode,
    returned_at: i64,

    fn fromStack(stack: Stack, returned_at: i64) *FreeListNode {
        assert(stack.len >= MIN_STACK_SIZE);
        const node: *FreeListNode = @ptrCast(@alignCast(stack.ptr));
        node.* = .{
            .next = null,
            .returned_at = returned_at,
        };
        return node;
    }

    fn toStack(node: *FreeListNode, len: usize) Stack {
        const ptr: StackPtr = @ptrCast(@alignCast(node));
        return ptr[0..len];
    }
};

const Bucket = struct {
    head: ?*FreeListNode = null,
    count: usize = 0,

    fn acquire(self: *Bucket, size: usize, allocator: Allocator) !Stack {
        // Pop from head (LIFO)
        if (self.head) |node| {
            self.head = node.next;
            self.count -= 1;
            return node.toStack(size);
        }

        // Pool empty, allocate new stack with page alignment
        const alignment = @max(stack_alignment, stack_alloc_alignment);
        return try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alignment), size);
    }

    fn release(self: *Bucket, stack: Stack) void {
        const node = FreeListNode.fromStack(stack, std.time.milliTimestamp());
        node.next = self.head;
        self.head = node;
        self.count += 1;
    }

    fn cleanupOld(self: *Bucket, size: usize, allocator: Allocator, now: i64, retention_ms: i64, min_warm: usize) void {
        var prev: ?*FreeListNode = null;
        var curr = self.head;

        while (curr) |node| {
            if (self.count <= min_warm) break;

            if (node.returned_at + retention_ms < now) {
                // Remove this node
                const next = node.next;
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.head = next;
                }
                allocator.free(node.toStack(size));
                self.count -= 1;
                curr = next; // don't update prev
            } else {
                prev = node;
                curr = node.next;
            }
        }
    }

    fn deinit(self: *Bucket, size: usize, allocator: Allocator) void {
        var curr = self.head;
        while (curr) |node| {
            const next = node.next;
            allocator.free(node.toStack(size));
            curr = next;
        }
        self.head = null;
        self.count = 0;
    }
};

pub const StackPoolOptions = struct {
    retention_ms: i64 = 60 * std.time.ms_per_s, // 60 seconds
    cleanup_interval_ms: i64 = 10 * std.time.ms_per_s, // 10 seconds
    min_warm_count: usize = 4,
};

pub const StackPool = struct {
    buckets: [NUM_BUCKETS]Bucket,
    allocator: Allocator,
    retention_ms: i64,
    min_warm_count: usize,

    pub fn init(allocator: Allocator, options: StackPoolOptions) StackPool {
        return .{
            .buckets = [_]Bucket{.{}} ** NUM_BUCKETS,
            .allocator = allocator,
            .retention_ms = options.retention_ms,
            .min_warm_count = options.min_warm_count,
        };
    }

    pub fn deinit(self: *StackPool) void {
        for (&self.buckets, 0..) |*bucket, i| {
            bucket.deinit(bucketSize(i), self.allocator);
        }
    }

    /// Round up to next power of 2 (minimum MIN_STACK_SIZE)
    fn roundToPowerOf2(size: usize) usize {
        if (size <= MIN_STACK_SIZE) return MIN_STACK_SIZE;
        return std.math.ceilPowerOfTwo(usize, size) catch unreachable;
    }

    /// Select bucket index based on power-of-2 size
    /// Returns null if size is too large for pool
    fn selectBucket(size: usize) ?usize {
        if (size > MAX_POOLED_SIZE) return null;

        // Calculate log2(size / MIN_STACK_SIZE)
        const ratio = size / MIN_STACK_SIZE;
        const bucket_idx = std.math.log2(ratio);

        assert(bucket_idx < NUM_BUCKETS);
        return bucket_idx;
    }

    pub fn acquire(self: *StackPool, requested_size: usize) !Stack {
        assert(requested_size >= MIN_STACK_SIZE);
        const rounded_size = roundToPowerOf2(requested_size);

        if (selectBucket(rounded_size)) |bucket_idx| {
            return self.buckets[bucket_idx].acquire(bucketSize(bucket_idx), self.allocator);
        }

        // Too large for pool, allocate directly with page alignment
        const alignment = @max(stack_alignment, stack_alloc_alignment);
        return try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alignment), rounded_size);
    }

    pub fn release(self: *StackPool, stack: Stack) void {
        assert(stack.len >= MIN_STACK_SIZE);

        if (selectBucket(stack.len)) |bucket_idx| {
            self.buckets[bucket_idx].release(stack);
        } else {
            // Too large for pool, free directly
            self.allocator.free(stack);
        }
    }

    pub fn cleanup(self: *StackPool) void {
        const now = std.time.milliTimestamp();
        for (&self.buckets, 0..) |*bucket, i| {
            bucket.cleanupOld(bucketSize(i), self.allocator, now, self.retention_ms, self.min_warm_count);
        }
    }
};
