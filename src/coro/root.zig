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
pub const StackExtendMode = stack.StackExtendMode;
pub const stackAlloc = stack.stackAlloc;
pub const stackFree = stack.stackFree;
pub const stackRecycle = stack.stackRecycle;
pub const stackExtend = stack.stackExtend;
pub const setupStackGrowth = stack.setupStackGrowth;
pub const cleanupStackGrowth = stack.cleanupStackGrowth;
pub const panicHandler = stack.panicHandler;

pub const StackPool = @import("stack_pool.zig").StackPool;

test {
    std.testing.refAllDecls(@This());
}
