// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const MemoryPoolAligned = @import("../utils/memory_pool.zig").MemoryPoolAligned;

const Runtime = @import("../runtime.zig").Runtime;
const Executor = @import("../runtime.zig").Executor;
const Awaitable = @import("awaitable.zig").Awaitable;
const Coroutine = @import("../coro/coroutines.zig").Coroutine;
const WaitNode = @import("WaitNode.zig");
const Cancelable = @import("../common.zig").Cancelable;
const Group = @import("group.zig").Group;
const registerGroupTask = @import("group.zig").registerGroupTask;
const unregisterGroupTask = @import("group.zig").unregisterGroupTask;
const os = @import("../os/root.zig");

pub const Closure = struct {
    start: Start,
    result_len: u12,
    result_padding: u4,
    context_len: u12,
    context_padding: u4,

    pub const Start = union(enum) {
        /// Regular task: fn(context, result) -> void
        regular: *const fn (context: *const anyopaque, result: *anyopaque) void,
        /// Group task: fn(context) -> Cancelable!void
        group: *const fn (context: *const anyopaque) Cancelable!void,
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
    pub fn call(self: *const Closure, comptime TaskType: type, task: *TaskType) void {
        const context = self.getContextPtr(TaskType, task);

        switch (self.start) {
            .regular => |start| {
                const result = self.getResultPtr(TaskType, task);
                start(context, result);
            },
            .group => |start| {
                // The start signature returns Cancelable!void for std.Io compatibility
                start(context) catch {};
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

// Cancellation status - tracks both user and auto-cancellation
// Organized as 4 bytes for easier alignment:
// Byte 0: flags (user_canceled + padding)
// Byte 1: auto_canceled counter
// Byte 2: pending_errors counter
// Byte 3: shield_count counter
pub const CanceledStatus = packed struct(u32) {
    user_canceled: bool = false,
    _padding: u7 = 0,
    auto_canceled: u8 = 0,
    pending_errors: u8 = 0,
    shield_count: u8 = 0,
};

// Kind of cancellation
pub const CancelKind = enum { user, auto };

pub const AnyTask = struct {
    awaitable: Awaitable,
    coro: Coroutine,
    state: std.atomic.Value(State),

    // Cancellation status - tracks user cancel, timeout, pending errors, and shield count
    canceled_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Closure for the task
    closure: Closure,

    pub const State = enum(u8) {
        new,
        ready,
        preparing_to_wait,
        waiting,
        finished,
    };

    pub const wait_node_vtable = WaitNode.VTable{
        .wake = waitNodeWake,
    };

    fn waitNodeWake(wait_node: *WaitNode) void {
        const awaitable: *Awaitable = @fieldParentPtr("wait_node", wait_node);
        AnyTask.fromAwaitable(awaitable).wake();
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

    /// Get the typed result from this task's closure.
    pub fn getResult(self: *AnyTask, comptime T: type) T {
        // Sanity checks before unsafe casting
        if (std.debug.runtime_safety) {
            std.debug.assert(self.awaitable.hasResult()); // Task must be completed
            std.debug.assert(@sizeOf(T) == self.closure.result_len); // Size must match
            std.debug.assert(@alignOf(T) <= Closure.max_result_alignment); // Alignment must fit
        }

        const result_ptr: *T = @ptrCast(@alignCast(self.closure.getResultPtr(AnyTask, self)));
        return result_ptr.*;
    }

    /// Get the executor that owns this task.
    pub inline fn getExecutor(self: *AnyTask) *Executor {
        return Executor.fromCoroutine(&self.coro);
    }

    pub inline fn getRuntime(self: *AnyTask) *Runtime {
        return self.getExecutor().runtime;
    }

    pub const YieldMode = enum { park, reschedule };

    /// Cooperatively yield control to other tasks.
    ///
    /// - `.park`: Suspend until resumed (I/O, sync primitives, timeout, cancellation).
    ///   The task state must be `.preparing_to_wait` before calling.
    ///   The actual transition to `.waiting` is deferred until after the context is saved.
    ///
    /// - `.reschedule`: Reschedule immediately (cooperative yielding).
    ///   The task state remains `.ready`.
    pub fn yield(self: *AnyTask, comptime mode: YieldMode, comptime cancel_mode: Executor.YieldCancelMode) if (cancel_mode == .allow_cancel) Cancelable!void else void {
        var executor = self.getExecutor();
        executor.current_task = null;

        // Check and consume cancellation flag before yielding (unless no_cancel)
        if (cancel_mode == .allow_cancel) {
            self.checkCancel() catch |err| {
                self.state.store(.ready, .release);
                executor.current_task = self;
                return err;
            };
        }

        // Set up deferred cleanup — state transition happens after context is saved
        executor.pending_cleanup = switch (mode) {
            .park => .{ .park = self },
            .reschedule => .{ .reschedule = self },
        };

        if (self == &executor.main_task) {
            // Main task enters the run loop instead of context switching
            executor.run(.until_ready) catch |err| {
                std.log.err("Event loop error during yield: {}", .{err});
            };
        } else {
            executor.switchOut(&self.coro);

            // --- Resumed: landing site (b) ---
            // We could be on a different executor now due to task migration
            executor = self.getExecutor();
            executor.processCleanup();
        }

        std.debug.assert(self.state.load(.acquire) == .ready);
        defer executor.current_task = self;

        // Check after resuming in case we were canceled while suspended
        if (cancel_mode == .allow_cancel) {
            try self.checkCancel();
        }
    }

    /// Begin a cancellation shield to prevent being canceled during critical sections.
    pub fn beginShield(self: *AnyTask) void {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);
            status.shield_count += 1;
            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            break;
        }
    }

    /// End a cancellation shield.
    pub fn endShield(self: *AnyTask) void {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);
            std.debug.assert(status.shield_count > 0);
            status.shield_count -= 1;
            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            break;
        }
    }

    /// Set the canceled status on this task.
    /// Returns true if this cancellation triggered, false if shadowed by prior user cancellation.
    pub fn setCanceled(self: *AnyTask, kind: CancelKind) bool {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);
            var triggered: bool = undefined;

            switch (kind) {
                .user => {
                    status.user_canceled = true;
                    status.pending_errors += 1;
                    triggered = true;
                },
                .auto => {
                    if (status.user_canceled) {
                        // Shadowed by user cancellation
                        status.pending_errors += 1;
                        triggered = false;
                    } else {
                        status.auto_canceled += 1;
                        status.pending_errors += 1;
                        triggered = true;
                    }
                },
            }

            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            return triggered;
        }
    }

    /// Re-arm cancellation after it was acknowledged.
    /// This increments pending_errors so the next cancellation point returns error.Canceled.
    /// Asserts that user_canceled is already set.
    pub fn recancel(self: *AnyTask) void {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // Must have been canceled already
            std.debug.assert(status.user_canceled);

            // Increment pending_errors
            status.pending_errors += 1;

            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            break;
        }
    }

    /// Try to consume an auto-cancel. Returns true if an auto-cancel was consumed,
    /// false if user-canceled or no auto-cancel pending.
    pub fn checkAutoCancel(self: *AnyTask) bool {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // User cancellation has priority
            if (status.user_canceled) return false;

            // Check if there's an auto-cancel to consume
            if (status.auto_canceled > 0) {
                status.auto_canceled -= 1;
                const new: u32 = @bitCast(status);
                if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                    current = prev;
                    continue;
                }
                return true;
            }

            return false;
        }
    }

    /// Check if there are pending cancellation errors to consume.
    /// If pending_errors > 0 and not shielded, decrements the count and returns error.Canceled.
    /// Otherwise returns void (no error).
    pub fn checkCancel(self: *AnyTask) Cancelable!void {
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // If shielded, nothing to consume
            if (status.shield_count > 0) return;

            // If no pending errors, nothing to consume
            if (status.pending_errors == 0) return;

            // Decrement pending_errors
            status.pending_errors -= 1;

            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                current = prev;
                continue;
            }
            return error.Canceled;
        }
    }

    /// Cancel this task by setting canceled status and waking it if suspended.
    pub fn cancel(self: *AnyTask) void {
        if (self.setCanceled(.user)) {
            self.wake();
        }
    }

    /// Wake this task (mark it as ready and schedule for execution).
    pub fn wake(self: *AnyTask) void {
        const executor = Executor.fromCoroutine(&self.coro);
        executor.scheduleTask(self);
    }

    pub fn destroy(self: *AnyTask) void {
        const rt = self.getRuntime();
        if (self.coro.context.stack_info.allocation_len > 0) {
            rt.stack_pool.release(self.coro.context.stack_info, rt.now());
        }

        self.closure.free(AnyTask, rt, self);
    }

    pub fn startFn(coro: *Coroutine, _: ?*anyopaque) void {
        const self = fromCoroutine(coro);

        // Landing site (a): handle cleanup for the task that yielded to us
        var executor = self.getExecutor();
        executor.processCleanup();

        // Run the task's function
        self.closure.call(AnyTask, self);

        // Re-fetch executor — task may have migrated during execution
        executor = self.getExecutor();
        executor.pending_cleanup = .{ .finish = self };
        executor.current_task = null;
        executor.switchOut(&self.coro);
        unreachable;
    }

    pub fn create(
        executor: *Executor,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: Closure.Start,
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
                .wait_node = .{
                    .vtable = &AnyTask.wait_node_vtable,
                },
            },
            .coro = .{
                .parent_context_ptr = .init(&executor.main_task.coro.context),
            },
            .closure = alloc_result.closure,
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

