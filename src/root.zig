// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

pub const Coroutine = @import("coroutines.zig").Coroutine;
pub const Closure = @import("coroutines.zig").Closure;

pub const Context = @import("coroutines.zig").Context;
pub const switchContext = @import("coroutines.zig").switchContext;
pub const setupContext = @import("coroutines.zig").setupContext;
pub const EntryPointFn = @import("coroutines.zig").EntryPointFn;

pub const StackInfo = @import("stack.zig").StackInfo;
pub const stackAlloc = @import("stack.zig").stackAlloc;
pub const stackFree = @import("stack.zig").stackFree;
pub const setupStackGrowth = @import("stack.zig").setupStackGrowth;
pub const cleanupStackGrowth = @import("stack.zig").cleanupStackGrowth;

pub const StackPool = @import("stack_pool.zig").StackPool;
pub const StackPoolConfig = @import("stack_pool.zig").Config;

test {
    _ = @import("coroutines.zig");
    _ = @import("stack.zig");
    _ = @import("stack_pool.zig");
}
