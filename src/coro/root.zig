// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Low-level coroutine primitives.
//!
//! This module provides stackful coroutines with manual scheduling.
//! For most use cases, prefer `zio.Runtime` which provides automatic
//! scheduling, I/O integration, and synchronization primitives.
//!
//! Use this module when you need:
//! - Custom scheduling strategies
//! - Integration with external event loops
//! - Fine-grained control over context switching

const std = @import("std");

const coroutines = @import("coroutines.zig");
pub const Coroutine = coroutines.Coroutine;
pub const Context = coroutines.Context;
pub const Closure = coroutines.Closure;
pub const EntryPointFn = coroutines.EntryPointFn;
pub const setupContext = coroutines.setupContext;
pub const switchContext = coroutines.switchContext;

const stack = @import("stack.zig");
pub const Stack = stack.StackInfo;
pub const panicHandler = stack.panicHandler;

// Stacks are allocated and per-thread growth is set up through the pool:
//   var pool = StackPool.init(allocator, config);
//   try StackPool.setup();         // once per thread
//   const stack_info = try pool.acquire();
pub const StackPool = stack.StackPool;
pub const StackPoolConfig = stack.Config;

test {
    std.testing.refAllDecls(@This());
}
