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
//!
//! ## Stacks
//!
//! `stackAlloc(info, maximum_size, committed_size)` reserves `maximum_size`
//! bytes of address space but makes only the top `committed_size` bytes
//! usable. What happens when a coroutine runs past the committed region
//! depends on the platform:
//!
//! - POSIX: the rest is only reachable through `setupStackGrowth()`, which
//!   installs a SIGSEGV/SIGBUS handler that commits more pages on demand and
//!   reports a real overflow with a "Coroutine stack overflow!" message.
//!   Without it, touching uncommitted stack is a plain segfault, typically
//!   reported at the prologue of whatever function was being entered.
//!   `zio.Runtime` calls it on every executor thread; when using this module
//!   directly, call it on each thread that runs coroutines (and
//!   `cleanupStackGrowth()` when the thread is done), or commit the whole
//!   stack up front.
//! - Windows: the stack grows automatically via guard pages.
//! - OpenBSD: the whole stack is committed at allocation, there is no growth.
//!
//! Size stacks for the code that runs on them, not for the coroutine body
//! alone. Debug builds of the standard library use large frames: even
//! `std.debug.print` needs more than 4 KiB, and 64 KiB is too little for much
//! of `std.Io`. `zio.Runtime` defaults to 8 MiB reserved, 256 KiB committed.

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
pub const crashHandler = stack.crashHandler;

pub const StackPool = @import("stack_pool.zig").StackPool;

test {
    std.testing.refAllDecls(@This());
}
