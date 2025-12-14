// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../utils/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const GroupNode = @import("group.zig").GroupNode;
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const WaitResult = @import("../select.zig").WaitResult;
const Cancelable = @import("../common.zig").Cancelable;
const select = @import("../select.zig");

// Forward declaration - Runtime is defined in runtime.zig
const Runtime = @import("../runtime.zig").Runtime;

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    task,
    blocking_task,
};

// Cancellation status - tracks both user and timeout cancellation
pub const CanceledStatus = packed struct(u32) {
    user_canceled: bool = false,
    timeout: u8 = 0,
    pending_errors: u16 = 0,
    _padding: u7 = 0,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *Awaitable) void,

    wait_node: WaitNode,

    // Completion status - true when awaitable has completed
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Cancellation status - tracks user cancel, timeout, and pending errors
    canceled_status: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

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

    // Group membership - group_node.group is null if standalone
    group_node: GroupNode = .{},

    // Future protocol - type-erased result type
    pub const Result = void;

    pub const State = WaitQueue(WaitNode).State;
    pub const not_complete = State.sentinel0;
    pub const complete = State.sentinel1;

    /// Request cancellation of this awaitable.
    /// This will set user_canceled flag and increment pending_errors.
    /// If the task is currently suspended, we will wake it up,
    /// so that it can handle the cancellation (e.g. cancel the underlying I/O operation).
    /// If the task is already running/dead, the wake is a noop.
    pub fn cancel(self: *Awaitable) void {
        // CAS loop to set user_canceled and increment pending_errors
        var current = self.canceled_status.load(.acquire);
        while (true) {
            var status: CanceledStatus = @bitCast(current);

            // Set user_canceled flag
            status.user_canceled = true;

            // Increment pending_errors
            status.pending_errors += 1;

            const new: u32 = @bitCast(status);
            if (self.canceled_status.cmpxchgWeak(current, new, .acq_rel, .acquire)) |prev| {
                // CAS failed, use returned previous value and retry
                current = prev;
                continue;
            }
            // CAS succeeded
            break;
        }

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

/// Registry of all awaitables (tasks and blocking tasks) in the runtime.
/// Used for lifecycle management.
pub const AwaitableList = struct {
    queue: WaitQueue(Awaitable) = .empty,

    /// Add an awaitable to the registry.
    pub fn add(self: *AwaitableList, awaitable: *Awaitable) void {
        self.queue.push(awaitable);
    }

    /// Remove an awaitable from the registry.
    /// Returns true if the awaitable was found and removed.
    pub fn remove(self: *AwaitableList, awaitable: *Awaitable) bool {
        return self.queue.remove(awaitable);
    }

    /// Returns true if the registry has no awaitables.
    pub fn isEmpty(self: *const AwaitableList) bool {
        const state = self.queue.getState();
        return !state.isPointer();
    }
};
