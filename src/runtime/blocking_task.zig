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
const Group = @import("group.zig").Group;
const registerGroupTask = @import("group.zig").registerGroupTask;
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
        // Sanity checks before unsafe casting
        if (std.debug.runtime_safety) {
            std.debug.assert(self.awaitable.done.load(.acquire)); // Task must be completed
            std.debug.assert(@sizeOf(T) == self.closure.result_len); // Size must match
            std.debug.assert(@alignOf(T) <= Closure.max_result_alignment); // Alignment must fit
        }

        const result_ptr: *T = @ptrCast(@alignCast(self.closure.getResultPtr(AnyBlockingTask, self)));
        return result_ptr.*;
    }

    /// Cancel this blocking task by setting canceled status and canceling the thread pool work.
    pub fn cancel(self: *AnyBlockingTask) void {
        self.awaitable.setCanceled();
        // TODO: Actually cancel the task via thread pool
        // self.runtime.thread_pool.cancel(&self.work);
    }

    pub fn destroy(self: *AnyBlockingTask, rt: *Runtime) void {
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
                .wait_node = .{
                    .vtable = &AnyBlockingTask.wait_node_vtable,
                },
            },
            .work = ev.Work.init(workFunc, self),
            .runtime = runtime,
            .closure = alloc_result.closure,
        };

        // Set up the thread pool completion callback
        self.work.completion_fn = threadPoolCompletion;
        self.work.completion_context = self;

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(AnyBlockingTask, self);
        @memcpy(context_dest, context);

        return self;
    }
};

// Work function for blocking tasks - runs in thread pool
fn workFunc(work: *ev.Work) void {
    const task: *AnyBlockingTask = @ptrCast(@alignCast(work.userdata.?));

    // Execute the user's blocking function
    // ev handles cancellation - if canceled, this won't be called
    task.closure.call(AnyBlockingTask, task);
}

// Completion callback - called by thread pool worker thread when work finishes.
// All operations here must be thread-safe as this runs on a foreign thread.
fn threadPoolCompletion(ctx: ?*anyopaque, work: *ev.Work) void {
    const task: *AnyBlockingTask = @ptrCast(@alignCast(ctx));

    // TODO: Handle error case (work.c.err) when task was canceled
    _ = work;

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    task.awaitable.markComplete();

    // For group tasks, decrement counter and release group's reference
    if (task.awaitable.group_node.group) |group| {
        onGroupTaskComplete(group, task.runtime, &task.awaitable);
    }

    // Release the blocking task's reference and check for shutdown
    task.runtime.releaseAwaitable(&task.awaitable, true);
}

/// Register a blocking task with the runtime and submit it for execution.
/// Increments its reference count, adds the task to the runtime's task list,
/// and submits it directly to the thread pool.
fn registerBlockingTask(rt: *Runtime, task: *AnyBlockingTask) void {
    task.awaitable.ref_count.incr();
    rt.tasks.add(&task.awaitable);
    rt.thread_pool.submit(&task.work);
}

/// Spawn a blocking task with raw context bytes and start function.
/// Used by Runtime.spawnBlocking and Group.spawnBlocking.
/// Thread-safe: can be called from any thread.
pub fn spawnBlockingTask(
    rt: *Runtime,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: Closure.Start,
    group: ?*Group,
) !*AnyBlockingTask {
    const task = try AnyBlockingTask.create(
        rt,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
    );
    errdefer task.destroy(rt);

    if (group) |g| {
        try registerGroupTask(g, &task.awaitable);
    }

    registerBlockingTask(rt, task);

    return task;
}
