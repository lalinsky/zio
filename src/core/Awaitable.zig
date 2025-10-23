const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../utils/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;

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

    pub const State = WaitQueue(WaitNode).State;
    pub const not_complete = State.sentinel0;
    pub const complete = State.sentinel1;

    /// Request cancellation of this awaitable.
    /// The cancellation flag will be consumed by the next yield() call.
    pub fn requestCancellation(self: *Awaitable) void {
        self.canceled.store(true, .release);
    }

    /// Registers a wait node to be notified when the awaitable completes.
    /// This is part of the Future protocol for select().
    /// Returns false if the awaitable is already complete (no wait needed), true if added to queue.
    pub fn asyncWait(self: *const Awaitable, wait_node: *WaitNode) bool {
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
    pub fn asyncCancelWait(self: *const Awaitable, wait_node: *WaitNode) void {
        // Cast away const to mutate the waiting list
        const mutable_self: *Awaitable = @constCast(self);
        _ = mutable_self.waiting_list.remove(wait_node);
    }
};
