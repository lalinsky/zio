// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const Allocator = std.mem.Allocator;
const aio = @import("../aio/root.zig");

const Runtime = @import("../runtime.zig").Runtime;
const Awaitable = @import("awaitable.zig").Awaitable;
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const Closure = @import("task.zig").Closure;

const assert = std.debug.assert;

pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    work: aio.Work,
    runtime: *Runtime,
    closure: Closure,

    pub const wait_node_vtable = WaitNode.VTable{};

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub fn create(
        runtime: *Runtime,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: Closure.Start,
        destroy_fn: *const fn (*Runtime, *Awaitable) void,
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
                .destroy_fn = destroy_fn,
                .wait_node = .{
                    .vtable = &AnyBlockingTask.wait_node_vtable,
                },
            },
            .work = aio.Work.init(workFunc, self),
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
fn workFunc(work: *aio.Work) void {
    const any_blocking_task: *AnyBlockingTask = @ptrCast(@alignCast(work.userdata.?));

    // Execute the user's blocking function
    // aio handles cancellation - if canceled, this won't be called
    any_blocking_task.closure.call(AnyBlockingTask, any_blocking_task, any_blocking_task.awaitable.group_node.group);
}

// Completion callback - called by aio event loop when work finishes
fn completionCallback(
    _: *aio.Loop,
    completion: *aio.Completion,
) void {
    const any_blocking_task: *AnyBlockingTask = @ptrCast(@alignCast(completion.userdata.?));

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.awaitable.markComplete();

    // For group tasks, remove from group list and release group's reference
    // Only release if we successfully removed it (groupCancel might have popped it first)
    if (any_blocking_task.awaitable.group_node.group) |group| {
        if (group.tasks.remove(&any_blocking_task.awaitable.group_node)) {
            const runtime = any_blocking_task.runtime;
            runtime.releaseAwaitable(&any_blocking_task.awaitable, false);
        }
    }

    // Release the blocking task's reference and check for shutdown
    const runtime = any_blocking_task.runtime;
    runtime.releaseAwaitable(&any_blocking_task.awaitable, true);
}

// Typed blocking task that wraps a pointer to AnyBlockingTask
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();

        task: *AnyBlockingTask,

        pub const Result = T;

        pub fn fromAny(any_blocking_task: *AnyBlockingTask) Self {
            return Self{ .task = any_blocking_task };
        }

        pub fn fromAwaitable(awaitable: *Awaitable) Self {
            return fromAny(AnyBlockingTask.fromAwaitable(awaitable));
        }

        pub fn toAwaitable(self: Self) *Awaitable {
            return &self.task.awaitable;
        }

        pub fn cancel(self: Self) void {
            self.task.awaitable.cancel();
        }

        pub fn wait(self: Self, runtime: *Runtime) !T {
            try self.task.awaitable.wait(runtime);
            return self.getResult();
        }

        pub fn asyncWait(self: Self, comptime options: Awaitable.AsyncWaitOptions) Awaitable.AsyncWaitResult(options) {
            return self.task.awaitable.asyncWait(options);
        }

        pub fn asyncCancelWait(self: Self, comptime options: Awaitable.AsyncWaitOptions) Awaitable.AsyncCancelWaitResult(options) {
            return self.task.awaitable.asyncCancelWait(options);
        }

        pub fn deinit(_: Self) void {
            // Result stored inline, no separate deallocation needed
        }

        fn getResultPtr(self: Self) *T {
            const c = &self.task.closure;
            const result_ptr = c.getResultPtr(AnyBlockingTask, self.task);
            return @ptrCast(@alignCast(result_ptr));
        }

        pub fn getResult(self: Self) T {
            return self.getResultPtr().*;
        }

        pub fn getRuntime(self: Self) *Runtime {
            return self.task.runtime;
        }

        pub fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
            const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
            any_blocking_task.closure.free(AnyBlockingTask, rt, any_blocking_task);
        }

        pub fn create(
            runtime: *Runtime,
            func: anytype,
            args: std.meta.ArgsTuple(@TypeOf(func)),
        ) !Self {
            const Wrapper = struct {
                fn start(ctx: *const anyopaque, result: *anyopaque) void {
                    const a: *const @TypeOf(args) = @ptrCast(@alignCast(ctx));
                    const r: *T = @ptrCast(@alignCast(result));
                    r.* = @call(.always_inline, func, a.*);
                }
            };

            const any_blocking_task = try AnyBlockingTask.create(
                runtime,
                @sizeOf(T),
                .fromByteUnits(@alignOf(T)),
                std.mem.asBytes(&args),
                .fromByteUnits(@alignOf(@TypeOf(args))),
                .{ .regular = &Wrapper.start },
                &Self.destroyFn,
            );

            return Self.fromAny(any_blocking_task);
        }

        pub fn destroy(self: Self, runtime: *Runtime) void {
            self.task.awaitable.destroy_fn(runtime, &self.task.awaitable);
        }
    };
}
