const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const coroutines = @import("coroutines.zig");
const Stack = coroutines.Stack;
const StackPtr = coroutines.StackPtr;
const stack_alignment = coroutines.stack_alignment;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;

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
    next: ?*FreeListNode = null,
    prev: ?*FreeListNode = null,
    in_list: bool = false,
    returned_at: std.time.Instant,

    fn fromStack(stack: Stack, returned_at: std.time.Instant) *FreeListNode {
        assert(stack.len >= MIN_STACK_SIZE);
        const node: *FreeListNode = @ptrCast(@alignCast(stack.ptr));
        node.* = .{
            .next = null,
            .prev = null,
            .in_list = false,
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
    queue: WaitQueue(FreeListNode) = WaitQueue(FreeListNode).empty,

    fn acquire(self: *Bucket, size: usize, allocator: Allocator) !Stack {
        // Pop from front (FIFO - gets oldest stack)
        if (self.queue.pop()) |node| {
            return node.toStack(size);
        }

        // Pool empty, allocate new stack with page alignment
        const alignment = @max(stack_alignment, stack_alloc_alignment);
        return try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alignment), size);
    }

    fn release(self: *Bucket, stack: Stack, returned_at: std.time.Instant) void {
        const node = FreeListNode.fromStack(stack, returned_at);
        self.queue.push(node);
    }

    fn cleanupOld(self: *Bucket, size: usize, allocator: Allocator, now: std.time.Instant, retention_ns: u64, min_warm: usize) void {
        var kept_count: usize = 0;

        // Pop from front (oldest first due to FIFO)
        while (self.queue.pop()) |node| {
            const age_ns = now.since(node.returned_at);
            // Check if stack is too old
            if (age_ns > retention_ns and kept_count >= min_warm) {
                // Too old and we have enough warm stacks - free it
                allocator.free(node.toStack(size));
            } else {
                // Still young or need to keep for min_warm - push back to queue
                self.queue.push(node);
                kept_count += 1;

                // Since queue is FIFO, once we find a young stack, all following are younger
                // So we can stop here
                break;
            }
        }
    }

    fn deinit(self: *Bucket, size: usize, allocator: Allocator) void {
        // Drain the queue and free all stacks
        while (self.queue.pop()) |node| {
            allocator.free(node.toStack(size));
        }
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
    retention_ns: u64,
    min_warm_count: usize,

    pub fn init(allocator: Allocator, options: StackPoolOptions) StackPool {
        return .{
            .buckets = [_]Bucket{.{}} ** NUM_BUCKETS,
            .allocator = allocator,
            .retention_ns = @as(u64, @intCast(options.retention_ms)) * std.time.ns_per_ms,
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
            const now = std.time.Instant.now() catch unreachable;
            self.buckets[bucket_idx].release(stack, now);
        } else {
            // Too large for pool, free directly
            self.allocator.free(stack);
        }
    }

    pub fn cleanup(self: *StackPool) void {
        const now = std.time.Instant.now() catch unreachable;
        for (&self.buckets, 0..) |*bucket, i| {
            bucket.cleanupOld(bucketSize(i), self.allocator, now, self.retention_ns, self.min_warm_count);
        }
    }
};
