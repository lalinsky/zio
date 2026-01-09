// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const JoinHandle = runtime.JoinHandle;

pub const AutoCancel = @import("runtime/autocancel.zig").AutoCancel;

pub const Group = @import("runtime/group.zig").Group;

const common = @import("common.zig");
pub const Cancelable = common.Cancelable;
pub const Timeoutable = common.Timeoutable;

pub const Duration = @import("time.zig").Duration;

const fs = @import("fs.zig");
pub const File = fs.File;
pub const Dir = fs.Dir;

pub const net = @import("net.zig");

pub const Mutex = @import("sync/Mutex.zig");
pub const Condition = @import("sync/Condition.zig");
pub const ResetEvent = @import("sync/ResetEvent.zig");
pub const Notify = @import("sync/Notify.zig");
pub const Semaphore = @import("sync/Semaphore.zig");
pub const Barrier = @import("sync/Barrier.zig");
pub const Futex = @import("sync/Futex.zig");
pub const Channel = @import("sync/channel.zig").Channel;
pub const BroadcastChannel = @import("sync/broadcast_channel.zig").BroadcastChannel;
pub const Future = @import("sync/future.zig").Future;

pub const Signal = @import("signal.zig").Signal;
pub const SignalKind = @import("signal.zig").SignalKind;

pub const select = @import("select.zig").select;
pub const wait = @import("select.zig").wait;
pub const SelectResult = @import("select.zig").SelectResult;
pub const WaitResult = @import("select.zig").WaitResult;

/// Low-level coroutine library.
pub const coro = @import("coro/root.zig");

/// Low-level event loop library.
pub const ev = @import("ev/root.zig");

/// Low-level OS APIs.
pub const os = @import("os/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("stdio.zig");
}
