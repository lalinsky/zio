const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const runtime = @import("runtime.zig");
const AnyTask = runtime.AnyTask;
const AnyBlockingTask = runtime.AnyBlockingTask;

// Task pool allocates fixed-size blocks that can hold either AnyTask or AnyBlockingTask
// plus space for FutureResult(T) and Args (for blocking tasks)
pub const TASK_ALLOCATION_SIZE = 512;
pub const TASK_ALLOCATION_ALIGNMENT = 16;

const FreeListNode = struct {
    next: ?*FreeListNode,
    returned_at: i64,
};

pub const TaskPoolOptions = struct {
    retention_ms: i64 = 60 * std.time.ms_per_s, // 60 seconds
    min_warm_count: usize = 4,
};

pub const TaskPool = struct {
    head: ?*FreeListNode = null,
    count: usize = 0,
    allocator: Allocator,
    retention_ms: i64,
    min_warm_count: usize,

    pub fn init(allocator: Allocator, options: TaskPoolOptions) TaskPool {
        return .{
            .allocator = allocator,
            .retention_ms = options.retention_ms,
            .min_warm_count = options.min_warm_count,
        };
    }

    pub fn deinit(self: *TaskPool) void {
        var curr = self.head;
        while (curr) |node| {
            const next = node.next;
            const slice = @as([*]u8, @ptrCast(node))[0..TASK_ALLOCATION_SIZE];
            self.allocator.free(slice);
            curr = next;
        }
        self.head = null;
        self.count = 0;
    }

    /// Acquire a 512-byte aligned block for task allocation
    pub fn acquire(self: *TaskPool) ![*]align(TASK_ALLOCATION_ALIGNMENT) u8 {
        // Pop from head (LIFO)
        if (self.head) |node| {
            self.head = node.next;
            self.count -= 1;
            return @ptrCast(@alignCast(node));
        }

        // Pool empty, allocate new block
        const slice = try self.allocator.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(TASK_ALLOCATION_ALIGNMENT),
            TASK_ALLOCATION_SIZE,
        );
        return @ptrCast(@alignCast(slice.ptr));
    }

    /// Release a task allocation back to the pool
    pub fn release(self: *TaskPool, ptr: [*]align(TASK_ALLOCATION_ALIGNMENT) u8) void {
        const node: *FreeListNode = @ptrCast(@alignCast(ptr));
        node.* = .{
            .next = self.head,
            .returned_at = std.time.milliTimestamp(),
        };
        self.head = node;
        self.count += 1;
    }

    /// Clean up old allocations based on retention policy
    pub fn cleanup(self: *TaskPool) void {
        const now = std.time.milliTimestamp();
        var prev: ?*FreeListNode = null;
        var curr = self.head;

        while (curr) |node| {
            if (self.count <= self.min_warm_count) break;

            if (node.returned_at + self.retention_ms < now) {
                // Remove this node
                const next = node.next;
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.head = next;
                }
                const slice = @as([*]u8, @ptrCast(node))[0..TASK_ALLOCATION_SIZE];
                self.allocator.free(slice);
                self.count -= 1;
                curr = next; // don't update prev
            } else {
                prev = node;
                curr = node.next;
            }
        }
    }
};
