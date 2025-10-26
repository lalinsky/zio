const WaitQueue = @import("../utils/wait_queue.zig").WaitQueue;
const Awaitable = @import("Awaitable.zig").Awaitable;

/// Registry of all awaitables (tasks and blocking tasks) in the runtime.
/// Used for lifecycle management and preventing spawns during shutdown.
///
/// State encoding:
/// - sentinel0 (empty_open): No awaitables, accepting new spawns
/// - sentinel1 (empty_closed): No awaitables, runtime shutting down, reject spawns
/// - pointer: Has awaitables, accepting new spawns
pub const AwaitableList = @This();

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
