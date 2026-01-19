// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const meta = @import("../meta.zig");
const Runtime = @import("../runtime.zig").Runtime;
const JoinHandle = @import("../runtime.zig").JoinHandle;
const CompactWaitQueue = @import("../utils/wait_queue.zig").CompactWaitQueue;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const Awaitable = @import("awaitable.zig").Awaitable;
const AnyTask = @import("task.zig").AnyTask;
const spawnTask = @import("task.zig").spawnTask;
const AnyBlockingTask = @import("blocking_task.zig").AnyBlockingTask;
const spawnBlockingTask = @import("blocking_task.zig").spawnBlockingTask;
const Futex = @import("../sync/Futex.zig");

/// Matches std.Io.Group layout exactly for future vtable compatibility.
pub const IoGroup = extern struct {
    token: std.atomic.Value(?*anyopaque) = .init(null),
    state: usize = 0,
};

pub const Group = struct {
    inner: IoGroup = .{},

    pub const init: Group = .{};

    // Interpret inner.token as CompactWaitQueue head
    //   null (0)  = sentinel0 = idle/done
    //   1         = sentinel1 = closing (reject new spawns)
    //   pointer   = has tasks

    // Interpret inner.state as State
    pub const State = extern struct {
        counter: u32 = 0, // pending task count, also futex target
        flags: u32 = 0, // atomic Or/And for flag bits
    };

    comptime {
        std.debug.assert(@sizeOf(State) == @sizeOf(usize));
    }

    const canceled_bit: u32 = 1 << 0;
    const failed_bit: u32 = 1 << 1;
    const fail_fast_bit: u32 = 1 << 2;
    const closed_bit: u32 = 1 << 3;

    fn getTasks(self: *Group) *CompactWaitQueue(GroupNode) {
        return @ptrCast(&self.inner.token);
    }

    fn getStatePtr(self: *Group) *State {
        return @ptrCast(&self.inner.state);
    }

    fn getCounter(self: *Group) *u32 {
        return &self.getStatePtr().counter;
    }

    fn getFlags(self: *Group) *u32 {
        return &self.getStatePtr().flags;
    }

    /// Set the failed flag.
    pub fn setFailed(self: *Group) void {
        _ = @atomicRmw(u32, self.getFlags(), .Or, failed_bit | closed_bit, .acq_rel);
    }

    /// Check if the failed flag is set.
    pub fn hasFailed(self: *Group) bool {
        return (@atomicLoad(u32, self.getFlags(), .acquire) & failed_bit) != 0;
    }

    /// Set the canceled flag.
    pub fn setCanceled(self: *Group) void {
        _ = @atomicRmw(u32, self.getFlags(), .Or, canceled_bit | closed_bit, .acq_rel);
    }

    /// Check if the canceled flag is set.
    pub fn isCanceled(self: *Group) bool {
        return (@atomicLoad(u32, self.getFlags(), .acquire) & canceled_bit) != 0;
    }

    /// Set the fail_fast flag.
    // TODO: Implement early wake on first error/cancel when fail_fast is set
    pub fn setFailFast(self: *Group) void {
        _ = @atomicRmw(u32, self.getFlags(), .Or, fail_fast_bit, .acq_rel);
    }

    /// Check if the fail_fast flag is set.
    pub fn isFailFast(self: *Group) bool {
        return (@atomicLoad(u32, self.getFlags(), .acquire) & fail_fast_bit) != 0;
    }

    fn setClosed(self: *Group) void {
        _ = @atomicRmw(u32, self.getFlags(), .Or, closed_bit, .acq_rel);
    }

    fn isClosed(self: *Group) bool {
        return (@atomicLoad(u32, self.getFlags(), .acquire) & closed_bit) != 0;
    }

    pub fn spawn(self: *Group, rt: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
        const Args = @TypeOf(args);
        const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Context = struct { group: *Group, args: Args };
        const Wrapper = struct {
            fn start(ctx: *const anyopaque) Cancelable!void {
                const context: *const Context = @ptrCast(@alignCast(ctx));
                const group = context.group;
                if (@typeInfo(ReturnType) == .error_union) {
                    @call(.auto, func, context.args) catch |err| {
                        if (err == error.Canceled) {
                            group.setCanceled();
                            return error.Canceled;
                        } else {
                            group.setFailed();
                        }
                    };
                } else {
                    _ = @call(.auto, func, context.args);
                }
            }
        };

        const context: Context = .{ .group = self, .args = args };
        return groupSpawnTask(self, rt, std.mem.asBytes(&context), .fromByteUnits(@alignOf(Context)), &Wrapper.start);
    }

    pub fn spawnBlocking(self: *Group, rt: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
        const Args = @TypeOf(args);
        const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Context = struct { group: *Group, args: Args };
        const Wrapper = struct {
            fn start(ctx: *const anyopaque, _: *anyopaque) void {
                const context: *const Context = @ptrCast(@alignCast(ctx));
                const group = context.group;
                if (@typeInfo(ReturnType) == .error_union) {
                    @call(.auto, func, context.args) catch |err| {
                        if (err == error.Canceled) {
                            group.setCanceled();
                        } else {
                            group.setFailed();
                        }
                    };
                } else {
                    _ = @call(.auto, func, context.args);
                }
            }
        };

        const context: Context = .{ .group = self, .args = args };
        return groupSpawnBlockingTask(self, rt, std.mem.asBytes(&context), .fromByteUnits(@alignOf(Context)), &Wrapper.start);
    }

    pub fn wait(group: *Group, rt: *Runtime) Cancelable!void {
        group.setClosed();
        errdefer group.cancel(rt);

        // Wait for all tasks to complete
        const counter_ptr = group.getCounter();
        while (true) {
            const counter = @atomicLoad(u32, counter_ptr, .acquire);
            if (counter == 0) break;
            try Futex.wait(rt, counter_ptr, counter);
        }

        // All tasks completed - verify list is empty (sentinel0)
        // Tasks remove themselves in onGroupTaskComplete
        std.debug.assert(group.getTasks().getState() == .sentinel0);
    }

    pub fn cancel(group: *Group, rt: *Runtime) void {
        rt.beginShield();
        defer rt.endShield();

        group.setCanceled();

        // Pop all tasks and cancel them
        while (group.getTasks().popOrTransition(.sentinel0, .sentinel1)) |node| {
            const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
            awaitable.cancel();
            awaitable.release(rt);
        }

        // Wait for all tasks to complete
        const counter_ptr = group.getCounter();
        while (true) {
            const counter = @atomicLoad(u32, counter_ptr, .acquire);
            if (counter == 0) break;
            Futex.wait(rt, counter_ptr, counter) catch unreachable;
        }

        // Transition back to idle
        _ = group.getTasks().tryTransition(.sentinel1, .sentinel0);
    }
};

