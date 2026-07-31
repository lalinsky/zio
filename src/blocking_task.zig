// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const ev = @import("ev/root.zig");

const Runtime = @import("runtime.zig").Runtime;
const getCurrentExecutorOrNull = @import("runtime.zig").getCurrentExecutorOrNull;
const syscall_cancel = @import("os/root.zig").syscall_cancel;
const Awaitable = @import("awaitable.zig").Awaitable;
const Closure = @import("task.zig").Closure;
const finishTask = @import("task.zig").finishTask;
const Group = @import("group.zig").Group;
const registerGroupTask = @import("group.zig").registerGroupTask;
const unregisterGroupTask = @import("group.zig").unregisterGroupTask;

const assert = std.debug.assert;

pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    work: ev.Work,
    runtime: *Runtime,
    closure: Closure,

    /// Bound by the pool worker around the task's function (via
    /// `work.cancel_token`), so a `SIGURG` from `cancel()` can interrupt a
    /// cancelable blocking syscall or `Waiter` park inside it.
    token: syscall_cancel.Token = .{},

    // Guards cancel(): only the first caller arms cancellation and takes the
    // keep-alive ref.
    user_canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    /// Get the typed result from this task's closure.
    pub fn getResult(self: *AnyBlockingTask, comptime T: type) T {
        // Sanity checks before unsafe casting
        if (std.debug.runtime_safety) {
            std.debug.assert(self.awaitable.hasResult()); // Task must be completed
            std.debug.assert(@sizeOf(T) == self.closure.result_len); // Size must match
            std.debug.assert(@alignOf(T) <= Closure.max_result_alignment); // Alignment must fit
        }

        const result_ptr: *T = @ptrCast(@alignCast(self.closure.getResultPtr(AnyBlockingTask, self)));
        return result_ptr.*;
    }

    /// Request cancellation of this blocking task.
    ///
    /// Cancels the pool work (first `SIGURG`) and, if the worker is blocked in a
    /// cancelable syscall, arms the current loop's resend so `tick` re-sends
    /// until the worker acknowledges. A keep-alive ref is taken so the work (and
    /// its token) cannot be freed while it may sit on the loop's resend list; it
    /// is released via `onResendRelease` when the entry is dropped (or right away
    /// when no resend is armed).
    pub fn cancel(self: *AnyBlockingTask) void {
        // Only the first caller arms cancellation and takes the ref.
        if (self.user_canceled.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

        self.awaitable.ref_count.incr();
        self.work.resend_release = onResendRelease;

        if (getCurrentExecutorOrNull()) |exec| {
            exec.loop.cancelWork(&self.work);
        } else {
            // Not on a loop thread, so there is no ticking loop here to drive the
            // SIGURG resend: best-effort single signal, then drop the ref.
            self.runtime.thread_pool.cancel(&self.work);
            onResendRelease(&self.work);
        }
    }

    /// Drop the keep-alive ref taken by `cancel()`. Runs on the loop thread when
    /// the resend entry is dropped (or inline when no resend was armed).
    fn onResendRelease(work: *ev.Work) void {
        const self: *AnyBlockingTask = @fieldParentPtr("work", work);
        self.awaitable.release();
    }

    pub inline fn getRuntime(self: *AnyBlockingTask) *Runtime {
        return self.runtime;
    }

    pub fn destroy(self: *AnyBlockingTask) void {
        self.closure.free(AnyBlockingTask, self.getRuntime(), self);
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
                .wait_node = .{},
            },
            .work = ev.Work.init(workFunc, self),
            .runtime = runtime,
            .closure = alloc_result.closure,
        };

        // Set up the thread pool completion callback
        self.work.completion_fn = threadPoolCompletion;
        self.work.completion_context = self;

        // Bind the cancel token so the worker enters/exits it around the task's
        // function, making cancelable syscalls (and Waiter parks) interruptible.
        self.work.cancel_token = &self.token;

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(AnyBlockingTask, self);
        @memcpy(context_dest, context);

        return self;
    }
};

// Work function for blocking tasks - runs in thread pool
fn workFunc(work: *ev.Work) void {
    const task: *AnyBlockingTask = @ptrCast(@alignCast(work.userdata.?));

    // Execute the user's blocking function. Token-bearing work always runs; a
    // cancellation is delivered by SIGURG interrupting a cancelable syscall (or
    // Waiter park) inside the function, which surfaces as error.Canceled in the
    // function's own result.
    task.closure.call(AnyBlockingTask, task);
}

// Completion callback - called by thread pool worker thread when work finishes.
// All operations here must be thread-safe as this runs on a foreign thread.
fn threadPoolCompletion(ctx: ?*anyopaque, work: *ev.Work) void {
    const task: *AnyBlockingTask = @ptrCast(@alignCast(ctx));
    _ = work;

    // Cancellation, if any, was already delivered in-band as the function's
    // error.Canceled result; nothing extra to do here beyond finishing.
    finishTask(task.runtime, &task.awaitable);
}

/// Register a blocking task with the runtime and submit it for execution.
/// Increments the task count and submits the task to the thread pool.
/// Returns error.RuntimeShutdown if the runtime is shutting down.
fn registerBlockingTask(rt: *Runtime, task: *AnyBlockingTask) error{RuntimeShutdown}!void {
    // Check if runtime is shutting down before incrementing counter
    if (rt.shutting_down.load(.acquire)) {
        return error.RuntimeShutdown;
    }

    // Do NOT increment ref_count here. Unlike registerTask (task.zig), this would
    // add a third reference that is never released: the init ref (=1) is dropped by
    // finishTask via threadPoolCompletion, and the caller (JoinHandle) ref is added
    // in spawnBlockingTask before submit and dropped by join()/cancel()/detach().
    // The extra incr orphans one reference and leaks the blocking-task allocation.
    // It is masked for pool-sized tasks (pool.deinit frees the backing buffer) and
    // only observable for tasks larger than pool_item_size (direct allocator path).
    _ = rt.task_count.fetchAdd(1, .acq_rel);
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
    errdefer task.destroy();

    // +1 ref before the task is reachable by anyone else, to prevent a race
    // where it completes before the caller can take ownership. See spawnTask
    // for why this has to come before registerGroupTask.
    task.awaitable.ref_count.incr();
    errdefer _ = task.awaitable.ref_count.decr();

    if (group) |g| try registerGroupTask(g, &task.awaitable);
    errdefer if (group) |g| unregisterGroupTask(g, &task.awaitable);

    try registerBlockingTask(rt, task);

    return task;
}
