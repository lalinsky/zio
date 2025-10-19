// Re-export all synchronization primitives
pub const Mutex = @import("sync/Mutex.zig");
pub const Condition = @import("sync/Condition.zig");
pub const ResetEvent = @import("sync/ResetEvent.zig");
pub const Semaphore = @import("sync/Semaphore.zig");
pub const Barrier = @import("sync/Barrier.zig");

// Generic types
pub const Channel = @import("sync/channel.zig").Channel;
pub const BroadcastChannel = @import("sync/broadcast_channel.zig").BroadcastChannel;

// Re-export tests from individual modules
test {
    _ = Mutex;
    _ = Condition;
    _ = ResetEvent;
    _ = Semaphore;
    _ = Barrier;
    _ = @import("sync/channel.zig");
    _ = @import("sync/broadcast_channel.zig");
}