/// Spawn a task in the group with raw context bytes and start function.
/// Used by Group.spawn and std.Io vtable implementations.
pub fn groupSpawnTask(
    group: *Group,
    rt: *Runtime,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque) Cancelable!void,
) !void {
    _ = try spawnTask(rt, 0, .@"1", context, context_alignment, .{ .group = start }, group);
}

/// Spawn a blocking task in the group with raw context bytes and start function.
/// Used by Group.spawnBlocking.
pub fn groupSpawnBlockingTask(
    group: *Group,
    rt: *Runtime,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) !void {
    _ = try spawnBlockingTask(rt, 0, .@"1", context, context_alignment, .{ .regular = start }, group);
}

/// Register an awaitable with a group.
/// Increments counter, sets group_node.group, and adds to task list.
/// Returns error.Closed if group is closed.
pub fn registerGroupTask(group: *Group, awaitable: *Awaitable) error{Closed}!void {
    if (group.isClosed()) return error.Closed;
    _ = @atomicRmw(u32, group.getCounter(), .Add, 1, .acq_rel);
    awaitable.group_node.group = group;
    if (!group.getTasks().pushUnless(.sentinel1, &awaitable.group_node)) {
        _ = @atomicRmw(u32, group.getCounter(), .Sub, 1, .acq_rel);
        return error.Closed;
    }
}

/// Unregister an awaitable from a group.
/// Removes from task list, releases ref, decrements counter, and wakes waiters if last task.
pub fn unregisterGroupTask(rt: *Runtime, group: *Group, awaitable: *Awaitable) void {
    // Only release if we successfully removed it (cancel might have popped it first)
    if (group.getTasks().remove(&awaitable.group_node)) {
        awaitable.release(rt);
    }

    const counter_ptr = group.getCounter();
    if (@atomicRmw(u32, counter_ptr, .Sub, 1, .acq_rel) == 1) {
        Futex.wake(rt, counter_ptr, std.math.maxInt(u32));
    }
}

pub const GroupNode = struct {
    group: ?*Group = null,

    next: ?*GroupNode = null,
    prev: ?*GroupNode = null,
    in_list: bool = false,

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

    var handle = try rt.spawn(TestContext.asyncTask, .{rt});
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

    var handle = try rt.spawn(TestContext.asyncTask, .{rt});
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
            runtime.sleep(.fromMilliseconds(1000)) catch {
                _ = @atomicRmw(usize, &canceled, .Add, 1, .monotonic);
            };
        }

        fn cancellerTask(runtime: *Runtime, group_handle: *JoinHandle(anyerror!void)) !void {
            // Wait a bit for tasks to start
            try runtime.sleep(.fromMilliseconds(10));
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
            var group_handle = try runtime.spawn(groupTask, .{runtime});

            // Spawn a task that will cancel the group task
            var canceller = try runtime.spawn(cancellerTask, .{ runtime, &group_handle });
            defer canceller.cancel(runtime);

            // Wait for group task to complete (should be canceled)
            try group_handle.join(runtime);

            // All tasks should have been canceled
            try std.testing.expectEqual(@as(usize, 3), started);
            try std.testing.expectEqual(@as(usize, 3), canceled);
        }
    };

    var handle = try rt.spawn(TestContext.asyncTask, .{rt});
    try handle.join(rt);
}
