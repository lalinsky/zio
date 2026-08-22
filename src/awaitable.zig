// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("utils/ref_counter.zig").RefCounter;
const WaitNode = @import("utils/wait_queue.zig").WaitNode;
const Waiter = @import("common.zig").Waiter;
const Prepare = @import("select.zig").Prepare;
const CommitResult = @import("select.zig").CommitResult;
const Rollback = @import("select.zig").Rollback;
const GroupNode = @import("group.zig").GroupNode;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;

// Forward declaration - Runtime is defined in runtime.zig
const Runtime = @import("runtime.zig").Runtime;
const AnyTask = @import("task.zig").AnyTask;
const AnyBlockingTask = @import("blocking_task.zig").AnyBlockingTask;

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    task,
    blocking_task,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    ref_count: RefCounter(u8) = RefCounter(u8).init(),

    wait_node: WaitNode,

    // WaitNodes waiting for the completion of this awaitable
    // Uses WaitQueue flag to track completion:
    // - flag clear = not complete
    // - flag set = complete
    waiting_list: WaitQueue(WaitNode) = .empty,

    // Group membership - group_node.group is null if standalone
    group_node: GroupNode = .{},

    /// Request cancellation of this awaitable.
    /// Dispatches to the sub-type's cancel method.
    pub fn cancel(self: *Awaitable) void {
        switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).cancel(),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).cancel(),
        }
    }

    // AsyncWait protocol (see select.zig). Completion is the sticky queue
    // flag; markComplete() dequeues and notifies every registration while
    // setting it.
    pub const AsyncWait = struct {
        pub const Result = void;
        pub const Context = struct {};

        pub fn prepare(self: *Awaitable, waiter: *Waiter, ctx: *Context) Prepare {
            _ = ctx;
            if (!self.waiting_list.pushUnlessFlag(&waiter.node)) return .ready;
            return .pending;
        }

        pub fn commit(self: *Awaitable, waiter: *Waiter, ctx: *Context) CommitResult(void) {
            _ = waiter;
            _ = ctx;
            std.debug.assert(self.waiting_list.isFlagSet());
            return .{ .done = {} };
        }

        pub fn rollback(self: *Awaitable, waiter: *Waiter, ctx: *Context) Rollback {
            _ = ctx;
            return if (self.waiting_list.remove(&waiter.node)) .removed else .signal_in_flight;
        }
    };

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    /// Waiting tasks may belong to different executors, so always uses `.maybe_remote` mode.
    /// Can be called from any context.
    pub fn markComplete(self: *Awaitable) void {
        // Pop and wake all waiters while setting the flag.
        // Break as soon as we pop the last waiter - signaling it can free `self`
        // if the awaitable is destroyed after being observed as complete.
        while (self.waiting_list.popAndSetFlag()) |result| {
            Waiter.fromNode(result.node).signal();
            if (result.is_last) break;
        }
    }

    /// Check if the awaitable has completed and a result is available.
    pub fn hasResult(self: *const Awaitable) bool {
        return self.waiting_list.isFlagSet();
    }

    /// Get the typed result from this awaitable.
    /// Dispatches to the appropriate task type based on kind.
    pub fn getTypedResult(self: *Awaitable, comptime T: type) T {
        return switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).getResult(T),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).getResult(T),
        };
    }

    /// Get the raw result bytes from this awaitable.
    pub fn getResultSlice(self: *Awaitable) []u8 {
        return switch (self.kind) {
            .task => {
                const task = AnyTask.fromAwaitable(self);
                return task.closure.getResultSlice(AnyTask, task);
            },
            .blocking_task => {
                const task = AnyBlockingTask.fromAwaitable(self);
                return task.closure.getResultSlice(AnyBlockingTask, task);
            },
        };
    }

    /// Release the awaitable, decrementing the reference count and destroying it if necessary.
    pub fn release(self: *Awaitable) void {
        if (self.ref_count.decr()) self.destroy();
    }

    /// Destroy the awaitable, freeing any associated resources.
    pub fn destroy(self: *Awaitable) void {
        switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).destroy(),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).destroy(),
        }
    }
};
