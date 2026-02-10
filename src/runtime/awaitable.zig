// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../utils/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const GroupNode = @import("group.zig").GroupNode;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const SimpleQueue = @import("../utils/wait_queue.zig").SimpleWaitQueue;
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
    ref_count: RefCounter(u8) = RefCounter(u8).init(),

    wait_node: WaitNode,

    // WaitNodes waiting for the completion of this awaitable
    // Uses WaitQueue flag to track completion:
    // - flag clear = not complete
    // - flag set = complete
    waiting_list: WaitQueue(WaitNode) = .empty,

    // Group membership - group_node.group is null if standalone
    group_node: GroupNode = .{},

    // Future protocol - type-erased result type
    pub const Result = void;

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
    pub fn asyncWait(self: *Awaitable, wait_node: *WaitNode) bool {
        // Fast path: check if already complete
        if (self.waiting_list.isFlagSet()) {
            return false;
        }
        // Try to push to queue - only succeeds if awaitable is not complete (flag not set)
        return self.waiting_list.pushUnlessFlag(wait_node);
    }

    /// Cancels a pending wait operation by removing the wait node.
    /// This is part of the Future protocol for select().
    /// Returns true if removed, false if already removed by completion (wake in-flight).
    pub fn asyncCancelWait(self: *Awaitable, wait_node: *WaitNode) bool {
        return self.waiting_list.remove(wait_node);
    }

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    /// Waiting tasks may belong to different executors, so always uses `.maybe_remote` mode.
    /// Can be called from any context.
    pub fn markComplete(self: *Awaitable) void {
        // Pop and wake all waiters while setting the flag
        while (self.waiting_list.popAndSetFlag()) |wait_node| {
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
