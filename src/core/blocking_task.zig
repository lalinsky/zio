// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Awaitable = @import("awaitable.zig").Awaitable;
const FutureImpl = @import("awaitable.zig").FutureImpl;
const FutureResult = @import("../future_result.zig").FutureResult;
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");

const assert = std.debug.assert;

pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    thread_pool_task: xev.ThreadPool.Task,
    runtime: *Runtime,
    execute_fn: *const fn (*AnyBlockingTask) void,

    pub const wait_node_vtable = WaitNode.VTable{};

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }
};

// Thread pool callback for blocking tasks
fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
    const any_blocking_task: *AnyBlockingTask = @fieldParentPtr("thread_pool_task", task);

    // Check if the task was canceled before it started executing
    if (!any_blocking_task.awaitable.canceled.load(.acquire)) {
        // Execute the user's blocking function only if not canceled
        any_blocking_task.execute_fn(any_blocking_task);
    }

    // Mark awaitable as complete and wake all waiters (thread-safe)
    // Even if canceled, we still mark as complete so waiters wake up
    any_blocking_task.awaitable.markComplete();

    // Release the blocking task's reference and check for shutdown
    const runtime = any_blocking_task.runtime;
    runtime.releaseAwaitable(&any_blocking_task.awaitable, true);
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyBlockingTask, Self);

        impl: Impl,

        pub const Result = Impl.Result;
        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;
        pub const asyncWait = Impl.asyncWait;
        pub const asyncCancelWait = Impl.asyncCancelWait;
        pub const toAwaitable = Impl.toAwaitable;
        pub const getResult = Impl.getResult;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        pub fn create(
            runtime: *Runtime,
            func: anytype,
            args: meta.ArgsType(func),
        ) !*Self {
            const Args = @TypeOf(args);

            const TaskData = struct {
                blocking_task: Self,
                args: Args,

                fn execute(any_blocking_task: *AnyBlockingTask) void {
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    const res = @call(.always_inline, func, self.args);
                    _ = self.blocking_task.impl.future_result.set(res);
                }

                fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
                    const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);
                    rt.allocator.destroy(self);
                }
            };

            const task_data = try runtime.allocator.create(TaskData);
            errdefer runtime.allocator.destroy(task_data);

            task_data.* = .{
                .blocking_task = .{
                    .impl = .{
                        .base = .{
                            .awaitable = .{
                                .kind = .blocking_task,
                                .destroy_fn = &TaskData.destroyFn,
                                .wait_node = .{
                                    .vtable = &AnyBlockingTask.wait_node_vtable,
                                },
                            },
                            .thread_pool_task = .{ .callback = threadPoolCallback },
                            .runtime = runtime,
                            .execute_fn = &TaskData.execute,
                        },
                        .future_result = .{},
                    },
                },
                .args = args,
            };

            return &task_data.blocking_task;
        }

        pub fn destroy(self: *Self, runtime: *Runtime) void {
            self.impl.base.awaitable.destroy_fn(runtime, &self.impl.base.awaitable);
        }
    };
}
