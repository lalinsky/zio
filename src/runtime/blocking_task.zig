// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const ev = @import("../ev/root.zig");

const Runtime = @import("../runtime.zig").Runtime;
const Awaitable = @import("awaitable.zig").Awaitable;
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const Closure = @import("task.zig").Closure;
const onGroupTaskComplete = @import("group.zig").onGroupTaskComplete;

const assert = std.debug.assert;

pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    work: ev.Work,
    runtime: *Runtime,
    closure: Closure,

    pub const wait_node_vtable = WaitNode.VTable{};

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    /// Get the typed result from this task's closure.
    pub fn getResult(self: *AnyBlockingTask, comptime T: type) T {
        const result_ptr: *T = @ptrCast(@alignCast(self.closure.getResultPtr(AnyBlockingTask, self)));
        return result_ptr.*;
    }

    pub fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
        const self = fromAwaitable(awaitable);
        self.closure.free(AnyBlockingTask, rt, self);
    }

    pub fn create(
        runtime: *Runtime,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: Closure.Start,
    ) !*AnyBlockingTask {
        // Allocate task with closure
        const alloc_result = try Closure.alloc(
            AnyBlockingTask,
            runtime,
            result_len,
            result_alignment,
            context.len,
            context_alignment,
            start,
        );
        errdefer alloc_result.closure.free(AnyBlockingTask, runtime, alloc_result.task);

        const self = alloc_result.task;
        self.* = .{
            .awaitable = .{
                .kind = .blocking_task,
                .destroy_fn = &AnyBlockingTask.destroyFn,
                .wait_node = .{
                    .vtable = &AnyBlockingTask.wait_node_vtable,
                },
            },
            .work = ev.Work.init(workFunc, self),
            .runtime = runtime,
            .closure = alloc_result.closure,
        };

        // Set up the completion callback to be called when work completes
        self.work.c.userdata = self;
        self.work.c.callback = completionCallback;

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(AnyBlockingTask, self);
        @memcpy(context_dest, context);

        return self;
    }
};

// Work function for blocking tasks - runs in thread pool
fn workFunc(work: *ev.Work) void {
    const any_blocking_task: *AnyBlockingTask = @ptrCast(@alignCast(work.userdata.?));

    // Execute the user's blocking function
    // ev handles cancellation - if canceled, this won't be called
    any_blocking_task.closure.call(AnyBlockingTask, any_blocking_task);
}

// Completion callback - called by ev event loop when work finishes
fn completionCallback(
    _: *ev.Loop,
    completion: *ev.Completion,
) void {
    const any_blocking_task: *AnyBlockingTask = @ptrCast(@alignCast(completion.userdata.?));

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.awaitable.markComplete();

    // For group tasks, decrement counter and release group's reference
    if (any_blocking_task.awaitable.group_node.group) |group| {
        onGroupTaskComplete(group, any_blocking_task.runtime, &any_blocking_task.awaitable);
    }

    // Release the blocking task's reference and check for shutdown
    const runtime = any_blocking_task.runtime;
    runtime.releaseAwaitable(&any_blocking_task.awaitable, true);
}

const getNextExecutor = @import("../runtime.zig").getNextExecutor;

/// Spawn a blocking task with raw context bytes and start function.
/// Used by Runtime.spawnBlocking.
pub fn spawnBlockingTask(
    rt: *Runtime,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) !*AnyBlockingTask {
    const executor = try getNextExecutor(rt);
    const task = try AnyBlockingTask.create(
        rt,
        result_len,
        result_alignment,
        context,
        context_alignment,
        .{ .regular = start },
    );
    errdefer AnyBlockingTask.destroyFn(rt, &task.awaitable);

    rt.tasks.add(&task.awaitable);

    task.awaitable.ref_count.incr();
    executor.loop.add(&task.work.c);

    return task;
}
