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
    task: ?*AnyTask = null,
    heap: xev.heap.IntrusiveField(Timeout) = .{},
    deadline_ms: i64 = undefined,
    triggered: bool = false,

    pub const init: Timeout = .{};

    pub fn clear(self: *Timeout, rt: *Runtime) void {
        const task = self.task orelse return;
        const executor = task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        task.timeouts.remove(self);
        task.maybeUpdateTimer();
        self.task = null;
    }

    pub fn set(self: *Timeout, rt: *Runtime, timeout_ns: u64) void {
        const task = self.task orelse rt.getCurrentTask() orelse unreachable;

        const executor = task.getExecutor();
        std.debug.assert(executor.runtime == rt);

        if (self.task == null) {
            self.task = task;
        } else {
            task.timeouts.remove(self);
        }

        self.triggered = false;
        const timeout_ms: i64 = @intCast((timeout_ns + std.time.ns_per_ms / 2) / std.time.ns_per_ms);
        self.deadline_ms = executor.loop.now() + timeout_ms;
        task.timeouts.insert(self);
        task.maybeUpdateTimer();
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
            var timeout = Timeout.init;
            defer timeout.clear(rt);

            timeout.set(rt, 100 * std.time.ns_per_ms);
        }
    };

    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(Test.main, .{rt}, .{});
}
