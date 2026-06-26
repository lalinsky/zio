// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

// DEBUG (iocp-debug branch only): surface log.warn/info/debug in release test
// builds so IOCP cross-loop tracing is visible in CI. Do not merge.
pub const std_options: std.Options = .{ .log_level = .debug };

// DEBUG (iocp-debug branch only): dump the trace ring on any panic / access
// violation (Zig converts segfaults to panics in safe modes), so a crash that
// happens before the watchdog's stall dump still yields the lead-up. Do not merge.
pub const panic = std.debug.FullPanic(panicHandler);
fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    @import("debug_trace.zig").dump();
    std.debug.defaultPanic(msg, ret_addr);
}

const runtime = @import("runtime.zig");
pub const Runtime = runtime.Runtime;
pub const RuntimeOptions = runtime.RuntimeOptions;
pub const JoinHandle = runtime.JoinHandle;

// Standalone task functions
pub const spawn = runtime.spawn;
pub const spawnBlocking = runtime.spawnBlocking;
pub const yield = runtime.yield;
pub const sleep = runtime.sleep;
pub const now = runtime.now;

pub const random = @import("random.zig").random;
pub const randomSecure = @import("random.zig").randomSecure;
pub const RandomSecureError = @import("random.zig").RandomSecureError;
pub const beginShield = runtime.beginShield;
pub const endShield = runtime.endShield;
pub const checkCancel = runtime.checkCancel;

pub const AutoCancel = @import("autocancel.zig").AutoCancel;

pub const Group = @import("group.zig").Group;
pub const CompletionQueue = @import("completion_queue.zig").CompletionQueue;

pub const TaskLocal = @import("task.zig").TaskLocal;

const common = @import("common.zig");
pub const Cancelable = common.Cancelable;
pub const Timeoutable = common.Timeoutable;
pub const blockInPlace = common.blockInPlace;

pub const time = @import("time.zig"); // TODO: make non-pub
pub const Duration = time.Duration;
pub const Timestamp = time.Timestamp;
pub const Timeout = time.Timeout;
pub const Stopwatch = time.Stopwatch;

const fs = @import("fs.zig");
pub const File = fs.File;
pub const Dir = fs.Dir;
pub const PipePair = fs.PipePair;

pub const stdin = fs.stdin;
pub const stdout = fs.stdout;
pub const stderr = fs.stderr;

pub const net = @import("net.zig");

pub const Mutex = @import("sync/Mutex.zig");
pub const Condition = @import("sync/Condition.zig");
pub const ResetEvent = @import("sync/ResetEvent.zig");
pub const Notify = @import("sync/Notify.zig");
pub const RwLock = @import("sync/RwLock.zig");
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

pub const debug_io = @import("io.zig").debug_io;

/// Low-level coroutine library.
pub const coro = @import("coro/root.zig");

/// Low-level event loop library.
pub const ev = @import("ev/root.zig");

/// Low-level OS APIs.
pub const os = @import("os/root.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("io.zig");
    _ = @import("random.zig");
    _ = @import("task.zig");
    _ = @import("iocp_repro.zig"); // DEBUG (#530): standalone AcceptEx repro. Do not merge.
}
