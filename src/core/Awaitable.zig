const std = @import("std");
const builtin = @import("builtin");

const RefCounter = @import("../sync/ref_counter.zig").RefCounter;
const WaitNode = @import("WaitNode.zig");
const ConcurrentQueue = @import("../utils/concurrent_queue.zig").ConcurrentQueue;

// Forward declaration - Runtime is defined in runtime.zig
const Runtime = @import("../runtime.zig").Runtime;

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    task,
    blocking_task,
    future,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *Awaitable) void,

    wait_node: WaitNode,

    // Universal state for both coroutines and threads
    // 0 = pending/not ready, 1 = complete/ready
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Cancellation flag - set to request cancellation, consumed by yield()
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // WaitNodes waiting for the completion of this awaitable
    waiting_list: ConcurrentQueue(WaitNode) = .empty,

    /// Request cancellation of this awaitable.
    /// The cancellation flag will be consumed by the next yield() call.
    pub fn requestCancellation(self: *Awaitable) void {
        self.canceled.store(true, .release);
    }
};
