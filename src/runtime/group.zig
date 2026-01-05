// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const meta = @import("../meta.zig");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const getNextExecutor = @import("../runtime.zig").getNextExecutor;
const JoinHandle = @import("../runtime.zig").JoinHandle;
const CompactWaitQueue = @import("../utils/wait_queue.zig").CompactWaitQueue;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const Awaitable = @import("awaitable.zig").Awaitable;
const AnyTask = @import("task.zig").AnyTask;
const CreateOptions = @import("task.zig").CreateOptions;
const ResetEvent = @import("../sync/ResetEvent.zig");

pub const Group = struct {
    state: std.atomic.Value(usize) = .init(0),
    completed: ResetEvent = .init,
    tasks: CompactWaitQueue(GroupNode) = .empty,

    pub const init: Group = .{};

    // State encoding:
    // - Bits 0-60: pending task counter
    // - Bit 61: fail_fast flag (if set, signal event early on error)
    // - Bit 62: failed flag (set when any task returns an error)
    // - Bit 63: canceled flag (set when group is canceled)
    const canceled_flag: usize = 1 << (@bitSizeOf(usize) - 1);
    const failed_flag: usize = 1 << (@bitSizeOf(usize) - 2);
    const fail_fast_flag: usize = 1 << (@bitSizeOf(usize) - 3);
    const counter_mask: usize = ~(canceled_flag | failed_flag | fail_fast_flag);

    /// Increment the pending task counter.
    pub fn incrCounter(self: *Group) void {
        _ = self.state.fetchAdd(1, .acq_rel);
    }

    /// Decrement the pending task counter. Returns true if this was the last task.
    pub fn decrCounter(self: *Group) bool {
        const prev = self.state.fetchSub(1, .acq_rel);
        return (prev & counter_mask) == 1;
    }

    /// Get the current counter value.
    pub fn getCounter(self: *Group) usize {
        return self.state.load(.acquire) & counter_mask;
    }

    /// Set the failed flag. If fail_fast is set, also signals the event.
    pub fn setFailed(self: *Group) void {
        const prev = self.state.fetchOr(failed_flag, .acq_rel);
        if ((prev & fail_fast_flag) != 0) {
            self.completed.set();
        }
    }

    /// Check if the failed flag is set.
    pub fn hasFailed(self: *Group) bool {
        return (self.state.load(.acquire) & failed_flag) != 0;
    }

    /// Set the canceled flag. If fail_fast is set, also signals the event.
    pub fn setCanceled(self: *Group) void {
        const prev = self.state.fetchOr(canceled_flag, .acq_rel);
        if ((prev & fail_fast_flag) != 0) {
            self.completed.set();
        }
    }

    /// Check if the canceled flag is set.
    pub fn isCanceled(self: *Group) bool {
        return (self.state.load(.acquire) & canceled_flag) != 0;
    }

    /// Set the fail_fast flag. When set, the group will signal early on first error.
    pub fn setFailFast(self: *Group) void {
        _ = self.state.fetchOr(fail_fast_flag, .acq_rel);
    }

    /// Check if the fail_fast flag is set.
    pub fn isFailFast(self: *Group) bool {
        return (self.state.load(.acquire) & fail_fast_flag) != 0;
    }

    pub fn spawn(self: *Group, rt: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
        const Args = @TypeOf(args);
        const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Wrapper = struct {
            fn start(group_ptr: *anyopaque, ctx: *const anyopaque) void {
                const group: *Group = @ptrCast(@alignCast(group_ptr));
                const a: *const Args = @ptrCast(@alignCast(ctx));
                const result = @call(.auto, func, a.*);

                // If the result is an error union and it's an error, set the appropriate flag
                if (@typeInfo(ReturnType) == .error_union) {
                    if (result) |_| {} else |err| {
                        if (err == error.Canceled) {
                            group.setCanceled();
                        } else {
                            group.setFailed();
                        }
                    }
                }
            }
        };

        // Increment counter before spawning
        self.incrCounter();
        errdefer _ = self.decrCounter();

        const executor = getNextExecutor(rt);
        const task = try AnyTask.create(
            executor,
            0, // result_len - group tasks return void
            .@"1", // result_alignment
            std.mem.asBytes(&args),
            .fromByteUnits(@alignOf(Args)),
            .{ .group = &Wrapper.start },
            .{},
        );
        errdefer task.closure.free(AnyTask, rt, task);

        // Associate the task with the group
        task.awaitable.group_node.group = self;
        self.tasks.push(&task.awaitable.group_node);
        errdefer _ = self.tasks.remove(&task.awaitable.group_node);

        rt.tasks.add(&task.awaitable);

        task.awaitable.ref_count.incr();
        executor.scheduleTask(task, .maybe_remote);
    }

    pub fn wait(group: *Group, rt: *Runtime) Cancelable!void {
        errdefer group.cancel(rt);
        try group.waitForRemainingTasks(rt, &group.tasks);
    }

    pub fn cancel(group: *Group, rt: *Runtime) void {
        rt.beginShield();
        defer rt.endShield();

        // Request cancellation for all tasks in the list
        var local_list: SimpleWaitQueue(GroupNode) = .empty;
        while (group.tasks.pop()) |node| {
            const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
            awaitable.cancel();
            local_list.push(node);
        }

        group.waitForRemainingTasks(rt, &local_list) catch unreachable;
    }

    fn waitForRemainingTasks(group: *Group, rt: *Runtime, tasks: anytype) Cancelable!void {
        try group.completed.wait(rt);
        while (tasks.pop()) |node| {
            const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
            rt.releaseAwaitable(awaitable, false);
        }
    }
};

