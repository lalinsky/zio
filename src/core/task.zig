// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const xev = @import("xev");
const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Awaitable = @import("awaitable.zig").Awaitable;
const CanceledStatus = @import("awaitable.zig").CanceledStatus;
const FutureImpl = @import("awaitable.zig").FutureImpl;
const Coroutine = @import("../coroutines.zig").Coroutine;
const coroutines = @import("../coroutines.zig");
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Timeout = @import("timeout.zig").Timeout;
const TimeoutHeap = @import("timeout.zig").TimeoutHeap;

/// Options for creating a task
pub const CreateOptions = struct {
    stack_size: ?usize = null,
    pinned: bool = false,
};

const max_result_len = 1 << 12;
const max_result_alignment = 1 << 4;
const max_context_len = 1 << 12;
const max_context_alignment = 1 << 4;

const Closure = struct {
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    result_len: u12,
    result_padding: u4,
    context_len: u12,
    context_padding: u4,

    fn getResultPtr(self: *const Closure, task: *AnyTask) *anyopaque {
        const result_ptr = @intFromPtr(task) + @sizeOf(AnyTask) + self.result_padding;
        return @ptrFromInt(result_ptr);
    }

    fn getResultSlice(self: *const Closure, task: *AnyTask) []u8 {
        const result_ptr = @intFromPtr(task) + @sizeOf(AnyTask) + self.result_padding;
        const result: [*]u8 = @ptrFromInt(result_ptr);
        return result[0..self.result_len];
    }

    fn getContextPtr(self: *const Closure, task: *AnyTask) *const anyopaque {
        const result_ptr = @intFromPtr(task) + @sizeOf(AnyTask) + self.result_padding;
        const context_ptr = result_ptr + self.result_len + self.context_padding;
        return @ptrFromInt(context_ptr);
    }

    fn getContextSlice(self: *const Closure, task: *AnyTask) []u8 {
        const result_ptr = @intFromPtr(task) + @sizeOf(AnyTask) + self.result_padding;
        const context_ptr = result_ptr + self.result_len + self.context_padding;
        const context: [*]u8 = @ptrFromInt(context_ptr);
        return context[0..self.context_len];
    }
};

pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    state: std.atomic.Value(State),

    // Shared xev timer for timeout handling
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timeouts: TimeoutHeap = .{ .context = {} },

    // Number of active cancelation sheilds
    shield_count: u8 = 0,

    // Number of times this task was pinned to the current executor
    pin_count: u8 = 0,

    // Closure for the task
    closure: Closure,

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

    /// Check if this task can be migrated to a different executor.
    /// Returns false if the task is pinned or canceled, true otherwise.
    pub inline fn canMigrate(self: *const AnyTask) bool {
        if (self.pin_count > 0) return false;
        if (self.awaitable.canceled_status.load(.acquire) != 0) return false;
        // TODO: Enable migration once we have work-stealing
        return false;
    }

    fn getNextTimeout(self: *AnyTask, now: i64) ?struct { timeout: *Timeout, delay_ms: u64 } {
        while (true) {
            var timeout = self.timeouts.peek() orelse return null;
            if (timeout.deadline_ms < now) {
                std.debug.assert(timeout.task != null);
                const removed = self.timeouts.deleteMin();
                std.debug.assert(timeout == removed);
                timeout.task = null;
                continue;
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

    /// Check if the given timeout triggered the cancellation.
    /// This should be called in a catch block after receiving an error.
    /// If the error is not error.Canceled, returns the original error unchanged.
    /// User cancellation has priority - if user_canceled is set, returns error.Canceled.
    /// Otherwise, if the timeout was triggered, decrements the timeout counter and returns error.Timeout.
    /// Otherwise, returns the original error.
    /// Note: user_canceled is NEVER cleared - once set, task is condemned.
    /// Note: Does NOT decrement pending_errors - that counter is only consumed by checkCanceled.
    pub fn checkTimeout(self: *AnyTask, _: *Runtime, timeout: *Timeout, err: anytype) !void {
        // If not error.Canceled, just return the original error
        if (err != error.Canceled) {
            return err;
        }

        var current = self.awaitable.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // User cancellation has priority - once condemned (user_canceled set), always return error.Canceled
            if (status.user_canceled) {
                return error.Canceled;
            }

            // No user cancellation - check if this timeout triggered
            if (timeout.triggered and status.timeout > 0) {
                // Decrement timeout counter
                status.timeout -= 1;
                const new: u32 = @bitCast(status);
                if (self.awaitable.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                    current = prev;
                    continue;
                }
                return error.Timeout;
            }

            // Timeout didn't trigger or already consumed
            return err;
        }
    }

    /// Check if there are pending cancellation errors to consume.
    /// If pending_errors > 0 and not shielded, decrements the count and returns error.Canceled.
    /// Otherwise returns void (no error).
    pub fn checkCanceled(self: *AnyTask, _: *Runtime) error{Canceled}!void {
        // If shielded, don't check cancellation
        if (self.shield_count > 0) return;

        // CAS loop to decrement pending_errors
        var current = self.awaitable.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // If no pending errors, nothing to consume
            if (status.pending_errors == 0) return;

            // Decrement pending_errors
            status.pending_errors -= 1;

            const new: u32 = @bitCast(status);
            if (self.awaitable.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                // CAS failed, use returned previous value and retry
                current = prev;
                continue;
            }
            // CAS succeeded - return error.Canceled
            return error.Canceled;
        }
    }

    pub fn destroyFn(rt: *Runtime, awaitable: *Awaitable) void {
        const self = fromAwaitable(awaitable);

        if (self.coro.stack) |stack| {
            const executor = Executor.fromCoroutine(&self.coro);
            executor.stack_pool.release(stack);
        }

        var allocation_size: usize = @sizeOf(AnyTask);
        allocation_size += self.closure.result_padding + self.closure.result_len;
        allocation_size += self.closure.context_padding + self.closure.context_len;

        const allocation = @as([*]align(@alignOf(AnyTask)) u8, @ptrCast(self))[0..allocation_size];
        rt.allocator.free(allocation);
    }

    pub fn startFn(coro: *Coroutine, _: ?*anyopaque) void {
        const self = fromCoroutine(coro);
        const c = &self.closure;

        const result = c.getResultPtr(self);
        const context = c.getContextPtr(self);

        c.start(context, result);
    }

    pub fn create(
        executor: *Executor,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
        options: CreateOptions,
    ) !*AnyTask {
        var allocation_size: usize = @sizeOf(AnyTask);

        // Reserve space for result
        if (result_len > max_result_len) return error.ResultTooLarge;
        if (result_alignment.toByteUnits() > max_result_alignment) return error.ResultTooLarge;
        const result_padding = result_alignment.forward(allocation_size) - allocation_size;
        allocation_size += result_padding + result_len;

        // Reserve space for context
        if (context.len > max_context_len) return error.ContextTooLarge;
        if (context_alignment.toByteUnits() > max_context_alignment) return error.ContextTooLarge;
        const context_padding = context_alignment.forward(allocation_size) - allocation_size;
        allocation_size += context_padding + context.len;

        // Allocate task context
        const allocation = try executor.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(AnyTask)), allocation_size);
        errdefer executor.allocator.free(allocation);

        // Acquire stack from pool
        const stack = try executor.stack_pool.acquire(options.stack_size orelse coroutines.DEFAULT_STACK_SIZE);
        errdefer executor.stack_pool.release(stack);

        const self: *AnyTask = @ptrCast(allocation.ptr);
        self.* = .{
            .state = .init(.new),
            .awaitable = .{
                .kind = .task,
                .destroy_fn = &AnyTask.destroyFn,
                .wait_node = .{
                    .vtable = &AnyTask.wait_node_vtable,
                },
            },
            .coro = .{
                .stack = stack,
                .parent_context_ptr = &executor.main_context,
            },
            .closure = .{
                .start = start,
                .result_padding = @intCast(result_padding),
                .result_len = @intCast(result_len),
                .context_padding = @intCast(context_padding),
                .context_len = @intCast(context.len),
            },
            .pin_count = if (options.pinned) 1 else 0,
        };

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(self);
        @memcpy(context_dest, context);

        self.coro.setup(&AnyTask.startFn, null);

        return self;
    }
};

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        base: AnyTask,

        pub fn fromAwaitable(awaitable: *Awaitable) *Self {
            return fromAny(.fromAwaitable(awaitable));
        }

        pub fn fromAny(task: *AnyTask) *Self {
            return @fieldParentPtr("base", task);
        }

        pub fn getRuntime(self: *Self) *Runtime {
            const executor = Executor.fromCoroutine(&self.base.coro);
            return executor.runtime;
        }

        fn allocationSize() usize {
            return comptime blk: {
                var s = @sizeOf(Self);
                s = std.mem.alignForward(usize, s, @alignOf(T)) + @sizeOf(T);
                break :blk s;
            };
        }

        fn getResultOffset() usize {
            return comptime blk: {
                var s = @sizeOf(Self);
                s = std.mem.alignForward(usize, s, @alignOf(T));
                break :blk s;
            };
        }

        fn getResultPtr(self: *Self) *T {
            return @ptrFromInt(@intFromPtr(self) + getResultOffset());
        }

        pub fn getResult(self: *Self) T {
            return self.getResultPtr().*;
        }

        pub fn create(
            executor: *Executor,
            func: anytype,
            args: meta.ArgsType(func),
            options: CreateOptions,
        ) !*Self {
            const Wrapper = struct {
                fn start(ctx: *const anyopaque, result: *anyopaque) void {
                    const a: *const @TypeOf(args) = @ptrCast(@alignCast(ctx));
                    const r: *T = @ptrCast(@alignCast(result));
                    r.* = @call(.auto, func, a.*);
                }
            };

            const task = try AnyTask.create(
                executor,
                @sizeOf(T),
                .fromByteUnits(@alignOf(T)),
                std.mem.asBytes(&args),
                .fromByteUnits(@alignOf(@TypeOf(args))),
                &Wrapper.start,
                options,
            );

            return Self.fromAny(task);
        }

        pub fn destroy(self: *Self, executor: *Executor) void {
            self.base.awaitable.destroy_fn(executor.runtime, &self.base.awaitable);
        }

        pub fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self = fromAny(any_task);

            // Release stack if it's still allocated
            if (any_task.coro.stack) |stack| {
                const executor = Executor.fromCoroutine(&any_task.coro);
                executor.stack_pool.release(stack);
            }

            const allocation = @as([*]align(@alignOf(Self)) u8, @ptrCast(self))[0..allocationSize()];
            runtime.allocator.free(allocation);
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

    const task = timeout.task orelse return .disarm;
    std.debug.assert(task == @as(*AnyTask, @fieldParentPtr("timer_c", completion)));

    // Remove this timeout from the heap
    task.timeouts.remove(timeout);
    timeout.task = null;

    // Clear the timer's userdata so maybeUpdateTimer knows the timer is not set
    completion.userdata = null;

    // Configure the next timer
    task.updateTimer(loop);

    // Cancel the task - behavior depends on whether already user-canceled
    var mark_as_triggered = false;
    var current = task.awaitable.canceled_status.load(.acquire);
    while (true) {
        var status: CanceledStatus = @bitCast(current);

        if (status.user_canceled) {
            // Task is already condemned by user cancellation
            // Just increment pending_errors to add another error
            // Don't increment timeout counter or set triggered flag
            mark_as_triggered = false;
            status.pending_errors += 1;
        } else {
            // This timeout is causing the cancellation
            // Increment timeout counter and pending_errors, will set triggered flag
            mark_as_triggered = true;
            status.timeout += 1;
            status.pending_errors += 1;
        }

        const new: u32 = @bitCast(status);
        if (task.awaitable.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
            // CAS failed, use returned previous value and retry
            current = prev;
            continue;
        }
        // CAS succeeded
        break;
    }

    // Only mark as triggered if this timeout caused the cancellation
    if (mark_as_triggered) {
        timeout.triggered = true;
    }

    // Always wake the task
    resumeTask(task, .local);

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
