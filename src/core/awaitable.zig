// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../utils/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitResult = @import("../select.zig").WaitResult;
const Cancelable = @import("../common.zig").Cancelable;
const FutureResult = @import("../future_result.zig").FutureResult;
const select = @import("../select.zig");

// Forward declaration - Runtime is defined in runtime.zig
const Runtime = @import("../runtime.zig").Runtime;

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    task,
    blocking_task,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *Awaitable) void,

    wait_node: WaitNode,

    // Completion status - true when awaitable has completed
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Cancellation flag - set to request cancellation, consumed by yield()
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // WaitNodes waiting for the completion of this awaitable
    // Use WaitQueue sentinel states:
    // - sentinel0 = not complete (no waiters, task not complete)
    // - sentinel1 = complete (no waiters, task is complete)
    // - pointer = waiting (has waiters, task not complete)
    waiting_list: WaitQueue(WaitNode) = .empty,

    // Intrusive list node for Runtime.tasks registry (WaitQueue)
    next: ?*Awaitable = null,
    prev: ?*Awaitable = null,
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

    // Future protocol - type-erased result type
    pub const Result = void;

    pub const State = WaitQueue(WaitNode).State;
    pub const not_complete = State.sentinel0;
    pub const complete = State.sentinel1;

    /// Request cancellation of this awaitable.
    /// This will set a flag that will be read at the next yield point.
    /// If the task is currently suspended, we will wake it up,
    /// so that it can handle the cancelation (e.g. cancel the underlaying I/O operation).
    /// If the task is already running/dead, the wake is a noop.
    pub fn cancel(self: *Awaitable) void {
        self.canceled.store(true, .release);
        self.wait_node.wake();
    }

    /// Registers a wait node to be notified when the awaitable completes.
    /// This is part of the Future protocol for select().
    /// Returns false if the awaitable is already complete (no wait needed), true if added to queue.
    pub fn asyncWait(self: *const Awaitable, _: *Runtime, wait_node: *WaitNode) bool {
        // Fast path: check if already complete
        if (self.done.load(.acquire)) {
            return false;
        }
        // Cast away const to mutate the waiting list
        // This is safe because waiting_list is designed to be mutated even from const contexts
        const mutable_self: *Awaitable = @constCast(self);
        // Try to push to queue - only succeeds if awaitable is not complete
        // Returns false if awaitable is complete, preventing invalid transition: complete -> has_waiters
        return mutable_self.waiting_list.pushUnless(complete, wait_node);
    }

    /// Cancels a pending wait operation by removing the wait node.
    /// This is part of the Future protocol for select().
    pub fn asyncCancelWait(self: *const Awaitable, _: *Runtime, wait_node: *WaitNode) void {
        // Cast away const to mutate the waiting list
        const mutable_self: *Awaitable = @constCast(self);
        _ = mutable_self.waiting_list.remove(wait_node);
    }

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    /// Waiting tasks may belong to different executors, so always uses `.maybe_remote` mode.
    /// Can be called from any context.
    pub fn markComplete(self: *Awaitable) void {
        // Set done flag first (release semantics for memory ordering)
        self.done.store(true, .release);

        // Pop and wake all waiters, then transition to complete
        // Loop continues until popOrTransition successfully transitions not_complete->complete
        while (self.waiting_list.popOrTransition(not_complete, complete)) |wait_node| {
            wait_node.wake();
        }
    }

    /// Get the result (void for type-erased awaitable)
    /// Part of the Future protocol for use with select()
    pub fn getResult(self: *Awaitable) void {
        _ = self;
    }
};

