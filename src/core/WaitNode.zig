const builtin = @import("builtin");

const WaitNode = @This();

vtable: *const VTable,

// For participation in wait queues
prev: ?*WaitNode = null,
next: ?*WaitNode = null,
tail: ?*WaitNode = null, // For CompactWaitQueue
in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

// User data associated with this wait node
userdata: usize = undefined,

pub const VTable = struct {
    // Called when this node should be woken
    wake: *const fn (self: *WaitNode) void = defaultWake,
};

fn defaultWake(self: *WaitNode) void {
    // Default wake implementation does nothing
    _ = self;
}

/// Wake this wait node
pub fn wake(self: *WaitNode) void {
    self.vtable.wake(self);
}