const getNextExecutor = @import("../runtime.zig").getNextExecutor;

/// Register a task with the runtime and schedule it for execution.
/// Increments its reference count, adds the task to the runtime's task list,
/// and schedules it on its executor.
/// Returns error.RuntimeShutdown if the runtime is shutting down.
pub fn registerTask(rt: *Runtime, task: *AnyTask) error{RuntimeShutdown}!void {
    // Check if runtime is shutting down before incrementing counter
    if (rt.shutting_down.load(.acquire)) {
        return error.RuntimeShutdown;
    }

    _ = rt.task_count.fetchAdd(1, .acq_rel);

    const executor = Executor.fromCoroutine(&task.coro);
    executor.scheduleTask(task);

    if (Executor.current) |current_executor| {
        if (current_executor == executor) {
            current_executor.maybeYield(.reschedule, .no_cancel);
        }
    }
}

pub fn finishTask(rt: *Runtime, awaitable: *Awaitable) void {
    // Decrement task count BEFORE marking complete to prevent race where
    // waiting thread wakes up and sees non-zero task_count in deinit()
    _ = rt.task_count.fetchSub(1, .acq_rel);

    // Mark awaitable as complete and wake all waiters
    awaitable.markComplete();

    // For group tasks, decrement counter and release group's reference
    if (awaitable.group_node.group) |group| {
        unregisterGroupTask(group, awaitable);
    }

    // Decref for task completion
    awaitable.release();
}

/// Spawn a task with raw context bytes and start function.
/// Used by Runtime.spawn, Group.spawn, and std.Io vtable implementations.
pub fn spawnTask(
    rt: *Runtime,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: Closure.Start,
    group: ?*Group,
) !*AnyTask {
    const executor = try getNextExecutor(rt);

    const task = try AnyTask.create(
        executor,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
    );
    errdefer task.destroy();

    if (group) |g| try registerGroupTask(g, &task.awaitable);
    errdefer if (group) |g| unregisterGroupTask(g, &task.awaitable);

    // +1 ref for the caller (JoinHandle) before scheduling, to prevent
    // race where task completes before caller can take ownership
    task.awaitable.ref_count.incr();
    errdefer _ = task.awaitable.ref_count.decr();

    try registerTask(rt, task);

    return task;
}

pub const TaskPool = struct {
    pub const pool_item_size = std.mem.alignForward(usize, @sizeOf(AnyTask) + 128, 128);

    pool: MemoryPoolAligned([pool_item_size]u8, .fromByteUnits(Closure.task_alignment)),
    mutex: os.Mutex = .init(),

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
