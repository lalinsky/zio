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
const Timeout = @import("timeout.zig").Timeout;
const TimeoutHeap = @import("timeout.zig").TimeoutHeap;

/// Options for creating a task
pub const CreateOptions = struct {
    stack_size: ?usize = null,
    pinned: bool = false,
};

pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    state: std.atomic.Value(State),

    // Shared xev timer for timeout handling
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timeouts: TimeoutHeap = .{ .context = {} },

    // Number of active timeouts currently registered
    timeout_count: u8 = 0,

    // Number of active cancelation sheilds
    shield_count: u8 = 0,

    // Number of times this task was pinned to the current executor
    pin_count: u8 = 0,

    pub const State = enum(u8) {
        new,
        ready,
        preparing_to_wait,
        waiting,
    };

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

    pub inline fn getLoop(self: *AnyTask) *xev.Loop {
        return self.getExecutor().getLoop();
    }

    /// Check if this task can be migrated to a different executor.
    /// Returns false if the task is pinned or canceled, true otherwise.
    pub inline fn canMigrate(self: *const AnyTask) bool {
        if (self.pin_count > 0) return false;
        if (self.awaitable.canceled.load(.acquire)) return false;
        // TODO: Enable migration once we have work-stealing
        return false;
    }

    fn getNextTimeout(self: *AnyTask, now: i64) ?struct { timeout: *Timeout, delay_ms: u64 } {
        while (true) {
            var timeout = self.timeouts.peek() orelse return null;
            if (timeout.deadline_ms < now) {
                const removed = self.timeouts.deleteMin();
                std.debug.assert(timeout == removed);
                timeout.active = false;
            }
            return .{
                .timeout = timeout,
                .delay_ms = @intCast(timeout.deadline_ms - now),
            };
        }
        unreachable;
    }

    pub fn cancelTimer(self: *AnyTask, loop: *xev.Loop) void {
        if (self.timer_c.state() == .dead) {
            return;
        }

        if (self.timer_c.userdata == null) {
            return;
        }

        // Even if the cancel fails for some reason, and the callback will get triggered
        // it will see null and do nothing.
        self.timer_c.userdata = null;

        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        // Cancel the timer, but don't want for the cancelation to be finished.
        timer.cancel(
            loop,
            &self.timer_c,
            &self.timer_cancel_c,
            void,
            null,
            noopTimerCancelCallback,
        );
    }

    pub fn setTimer(self: *AnyTask, loop: *xev.Loop, timeout: *Timeout, delay_ms: u64) void {
        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        timer.reset(
            loop,
            &self.timer_c,
            &self.timer_cancel_c,
            delay_ms,
            Timeout,
            timeout,
            timeoutCallback,
        );
    }

    pub fn updateTimer(self: *AnyTask, loop: *xev.Loop) void {
        const next = self.getNextTimeout(loop.now()) orelse {
            self.cancelTimer(loop);
            return;
        };
        self.setTimer(loop, next.timeout, next.delay_ms);
    }

    pub fn maybeUpdateTimer(self: *AnyTask) void {
        const executor = self.getExecutor();
        const next = self.getNextTimeout(executor.loop.now()) orelse {
            self.cancelTimer(&executor.loop);
            return;
        };
        if (@as(?*anyopaque, @ptrCast(next.timeout)) != self.timer_c.userdata) {
            self.setTimer(&executor.loop, next.timeout, next.delay_ms);
            return;
        }
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
                        },
                        .state = .init(.new),
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

// Callback for timeout timer
fn timeoutCallback(
    userdata: ?*Timeout,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    result catch return .disarm;
    const timeout = userdata orelse return .disarm;

    const task: *AnyTask = @fieldParentPtr("timer_c", completion);
    std.debug.assert(task == timeout.task);

    // Mark this one as triggered, user can convert this to error.Timeout
    // TODO: Should we only mark triggered if we were the one who canceled the task?
    timeout.triggered = true;

    // Remove this timeout from the heap
    if (timeout.active) {
        task.timeouts.remove(timeout);
        timeout.active = false;
    }

    // Configure the next timer
    task.updateTimer(loop);

    // Cancel the task (sets canceled flag and resumes it)
    // TODO: Race condition in cancel between storing cancelled and wake?
    task.awaitable.cancel();

    return .disarm;
}

// Noop callback for timeout timer cancellation
fn noopTimerCancelCallback(
    ud: ?*void,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.CancelError!void,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = c;
    _ = r catch {};
    return .disarm;
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
