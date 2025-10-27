const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Awaitable = @import("awaitable.zig").Awaitable;
const FutureImpl = @import("awaitable.zig").FutureImpl;
const Coroutine = @import("../coroutines.zig").Coroutine;
const coroutines = @import("../coroutines.zig");
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const TimeoutHeap = @import("timeout.zig").TimeoutHeap;

/// Options for creating a task
pub const CreateOptions = struct {
    stack_size: ?usize = null,
    pinned: bool = false,
};

pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,

    // Shared xev timer for timeout handling
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,

    // Shared xev timer for timeout handling
    timeouts: TimeoutHeap = .{ .context = {} },

    // Number of active timeouts currently registered
    timeout_count: u8 = 0,

    // Number of active cancelation sheilds
    shield_count: u8 = 0,

    // Number of times this task was pinned to the current executor
    pin_count: u8 = 0,

    pub const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    fn waitNodeWake(wait_node: *WaitNode) void {
        const awaitable: *Awaitable = @fieldParentPtr("wait_node", wait_node);
        resumeTask(awaitable, .maybe_remote);
    }

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        std.debug.assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromWaitNode(wait_node: *WaitNode) *AnyTask {
        const awaitable: *Awaitable = @fieldParentPtr("wait_node", wait_node);
        std.debug.assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromCoroutine(coro: *Coroutine) *AnyTask {
        return @fieldParentPtr("coro", coro);
    }

    /// Get the executor that owns this task.
    pub inline fn getExecutor(self: *AnyTask) *Executor {
        return Executor.fromCoroutine(&self.coro);
    }
};

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyTask, Self);

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
            const executor = Executor.fromCoroutine(&self.impl.base.coro);
            return executor.runtime;
        }

        pub fn create(
            executor: *Executor,
            func: anytype,
            args: meta.ArgsType(func),
            options: CreateOptions,
        ) !*Self {
            // Allocate task struct
            const task = try executor.allocator.create(Self);
            errdefer executor.allocator.destroy(executor.runtime);

            // Acquire stack from pool
            const stack = try executor.stack_pool.acquire(options.stack_size orelse coroutines.DEFAULT_STACK_SIZE);
            errdefer executor.stack_pool.release(stack);

            task.* = .{
                .impl = .{
                    .base = .{
                        .awaitable = .{
                            .kind = .task,
                            .destroy_fn = &Self.destroyFn,
                            .wait_node = .{
                                .vtable = &AnyTask.wait_node_vtable,
                            },
                        },
                        .coro = .{
                            .stack = stack,
                            .parent_context_ptr = &executor.main_context,
                            .state = .init(.waiting_sync),
                        },
                    },
                    .future_result = .{},
                },
            };

            task.impl.base.coro.setup(func, args, &task.impl.future_result);

            // Set pin count if task is pinned
            if (options.pinned) {
                task.impl.base.pin_count = 1;
            }

            return task;
        }

        pub fn destroy(self: *Self, executor: *Executor) void {
            self.impl.base.awaitable.destroy_fn(executor.runtime, &self.impl.base.awaitable);
        }

        pub fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self = fromAny(any_task);

            // Release stack if it's still allocated
            if (any_task.coro.stack) |stack| {
                const executor = Executor.fromCoroutine(&any_task.coro);
                executor.stack_pool.release(stack);
            }

            runtime.allocator.destroy(self);
        }
    };
}

/// Resume mode - controls cross-thread checking
pub const ResumeMode = enum {
    /// May resume on a different executor - checks thread-local executor
    maybe_remote,
    /// Always resumes on the current executor - skips check (use for IO callbacks)
    local,
};

/// Resume a task (mark it as ready).
/// Accepts *Awaitable, *AnyTask, or *Coroutine.
/// The coroutine must currently be in waiting state.
///
/// The `mode` parameter controls cross-thread checking:
/// - `.maybe_remote`: Checks if we're on the same executor (use for wait lists, futures)
/// - `.local`: Assumes we're on the same executor (use for IO callbacks)
pub fn resumeTask(obj: anytype, comptime mode: ResumeMode) void {
    const T = @TypeOf(obj);
    const task: *AnyTask = switch (T) {
        *AnyTask => obj,
        *Awaitable => AnyTask.fromAwaitable(obj),
        *Coroutine => AnyTask.fromCoroutine(obj),
        else => @compileError("resumeTask() requires, *AnyTask, *Awaitable or *Coroutine, got " ++ @typeName(T)),
    };

    const executor = Executor.fromCoroutine(&task.coro);
    executor.scheduleTask(task, mode);
}
