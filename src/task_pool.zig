const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const runtime = @import("runtime.zig");
const AnyTask = runtime.AnyTask;
const AnyBlockingTask = runtime.AnyBlockingTask;

pub const TaskPoolOptions = struct {
    retention_ms: i64 = 60 * std.time.ms_per_s, // 60 seconds
    min_warm_count: usize = 4,
};

// Unit size = max(sizeof(AnyTask), sizeof(AnyBlockingTask))
// Both now have 256-byte result_data, AnyTask is larger
const UNIT_SIZE = @max(@sizeOf(AnyTask), @sizeOf(AnyBlockingTask));

const FreeListNode = struct {
    next: ?*FreeListNode,
    returned_at: i64,

    fn fromBytes(bytes: []align(@alignOf(AnyTask)) u8, returned_at: i64) *FreeListNode {
        assert(bytes.len >= UNIT_SIZE);
        const node: *FreeListNode = @ptrCast(@alignCast(bytes.ptr));
        node.* = .{
            .next = null,
            .returned_at = returned_at,
        };
        return node;
    }

    fn toBytes(node: *FreeListNode) []align(@alignOf(AnyTask)) u8 {
        const ptr: [*]align(@alignOf(AnyTask)) u8 = @ptrCast(@alignCast(node));
        return ptr[0..UNIT_SIZE];
    }
};

const FreeList = struct {
    head: ?*FreeListNode = null,
    count: usize = 0,

    fn acquire(self: *FreeList, allocator: Allocator) ![]align(@alignOf(AnyTask)) u8 {
        // Pop from head (LIFO)
        if (self.head) |node| {
            self.head = node.next;
            self.count -= 1;
            return node.toBytes();
        }

        // Pool empty, allocate new block
        return try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(AnyTask)), UNIT_SIZE);
    }

    fn release(self: *FreeList, bytes: []align(@alignOf(AnyTask)) u8) void {
        const node = FreeListNode.fromBytes(bytes, std.time.milliTimestamp());
        node.next = self.head;
        self.head = node;
        self.count += 1;
    }

    fn cleanupOld(self: *FreeList, allocator: Allocator, now: i64, retention_ms: i64, min_warm: usize) void {
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
                allocator.free(node.toBytes());
                self.count -= 1;
                curr = next; // don't update prev
            } else {
                prev = node;
                curr = node.next;
            }
        }
    }

    fn deinit(self: *FreeList, allocator: Allocator) void {
        var curr = self.head;
        while (curr) |node| {
            const next = node.next;
            allocator.free(node.toBytes());
            curr = next;
        }
        self.head = null;
        self.count = 0;
    }
};

pub const TaskPool = struct {
    free_list: FreeList,
    allocator: Allocator,
    retention_ms: i64,
    min_warm_count: usize,

    pub fn init(allocator: Allocator, options: TaskPoolOptions) TaskPool {
        return .{
            .free_list = .{},
            .allocator = allocator,
            .retention_ms = options.retention_ms,
            .min_warm_count = options.min_warm_count,
        };
    }

    pub fn deinit(self: *TaskPool) void {
        self.free_list.deinit(self.allocator);
    }

    pub fn acquireAnyTask(self: *TaskPool) !*AnyTask {
        const bytes = try self.free_list.acquire(self.allocator);
        const task: *AnyTask = @ptrCast(@alignCast(bytes.ptr));
        // Zero out the memory to ensure clean state
        @memset(std.mem.asBytes(task), 0);
        return task;
    }

    pub fn releaseAnyTask(self: *TaskPool, task: *AnyTask) void {
        const bytes: []align(@alignOf(AnyTask)) u8 = @as([*]align(@alignOf(AnyTask)) u8, @ptrCast(task))[0..UNIT_SIZE];
        self.free_list.release(bytes);
    }

    pub fn acquireAnyBlockingTask(self: *TaskPool) !*AnyBlockingTask {
        const bytes = try self.free_list.acquire(self.allocator);
        const task: *AnyBlockingTask = @ptrCast(@alignCast(bytes.ptr));
        // Zero out the memory to ensure clean state
        @memset(std.mem.asBytes(task), 0);
        return task;
    }

    pub fn releaseAnyBlockingTask(self: *TaskPool, task: *AnyBlockingTask) void {
        const bytes: []align(@alignOf(AnyTask)) u8 = @as([*]align(@alignOf(AnyTask)) u8, @ptrCast(task))[0..UNIT_SIZE];
        self.free_list.release(bytes);
    }

    pub fn cleanup(self: *TaskPool) void {
        const now = std.time.milliTimestamp();
        self.free_list.cleanupOld(self.allocator, now, self.retention_ms, self.min_warm_count);
    }
};