// Future for runtime - not backed by computation, can be set from callbacks
// Shared implementation for all Future types (Task, BlockingTask, Future)
pub fn FutureImpl(comptime T: type, comptime Base: type, comptime Parent: type) type {
    return struct {
        base: Base,
        future_result: FutureResult(T),

        // Future protocol - Result type
        pub const Result = T;

        pub fn wait(parent: *Parent) Cancelable!WaitResult(T) {
            // Check if already completed
            if (parent.impl.future_result.get()) |res| {
                return .{ .value = res };
            }

            // Wait for completion using select.wait()
            const runtime = Parent.getRuntime(parent);
            return try select.wait(runtime, parent);
        }

        pub fn cancel(parent: *Parent) void {
            parent.impl.base.awaitable.cancel();
        }

        pub fn toAny(parent: *Parent) *Base {
            return &parent.impl.base;
        }

        pub fn fromAny(base: *Base) *Parent {
            const impl_ptr: *@This() = @fieldParentPtr("base", base);
            return @fieldParentPtr("impl", impl_ptr);
        }

        pub fn toAwaitable(parent: *Parent) *Awaitable {
            return &parent.impl.base.awaitable;
        }

        pub fn fromAwaitable(awaitable: *Awaitable) *Parent {
            const base_ptr: *Base = @fieldParentPtr("awaitable", awaitable);
            return fromAny(base_ptr);
        }

        pub fn deinit(parent: *Parent) void {
            const runtime = Parent.getRuntime(parent);
            runtime.releaseAwaitable(&parent.impl.base.awaitable, false);
        }

        /// Registers a wait node to be notified when the task completes.
        /// This is part of the Future protocol for select().
        /// Returns false if the task is already complete (no wait needed), true if added to queue.
        pub fn asyncWait(parent: *const Parent, _: *Runtime, wait_node: *WaitNode) bool {
            return parent.impl.base.awaitable.asyncWait(wait_node);
        }

        /// Cancels a pending wait operation by removing the wait node.
        /// This is part of the Future protocol for select().
        pub fn asyncCancelWait(parent: *const Parent, _: *Runtime, wait_node: *WaitNode) void {
            parent.impl.base.awaitable.asyncCancelWait(wait_node);
        }

        /// Gets the result value.
        /// This is part of the Future protocol for select().
        /// Asserts that the task has completed.
        pub fn getResult(parent: *Parent) T {
            return parent.impl.future_result.get().?;
        }
    };
}

/// Registry of all awaitables (tasks and blocking tasks) in the runtime.
/// Used for lifecycle management and preventing spawns during shutdown.
///
/// State encoding:
/// - sentinel0 (empty_open): No awaitables, accepting new spawns
/// - sentinel1 (empty_closed): No awaitables, runtime shutting down, reject spawns
/// - pointer: Has awaitables, accepting new spawns
pub const AwaitableList = struct {
    queue: WaitQueue(Awaitable) = .empty,

    const State = WaitQueue(Awaitable).State;
    const empty_open: State = .sentinel0;
    const empty_closed: State = .sentinel1;

    /// Add an awaitable to the registry.
    /// Returns error.Closed if the runtime is shutting down.
    pub fn add(self: *AwaitableList, awaitable: *Awaitable) error{Closed}!void {
        if (!self.queue.pushUnless(empty_closed, awaitable)) {
            return error.Closed;
        }
    }

    /// Remove an awaitable from the registry.
    /// Returns true if the awaitable was found and removed.
    pub fn remove(self: *AwaitableList, awaitable: *Awaitable) bool {
        return self.queue.remove(awaitable);
    }

    /// Close the registry to prevent new awaitable additions.
    /// Returns error.NotEmpty if the registry still has awaitables.
    /// Idempotent: succeeds if already closed.
    pub fn close(self: *AwaitableList) error{NotEmpty}!void {
        // Try atomic transition: empty_open → empty_closed
        if (!self.queue.tryTransition(empty_open, empty_closed)) {
            const state = self.queue.getState();
            if (state == empty_closed) return; // Already closed, OK
            return error.NotEmpty; // Has awaitables
        }
    }

    /// Returns true if the registry has no awaitables.
    /// Note: Does not distinguish between open/closed states.
    pub fn isEmpty(self: *const AwaitableList) bool {
        const state = self.queue.getState();
        return !state.isPointer();
    }

    /// Returns true if the registry is closed (rejecting new spawns).
    pub fn isClosed(self: *const AwaitableList) bool {
        return self.queue.getState() == empty_closed;
    }

    /// Remove and return the first awaitable from the registry.
    /// When popping the last item, transitions to empty_open (not closed).
    pub fn pop(self: *AwaitableList) ?*Awaitable {
        return self.queue.pop();
    }
};
