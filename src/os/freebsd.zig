// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// FreeBSD specific system calls and definitions

// umtx operations
// Reference: https://github.com/freebsd/freebsd-src/blob/main/sys/sys/umtx.h
pub const UMTX_OP_WAIT_UINT: c_int = 11;
pub const UMTX_OP_WAIT_UINT_PRIVATE: c_int = 15;
pub const UMTX_OP_WAKE: c_int = 3;
pub const UMTX_OP_WAKE_PRIVATE: c_int = 16;

/// Timeout for the `UMTX_OP_WAIT_*` requests, passed in `uaddr2` with its own
/// size in `uaddr`. The kernel distinguishes it from a bare `timespec` by that
/// size alone (`umtx_copyin_umtx_time`), and the bare form carries no clock, so
/// this is the only way to ask for anything but `CLOCK_REALTIME`.
///
/// `flags` is zero for an interval; `UMTX_ABSTIME` (0x01) would make `timeout` a
/// deadline instead.
pub const umtx_time = extern struct {
    timeout: std.c.timespec,
    flags: u32,
    clockid: u32,
};

pub extern "c" fn _umtx_op(obj: *const anyopaque, op: c_int, val: c_ulong, uaddr: ?*anyopaque, uaddr2: ?*anyopaque) c_int;

pub const sched_yield = @import("c.zig").sched_yield;
