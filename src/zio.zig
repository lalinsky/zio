// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Re-export coroutine functionality
pub const coroutines = @import("coroutines.zig");
pub const Coroutine = coroutines.Coroutine;
pub const CoroutineState = coroutines.CoroutineState;

// Re-export runtime functionality
const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const SpawnOptions = runtime.SpawnOptions;
pub const JoinHandle = runtime.JoinHandle;

// Re-export common error sets
const common = @import("common.zig");
pub const Cancelable = common.Cancelable;
pub const Timeoutable = common.Timeoutable;

// Re-export I/O functionality
pub const File = @import("io/file.zig").File;
pub const fs = @import("fs.zig");

// Re-export network functionality
pub const net = @import("net.zig");

// Re-export synchronization primitives
pub const Mutex = @import("sync.zig").Mutex;
pub const Condition = @import("sync.zig").Condition;
pub const ResetEvent = @import("sync.zig").ResetEvent;
pub const Semaphore = @import("sync.zig").Semaphore;
pub const Barrier = @import("sync.zig").Barrier;
pub const Channel = @import("sync.zig").Channel;
pub const BroadcastChannel = @import("sync.zig").BroadcastChannel;

// Re-export signal handling
pub const Signal = @import("signal.zig").Signal;
pub const SignalKind = @import("signal.zig").SignalKind;

// Re-export select functionality
pub const select = @import("select.zig").select;
pub const wait = @import("select.zig").wait;
pub const SelectResult = @import("select.zig").SelectResult;
pub const WaitResult = @import("select.zig").WaitResult;

// Re-export low-level utilities
pub const util = @import("utils.zig");

test {
    std.testing.refAllDecls(@This());
}
