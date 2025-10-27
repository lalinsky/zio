const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const AnyTask = @import("task.zig").AnyTask;

/// A timeout that applies to all I/O operations on the current task.
/// Multiple Timeout instances can be nested - the earliest deadline always applies.
/// Timeouts are stack-allocated and managed via defer pattern.
///
/// When a timeout expires, operations return error.Canceled and the `triggered` field is set to true,
/// allowing the caller to distinguish timeout-induced cancellation from explicit cancellation.
pub const Timeout = struct {
    task: *AnyTask,
    heap: xev.heap.IntrusiveField(Timeout) = .{},
    deadline_ms: i64 = undefined,
    active: bool = false,
    triggered: bool = false,

    /// Initialize a Timeout for the current task.
    /// The Timeout must be cleared with clear() when done.
    /// Panics if not called from within a coroutine.
    pub fn init(rt: *Runtime) Timeout {
        const task = rt.getCurrentTask() orelse @panic("Timeout.init requires active task");
        return .{ .task = task };
    }

    pub fn clear(self: *Timeout, rt: *Runtime) void {
        const executor = self.task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        if (self.active) {
            self.active = false;
            self.task.timeout_count -= 1;
            self.task.timeouts.remove(self);
            self.task.maybeUpdateTimer();
        }
    }

    pub fn set(self: *Timeout, rt: *Runtime, timeout_ns: u64) void {
        const executor = self.task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        if (self.active) {
            self.task.timeouts.remove(self);
        } else {
            self.active = true;
            self.task.timeout_count += 1;
        }
        self.triggered = false;
        const timeout_ms: i64 = @intCast(timeout_ns / std.time.ns_per_ms);
        self.deadline_ms = executor.loop.now() + timeout_ms;
        self.task.timeouts.insert(self);
        self.task.maybeUpdateTimer();
    }
};

/// Timeout heap comparator - orders by earliest deadline first
fn timeoutLess(_: void, a: *Timeout, b: *Timeout) bool {
    return a.deadline_ms < b.deadline_ms;
}

/// Heap type for storing timeouts, ordered by earliest deadline
pub const TimeoutHeap = xev.heap.Intrusive(Timeout, void, timeoutLess);

test "Timeout: smoke test" {
    // TODO: test real timeouts
    const Test = struct {
        fn main(rt: *Runtime) !void {
            var timeout = Timeout.init(rt);
            defer timeout.clear(rt);

            timeout.set(rt, 100 * std.time.ns_per_ms);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}
