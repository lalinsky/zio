// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

/// DragonFly BSD specific system calls and definitions

// umtx operations
// Note: umtx_sleep's comparison is NOT atomic with sleep, but is
// "properly interlocked" with umtx_wakeup
// Reference: https://github.com/DragonFlyBSD/DragonFlyBSD/blob/master/sys/sys/umtx.h
pub extern "c" fn umtx_sleep(addr: *const u32, value: c_int, timeout: c_int) c_int;
pub extern "c" fn umtx_wakeup(addr: *const u32, count: c_int) c_int;

pub const sched_yield = @import("c.zig").sched_yield;
