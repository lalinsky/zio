const std = @import("std");
const builtin = @import("builtin");
const meta = @import("../meta.zig");
const Runtime = @import("../runtime.zig").Runtime;
const JoinHandle = @import("../runtime.zig").JoinHandle;
const CompactWaitQueue = @import("../utils/wait_queue.zig").CompactWaitQueue;
const SimpleWaitQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const Awaitable = @import("awaitable.zig").Awaitable;
const select = @import("../select.zig");

pub const Group = struct {
    state: usize,
    context: ?*anyopaque,
    token: ?*anyopaque,

    pub const init: Group = .{ .state = 0, .context = null, .token = null };

    fn getList(self: *Group) *CompactWaitQueue(GroupNode) {
        return @ptrCast(&self.token);
    }

    pub fn spawn(self: *Group, rt: *Runtime, func: anytype, args: meta.ArgsType(func)) !void {
        const handle = try rt.spawn(func, args, .{});
        if (handle.awaitable) |awaitable| {
            const list = self.getList();
            awaitable.group_node.group = self;
            list.push(&awaitable.group_node);
        }
    }

    pub fn spawnBlocking(self: *Group, rt: *Runtime, func: anytype, args: meta.ArgsType(func)) !void {
        const handle = try rt.spawnBlocking(func, args);
        if (handle.awaitable) |awaitable| {
            const list = self.getList();
            awaitable.group_node.group = self;
            list.push(&awaitable.group_node);
        }
    }

    pub fn wait(group: *Group, rt: *Runtime) void {
        const list = group.getList();
        while (list.pop()) |node| {
            const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
            node.group = null;

            // Wait for completion - if canceled, cancel remaining tasks
            _ = select.wait(rt, awaitable) catch {
                // We were canceled while waiting - push the node back
                node.group = group;
                list.push(node);

                // Enter shield mode and cancel all remaining tasks
                rt.beginShield();
                group.cancel(rt);
                rt.endShield();
                return;
            };

            // Release the awaitable
            rt.releaseAwaitable(awaitable, false);
        }
    }

    pub fn cancel(group: *Group, rt: *Runtime) void {
        const list = group.getList();

        while (true) {
            // Pop all nodes into a local list, canceling as we go
            var local_list: SimpleWaitQueue(GroupNode) = .empty;
            while (list.pop()) |node| {
                node.group = null;
                const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
                if (awaitable.done.load(.acquire)) {
                    // Already done, just release
                    rt.releaseAwaitable(awaitable, false);
                } else {
                    // Request cancellation and queue for waiting
                    awaitable.cancel();
                    local_list.push(node);
                }
            }

            // If nothing needs waiting, we're done
            if (local_list.isEmpty()) break;

            // Wait for completion and release
            while (local_list.pop()) |node| {
                const awaitable: *Awaitable = @fieldParentPtr("group_node", node);
                select.waitUntilComplete(rt, awaitable);
                rt.releaseAwaitable(awaitable, false);
            }
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

            group.wait(runtime);
        }
    };

    try rt.runUntilComplete(TestContext.asyncTask, .{rt}, .{});
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

            group.wait(runtime);

            try std.testing.expectEqual(@as(usize, 3), completed);
        }
    };

    try rt.runUntilComplete(TestContext.asyncTask, .{rt}, .{});
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
            group.wait(runtime);
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

    try rt.runUntilComplete(TestContext.asyncTask, .{rt}, .{});
}
