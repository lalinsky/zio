//! Low-level utilities for implementing synchronization primitives and memory management.
//!
//! These are internal building blocks not intended for direct use in application code.
//! Use the higher-level primitives from the sync module instead.

const concurrent_queue = @import("utils/concurrent_queue.zig");

pub const ConcurrentQueue = concurrent_queue.ConcurrentQueue;
pub const CompactConcurrentQueue = concurrent_queue.CompactConcurrentQueue;
pub const RefCounter = @import("utils/ref_counter.zig").RefCounter;
pub const SharedPtr = @import("utils/shared_ptr.zig").SharedPtr;
