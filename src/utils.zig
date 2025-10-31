// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

//! Low-level utilities for implementing synchronization primitives and memory management.
//!
//! These are internal building blocks not intended for direct use in application code.
//! Use the higher-level primitives from the sync module instead.

const wait_queue = @import("utils/wait_queue.zig");

pub const WaitQueue = wait_queue.WaitQueue;
pub const WorkStealingQueue = @import("utils/queue.zig").WorkStealingQueue;
pub const RefCounter = @import("utils/ref_counter.zig").RefCounter;
pub const SharedPtr = @import("utils/shared_ptr.zig").SharedPtr;
