const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const AnyTask = @import("task.zig").AnyTask;

const Deadline = @TypeOf(xev.Loop.timer_next(undefined, 0));

/// A timeout that applies to all I/O operations on the current task.
/// Multiple Timeout instances can be nested - the earliest deadline always applies.
/// Timeouts are stack-allocated and managed via defer pattern.
///
/// When a timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const Timeout = struct {
    task: *AnyTask,
    heap: xev.heap.IntrusiveField(Timeout) = .{},
    deadline: Deadline = undefined,
    active: bool = false,
    triggered: bool = false,

    /// Initialize a Timeout for the current task.
    /// The Timeout must be deinitialized with deinit() when done.
    /// Panics if not called from within a coroutine.
    pub fn init(rt: *Runtime) Timeout {
        const task = rt.getCurrentTask() orelse @panic("Timeout.init requires active task");
        return .{ .task = task };
    }

    pub fn clear(self: *Timeout, rt: *Runtime) void {
        const executor = self.task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        if (self.active) {
            self.task.timeouts.remove(self);
            self.task.timeout_count -= 1;
            self.active = false;
        }
    }

    pub fn set(self: *Timeout, rt: *Runtime, timeout_ms: u64) void {
        const executor = self.task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        if (self.active) {
            self.task.timeouts.remove(self);
        } else {
            self.task.timeout_count += 1;
            self.active = true;
        }
        self.deadline = executor.loop.timer_next(timeout_ms);
        self.task.timeouts.insert(self);
        // TODO: start the timer if we are the first timeout
    }
};

/// Timeout heap comparator - orders by earliest deadline first
fn timeoutLess(_: void, a: *Timeout, b: *Timeout) bool {
    if (@typeInfo(Deadline) == .int) {
        return a.deadline < b.deadline;
    } else {
        const a_ns = a.deadline.sec * std.time.ns_per_s + a.deadline.nsec;
        const b_ns = b.deadline.sec * std.time.ns_per_s + b.deadline.nsec;
        return a_ns < b_ns;
    }
}

/// Heap type for storing timeouts, ordered by earliest deadline
pub const TimeoutHeap = xev.heap.Intrusive(Timeout, void, timeoutLess);

test "Timeout: smoke test" {
    // TODO: test real timeouts
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init(rt);
            defer timeout.clear(rt);

            timeout.set(rt, 100);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}
