// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Awaitable = @import("awaitable.zig").Awaitable;
const CanceledStatus = @import("awaitable.zig").CanceledStatus;
const Coroutine = @import("coro").Coroutine;
const StackInfo = @import("coro").StackInfo;
const WaitNode = @import("WaitNode.zig");
const meta = @import("../meta.zig");
const Cancelable = @import("../common.zig").Cancelable;
const Timeoutable = @import("../common.zig").Timeoutable;
const Timeout = @import("timeout.zig").Timeout;
const Group = @import("group.zig").Group;

/// Options for creating a task
pub const CreateOptions = struct {
    pinned: bool = false,
};

pub const Closure = struct {
    start: Start,
    result_len: u12,
    result_padding: u4,
    context_len: u12,
    context_padding: u4,

    pub const Start = union(enum) {
        /// Regular task: fn(context, result) -> void
        regular: *const fn (context: *const anyopaque, result: *anyopaque) void,
        /// Group task: fn(group, context) -> void, group comes from awaitable.group_node.group
        group: *const fn (group: *anyopaque, context: *const anyopaque) void,
    };

    pub const max_result_len = 1 << 12;
    pub const max_result_alignment = 1 << 4;
    pub const max_context_len = 1 << 12;
    pub const max_context_alignment = 1 << 4;
    pub const task_alignment = 1 << 4;

    pub fn getResultPtr(self: *const Closure, comptime TaskType: type, task: *TaskType) *anyopaque {
        const result_ptr = @intFromPtr(task) + @sizeOf(TaskType) + self.result_padding;
        return @ptrFromInt(result_ptr);
    }

    pub fn getResultSlice(self: *const Closure, comptime TaskType: type, task: *TaskType) []u8 {
        const result_ptr = @intFromPtr(task) + @sizeOf(TaskType) + self.result_padding;
        const result: [*]u8 = @ptrFromInt(result_ptr);
        return result[0..self.result_len];
    }

    pub fn getContextPtr(self: *const Closure, comptime TaskType: type, task: *TaskType) *const anyopaque {
        const result_ptr = @intFromPtr(task) + @sizeOf(TaskType) + self.result_padding;
        const context_ptr = result_ptr + self.result_len + self.context_padding;
        return @ptrFromInt(context_ptr);
    }

    pub fn getContextSlice(self: *const Closure, comptime TaskType: type, task: *TaskType) []u8 {
        const result_ptr = @intFromPtr(task) + @sizeOf(TaskType) + self.result_padding;
        const context_ptr = result_ptr + self.result_len + self.context_padding;
        const context: [*]u8 = @ptrFromInt(context_ptr);
        return context[0..self.context_len];
    }

    /// Call the start function with the appropriate arguments.
    /// For group tasks, handles counter decrement and event signaling.
    pub fn call(self: *const Closure, comptime TaskType: type, task: *TaskType, group_ptr: ?*Group) void {
        const context = self.getContextPtr(TaskType, task);

        switch (self.start) {
            .regular => |start| {
                const result = self.getResultPtr(TaskType, task);
                start(context, result);
            },
            .group => |start| {
                const group = group_ptr.?;
                start(group, context);

                // Decrement counter and signal event if this was the last task
                if (group.decrCounter()) {
                    group.getEvent().set();
                }
            },
        }
    }

    pub fn getAllocationSlice(self: *const Closure, comptime TaskType: type, task: *TaskType) []align(task_alignment) u8 {
        var allocation_size: usize = @sizeOf(TaskType);
        allocation_size += self.result_padding;
        allocation_size += self.result_len;
        allocation_size += self.context_padding;
        allocation_size += self.context_len;
        return @as([*]align(task_alignment) u8, @ptrCast(@alignCast(task)))[0..allocation_size];
    }

    pub fn AllocResult(comptime TaskType: type) type {
        return struct {
            closure: Closure,
            task: *TaskType,
        };
    }

    pub fn alloc(
        comptime TaskType: type,
        rt: *Runtime,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context_len: usize,
        context_alignment: std.mem.Alignment,
        start: Start,
    ) !AllocResult(TaskType) {
        var allocation_size: usize = @sizeOf(TaskType);

        // Reserve space for result
        if (result_len > max_result_len) return error.ResultTooLarge;
        if (result_alignment.toByteUnits() > max_result_alignment) return error.ResultTooLarge;
        const result_padding = result_alignment.forward(allocation_size) - allocation_size;
        allocation_size += result_padding + result_len;

        // Reserve space for context
        if (context_len > max_context_len) return error.ContextTooLarge;
        if (context_alignment.toByteUnits() > max_context_alignment) return error.ContextTooLarge;
        const context_padding = context_alignment.forward(allocation_size) - allocation_size;
        allocation_size += context_padding + context_len;

        // Allocate task from pool or fallback allocator
        const allocation = try rt.task_pool.alloc(rt, allocation_size);

        return .{
            .closure = .{
                .start = start,
                .result_len = @intCast(result_len),
                .result_padding = @intCast(result_padding),
                .context_len = @intCast(context_len),
                .context_padding = @intCast(context_padding),
            },
            .task = @ptrCast(allocation.ptr),
        };
    }

    pub fn free(self: *const Closure, comptime TaskType: type, rt: *Runtime, task: *TaskType) void {
        const allocation = self.getAllocationSlice(TaskType, task);
        rt.task_pool.free(rt, allocation);
    }
};

pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    state: std.atomic.Value(State),

    // Number of active cancellation shields
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

    /// Check if the given timeout triggered the cancellation.
    /// This should be called in a catch block after receiving an error.
    /// If the error is not error.Canceled, returns the original error unchanged.
    /// Marks a timeout as triggered and updates the task's cancellation status.
    /// If the task is already user-canceled, only increments pending_errors.
    /// Otherwise, increments both timeout counter and pending_errors, and sets timeout.triggered.
    pub fn setTimeout(self: *AnyTask) bool {
        var triggered = false;
        var current = self.awaitable.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            if (status.user_canceled) {
                // Task is already condemned by user cancellation
                // Just increment pending_errors to add another error
                triggered = false;
                status.pending_errors += 1;
            } else {
                // This timeout is causing the cancellation
                // Increment timeout counter and pending_errors
                triggered = true;
                status.timeout += 1;
                status.pending_errors += 1;
            }

            const new: u32 = @bitCast(status);
            if (self.awaitable.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            // CAS succeeded
            break;
        }

        return triggered;
    }

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

        if (self.coro.context.stack_info.allocation_len > 0) {
            rt.stack_pool.release(self.coro.context.stack_info);
        }

        self.closure.free(AnyTask, rt, self);
    }

    pub fn startFn(coro: *Coroutine, _: ?*anyopaque) void {
        const self = fromCoroutine(coro);
        self.closure.call(AnyTask, self, self.awaitable.group_node.group);
    }

    pub fn create(
        executor: *Executor,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: Closure.Start,
        options: CreateOptions,
    ) !*AnyTask {
        // Allocate task with closure
        const alloc_result = try Closure.alloc(
            AnyTask,
            executor.runtime,
            result_len,
            result_alignment,
            context.len,
            context_alignment,
            start,
        );
        errdefer alloc_result.closure.free(AnyTask, executor.runtime, alloc_result.task);

        const self = alloc_result.task;
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
                .parent_context_ptr = &executor.main_task.coro.context,
            },
            .closure = alloc_result.closure,
            .pin_count = if (options.pinned) 1 else 0,
        };

        // Acquire stack from pool and initialize context
        self.coro.context.stack_info = try executor.runtime.stack_pool.acquire();
        errdefer executor.runtime.stack_pool.release(self.coro.context.stack_info);

        // Copy context data into the allocation
        const context_dest = self.closure.getContextSlice(AnyTask, self);
        @memcpy(context_dest, context);

        self.coro.setup(&AnyTask.startFn, null);

        return self;
    }
};

// Typed task that wraps a pointer to AnyTask
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();

        task: *AnyTask,

        pub fn fromAwaitable(awaitable: *Awaitable) Self {
            return Self{ .task = AnyTask.fromAwaitable(awaitable) };
        }

        pub fn fromAny(task: *AnyTask) Self {
            return Self{ .task = task };
        }

        pub fn toAwaitable(self: Self) *Awaitable {
            return &self.task.awaitable;
        }

        pub fn getRuntime(self: Self) *Runtime {
            const executor = Executor.fromCoroutine(&self.task.coro);
            return executor.runtime;
        }

        fn getResultPtr(self: Self) *T {
            const c = &self.task.closure;
            const result_ptr = c.getResultPtr(AnyTask, self.task);
            return @ptrCast(@alignCast(result_ptr));
        }

        pub fn getResult(self: Self) T {
            return self.getResultPtr().*;
        }

        pub fn create(
            executor: *Executor,
            func: anytype,
            args: meta.ArgsType(func),
            options: CreateOptions,
        ) !Self {
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
                .{ .regular = &Wrapper.start },
                options,
            );

            return Self.fromAny(task);
        }

        pub fn destroy(self: Self, executor: *Executor) void {
            self.task.awaitable.destroy_fn(executor.runtime, &self.task.awaitable);
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

pub const TaskPool = struct {
    pub const pool_item_size = std.mem.alignForward(usize, @sizeOf(AnyTask) + 128, 128);

    pool: std.heap.MemoryPoolAligned([pool_item_size]u8, .fromByteUnits(Closure.task_alignment)),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) TaskPool {
        return .{
            .pool = .init(allocator),
        };
    }

    pub fn deinit(self: *TaskPool) void {
        self.pool.deinit();
    }

    pub fn alloc(self: *TaskPool, rt: *Runtime, size: usize) ![]align(Closure.task_alignment) u8 {
        if (size <= pool_item_size) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const ptr = try self.pool.create();
            return ptr;
        } else {
            return try rt.allocator.alignedAlloc(u8, .fromByteUnits(Closure.task_alignment), size);
        }
    }

    pub fn free(self: *TaskPool, rt: *Runtime, slice: []align(Closure.task_alignment) u8) void {
        if (slice.len <= pool_item_size) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pool.destroy(@ptrCast(slice.ptr));
        } else {
            rt.allocator.free(slice);
        }
    }
};

test "AnyTask size" {
    try std.testing.expectEqual(248, @sizeOf(AnyTask));
    try std.testing.expectEqual(384, TaskPool.pool_item_size);
}
