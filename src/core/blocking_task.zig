// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Awaitable = @import("awaitable.zig").Awaitable;
const FutureImpl = @import("awaitable.zig").FutureImpl;
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const Closure = @import("task.zig").Closure;

const assert = std.debug.assert;

pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    thread_pool_task: xev.ThreadPool.Task,
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
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        destroy_fn: *const fn (*Runtime, *Awaitable) void,
    ) !*AnyBlockingTask {
        var allocation_size: usize = @sizeOf(AnyBlockingTask);

        // Reserve space for result
        if (result_len > Closure.max_result_len) return error.ResultTooLarge;
        if (result_alignment.toByteUnits() > Closure.max_result_alignment) return error.ResultTooLarge;
        const result_padding = result_alignment.forward(allocation_size) - allocation_size;
        allocation_size += result_padding + result_len;

        // Reserve space for context
        if (context.len > Closure.max_context_len) return error.ContextTooLarge;
        if (context_alignment.toByteUnits() > Closure.max_context_alignment) return error.ContextTooLarge;
        const context_padding = context_alignment.forward(allocation_size) - allocation_size;
        allocation_size += context_padding + context.len;

        // Allocate task
        const allocation = try runtime.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(AnyBlockingTask)), allocation_size);
        errdefer runtime.allocator.free(allocation);

        const self: *AnyBlockingTask = @ptrCast(allocation.ptr);
        self.* = .{
            .awaitable = .{
                .kind = .blocking_task,
                .destroy_fn = destroy_fn,
                .wait_node = .{
                    .vtable = &AnyBlockingTask.wait_node_vtable,
                },
            },
            .thread_pool_task = .{ .callback = threadPoolCallback },
            .runtime = runtime,
            .closure = .{
                .start = start,
                .result_padding = @intCast(result_padding),
                .result_len = @intCast(result_len),
                .context_padding = @intCast(context_padding),
                .context_len = @intCast(context.len),
            },
        };

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(AnyBlockingTask, self);
        @memcpy(context_dest, context);

        return self;
    }
};

// Thread pool callback for blocking tasks
fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
    const any_blocking_task: *AnyBlockingTask = @fieldParentPtr("thread_pool_task", task);

    // Check if the task was canceled before it started executing
    if (any_blocking_task.awaitable.canceled_status.load(.acquire) == 0) {
        // Execute the user's blocking function only if not canceled
        const c = &any_blocking_task.closure;
        const result = c.getResultPtr(AnyBlockingTask, any_blocking_task);
        const context = c.getContextPtr(AnyBlockingTask, any_blocking_task);
        c.start(context, result);
    }

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.awaitable.markComplete();

    // Release the blocking task's reference and check for shutdown
    const runtime = any_blocking_task.runtime;
    runtime.releaseAwaitable(&any_blocking_task.awaitable, true);
}

// Typed blocking task that wraps AnyBlockingTask
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();

        base: AnyBlockingTask,

        pub const Result = T;

        pub fn fromAny(any_blocking_task: *AnyBlockingTask) *Self {
            return @fieldParentPtr("base", any_blocking_task);
        }

        pub fn fromAwaitable(awaitable: *Awaitable) *Self {
            return fromAny(AnyBlockingTask.fromAwaitable(awaitable));
        }

        pub fn toAwaitable(self: *Self) *Awaitable {
            return &self.base.awaitable;
        }

        pub fn cancel(self: *Self) void {
            self.base.awaitable.cancel();
        }

        pub fn wait(self: *Self, runtime: *Runtime) !T {
            try self.base.awaitable.wait(runtime);
            return self.getResult();
        }

        pub fn asyncWait(self: *Self, comptime options: Awaitable.AsyncWaitOptions) Awaitable.AsyncWaitResult(options) {
            return self.base.awaitable.asyncWait(options);
        }

        pub fn asyncCancelWait(self: *Self, comptime options: Awaitable.AsyncWaitOptions) Awaitable.AsyncCancelWaitResult(options) {
            return self.base.awaitable.asyncCancelWait(options);
        }

        pub fn deinit(_: *Self) void {
            // Result stored inline, no separate deallocation needed
        }

        fn getResultPtr(self: *Self) *T {
            const c = &self.base.closure;
            const result_ptr = c.getResultPtr(AnyBlockingTask, &self.base);
            return @ptrCast(@alignCast(result_ptr));
        }

        pub fn getResult(self: *Self) T {
            return self.getResultPtr().*;
        }

        pub fn getRuntime(self: *Self) *Runtime {
            return self.base.runtime;
        }

        pub fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
            const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
            const allocation = any_blocking_task.closure.getAllocationSlice(AnyBlockingTask, any_blocking_task);
            rt.allocator.free(allocation);
        }

        pub fn create(
            runtime: *Runtime,
            func: anytype,
            args: meta.ArgsType(func),
        ) !*Self {
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
                &Wrapper.start,
                &Self.destroyFn,
            );

            return Self.fromAny(any_blocking_task);
        }

        pub fn destroy(self: *Self, runtime: *Runtime) void {
            self.base.awaitable.destroy_fn(runtime, &self.base.awaitable);
        }
    };
}