pub const GroupNode = struct {
    group: ?*Group = null,

    next: ?*GroupNode = null,
    prev: ?*GroupNode = null,
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

    userdata: usize = undefined,
};

const Cancelable = @import("../common.zig").Cancelable;

fn testFn(arg: usize) usize {
    return arg + 1;
}

test "Group: spawn" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        fn asyncTask(runtime: *Runtime) !void {
            var group: Group = .init;
            defer group.cancel(runtime);

            try group.spawn(runtime, testFn, .{0});

            try group.wait(runtime);
        }
    };

    var handle = try rt.spawn(TestContext.asyncTask, .{rt}, .{});
    try handle.join(rt);
}

test "Group: wait for multiple tasks" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        var completed: usize = 0;

        fn task(_: *Runtime) void {
            _ = @atomicRmw(usize, &completed, .Add, 1, .monotonic);
        }

        fn asyncTask(runtime: *Runtime) !void {
            completed = 0;

            var group: Group = .init;
            defer group.cancel(runtime);

            try group.spawn(runtime, task, .{runtime});
            try group.spawn(runtime, task, .{runtime});
            try group.spawn(runtime, task, .{runtime});

            try group.wait(runtime);

            try std.testing.expectEqual(@as(usize, 3), completed);
        }
    };

    var handle = try rt.spawn(TestContext.asyncTask, .{rt}, .{});
    try handle.join(rt);
}

test "Group: cancellation while waiting" {
    const rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        var started: usize = 0;
        var canceled: usize = 0;

        fn slowTask(runtime: *Runtime) void {
            _ = @atomicRmw(usize, &started, .Add, 1, .monotonic);
            runtime.sleep(1000) catch {
                _ = @atomicRmw(usize, &canceled, .Add, 1, .monotonic);
            };
        }

        fn cancellerTask(runtime: *Runtime, group_handle: *JoinHandle(anyerror!void)) !void {
            // Wait a bit for tasks to start
            try runtime.sleep(10);
            // Cancel the group waiter
            group_handle.awaitable.?.cancel();
        }

        fn groupTask(runtime: *Runtime) anyerror!void {
            var group: Group = .init;
            defer group.cancel(runtime);

            // Spawn multiple slow tasks
            try group.spawn(runtime, slowTask, .{runtime});
            try group.spawn(runtime, slowTask, .{runtime});
            try group.spawn(runtime, slowTask, .{runtime});

            // This wait should be interrupted by cancellation
            group.wait(runtime) catch {};
        }

        fn asyncTask(runtime: *Runtime) !void {
            started = 0;
            canceled = 0;

            // Spawn the group task
            var group_handle = try runtime.spawn(groupTask, .{runtime}, .{});

            // Spawn a task that will cancel the group task
            var canceller = try runtime.spawn(cancellerTask, .{ runtime, &group_handle }, .{});
            defer canceller.cancel(runtime);

            // Wait for group task to complete (should be canceled)
            try group_handle.join(runtime);

            // All tasks should have been canceled
            try std.testing.expectEqual(@as(usize, 3), started);
            try std.testing.expectEqual(@as(usize, 3), canceled);
        }
    };

    var handle = try rt.spawn(TestContext.asyncTask, .{rt}, .{});
    try handle.join(rt);
}
