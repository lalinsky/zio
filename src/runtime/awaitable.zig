// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../utils/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const GroupNode = @import("group.zig").GroupNode;
const CompactWaitQueue = @import("../utils/wait_queue.zig").CompactWaitQueue;
const SimpleQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
const WaitResult = @import("../select.zig").WaitResult;
const Cancelable = @import("../common.zig").Cancelable;
const select = @import("../select.zig");

// Forward declaration - Runtime is defined in runtime.zig
const Runtime = @import("../runtime.zig").Runtime;
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
    ref_count: RefCounter(u32) = RefCounter(u32).init(),

    wait_node: WaitNode,

    // WaitNodes waiting for the completion of this awaitable
    // Use CompactWaitQueue sentinel states to track completion:
    // - sentinel0 = not complete (no waiters, task not complete)
    // - sentinel1 = complete (no waiters, task is complete)
    // - pointer = waiting (has waiters, task not complete)
    waiting_list: CompactWaitQueue(WaitNode) = .empty,

    // Group membership - group_node.group is null if standalone
    group_node: GroupNode = .{},

    // Future protocol - type-erased result type
    pub const Result = void;

    pub const State = CompactWaitQueue(WaitNode).State;
    pub const not_complete = State.sentinel0;
    pub const complete = State.sentinel1;

    /// Request cancellation of this awaitable.
    /// Dispatches to the sub-type's cancel method.
    pub fn cancel(self: *Awaitable) void {
        switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).cancel(),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).cancel(),
        }
    }

    /// Registers a wait node to be notified when the awaitable completes.
    /// This is part of the Future protocol for select().
    /// Returns false if the awaitable is already complete (no wait needed), true if added to queue.
    pub fn asyncWait(self: *Awaitable, _: *Runtime, wait_node: *WaitNode) bool {
        // Fast path: check if already complete
        if (self.waiting_list.getState() == complete) {
            return false;
        }
        // Try to push to queue - only succeeds if awaitable is not complete
        // Returns false if awaitable is complete, preventing invalid transition: complete -> has_waiters
        return self.waiting_list.pushUnless(complete, wait_node);
    }

    /// Cancels a pending wait operation by removing the wait node.
    /// This is part of the Future protocol for select().
    /// Returns true if removed, false if already removed by completion (wake in-flight).
    pub fn asyncCancelWait(self: *Awaitable, _: *Runtime, wait_node: *WaitNode) bool {
        return self.waiting_list.remove(wait_node);
    }

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    /// Waiting tasks may belong to different executors, so always uses `.maybe_remote` mode.
    /// Can be called from any context.
    pub fn markComplete(self: *Awaitable) void {
        // First, pop ALL waiters into a temporary list and transition to complete state.
        // This ensures waiting_list.getState() == complete BEFORE we wake any waiters,
        // preventing a race where woken tasks check hasResult() before the transition completes.
        var waiters: SimpleQueue(WaitNode) = .empty;

        while (self.waiting_list.popOrTransition(not_complete, complete)) |wait_node| {
            waiters.push(wait_node);
        }

        // Now wake all waiters - at this point waiting_list is in complete state
        while (waiters.pop()) |wait_node| {
            wait_node.wake();
        }
    }

    /// Get the result (void for type-erased awaitable)
    /// Part of the Future protocol for use with select()
    pub fn getResult(self: *Awaitable) void {
        _ = self;
    }

    /// Check if the awaitable has completed and a result is available.
    pub fn hasResult(self: *const Awaitable) bool {
        return self.waiting_list.getState() == complete;
    }

    /// Get the typed result from this awaitable.
    /// Dispatches to the appropriate task type based on kind.
    pub fn getTypedResult(self: *Awaitable, comptime T: type) T {
        return switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).getResult(T),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).getResult(T),
        };
    }

    /// Release the awaitable, decrementing the reference count and destroying it if necessary.
    pub fn release(self: *Awaitable, rt: *Runtime) void {
        if (self.ref_count.decr()) self.destroy(rt);
    }

    /// Destroy the awaitable, freeing any associated resources.
    pub fn destroy(self: *Awaitable, rt: *Runtime) void {
        switch (self.kind) {
            .task => AnyTask.fromAwaitable(self).destroy(rt),
            .blocking_task => AnyBlockingTask.fromAwaitable(self).destroy(rt),
        }
    }
};
