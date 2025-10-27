const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const AnyTask = @import("task.zig").AnyTask;

/// A timeout that applies to all I/O operations on the current task.
/// Multiple Timeout instances can be nested - the earliest deadline always applies.
/// Timeouts are stack-allocated and managed via defer pattern.
pub const Timeout = struct {
    task: *AnyTask,
    deadline_ns: u64 = 0,
    heap: xev.heap.IntrusiveField(Timeout) = .{},
    in_heap: bool = false,

    /// Initialize a Timeout for the current task.
    /// The Timeout must be deinitialized with deinit() when done.
    /// Panics if not called from within a coroutine.
    pub fn init(rt: *Runtime) Timeout {
        const task = rt.getCurrentTask() orelse @panic("Timeout.init requires active task");
        return .{ .task = task };
    }

    /// Set the timeout deadline in milliseconds from now.
    /// If the timeout is already in the heap, it will be updated with the new deadline.
    /// Can be called multiple times to update the deadline.
    pub fn set(self: *Timeout, rt: *Runtime, timeout_ms: u64) void {
        _ = rt;
        const executor = self.task.getExecutor();
        const now_ms = executor.loop.now();
        self.deadline_ns = @intCast((now_ms + @as(i64, @intCast(timeout_ms))) * 1_000_000);

        // Remove from heap if already present (will re-insert with new deadline)
        if (self.in_heap) {
            self.task.timeout_heap.remove(self);
        }

        // Insert with new deadline
        self.task.timeout_heap.insert(self);
        self.in_heap = true;
    }

    /// Remove the timeout from the heap.
    /// Safe to call even if the timeout was never set or already removed.
    pub fn deinit(self: *Timeout, rt: *Runtime) void {
        _ = rt;
        if (self.in_heap) {
            self.task.timeout_heap.remove(self);
            self.in_heap = false;
        }
    }
};

/// Timeout heap comparator - orders by earliest deadline first
fn timeoutLess(ctx: void, a: *Timeout, b: *Timeout) bool {
    _ = ctx;
    return a.deadline_ns < b.deadline_ns;
}

/// Heap type for storing timeouts, ordered by earliest deadline
pub const TimeoutHeap = xev.heap.Intrusive(Timeout, void, timeoutLess);
