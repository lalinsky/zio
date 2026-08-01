// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// NetBSD specific system calls and definitions

// Native futex, Linux-compatible semantics (sys/futex.h, NetBSD >= 9).
// FUTEX_WAIT blocks while *uaddr == val with a relative timeout (ETIMEDOUT on
// expiry, EAGAIN when the value already changed); FUTEX_WAKE wakes up to val
// waiters. libc ships no ___futex stub, so the call goes through the generic
// syscall(2) entry point. References:
// https://github.com/NetBSD/src/blob/trunk/sys/sys/futex.h
// https://github.com/NetBSD/src/blob/trunk/sys/kern/syscalls.master
pub const FUTEX_WAIT: c_int = 0;
pub const FUTEX_WAKE: c_int = 1;
pub const FUTEX_PRIVATE_FLAG: c_int = 128;

pub const SYS___futex: c_int = 166;

pub extern "c" fn syscall(number: c_int, ...) c_int;

pub fn futex(
    uaddr: *const u32,
    op: c_int,
    val: c_int,
    timeout: ?*const std.c.timespec,
    uaddr2: ?*u32,
    val2: c_int,
    val3: c_int,
) c_int {
    return syscall(SYS___futex, uaddr, op, val, timeout, uaddr2, val2, val3);
}

// LWP (Light Weight Process) park/unpark operations
// Reference: https://github.com/NetBSD/src/blob/trunk/sys/sys/lwp.h
pub extern "c" fn _lwp_self() c_int;

pub extern "c" fn ___lwp_park60(
    clock_id: c_int,
    flags: c_int,
    ts: ?*const std.c.timespec,
    unpark: c_int,
    hint: ?*const anyopaque,
    unparkhint: ?*const anyopaque,
) c_int;

pub extern "c" fn _lwp_unpark(target: c_int, hint: ?*const anyopaque) c_int;

pub const pthread_cond_t = std.c.pthread_cond_t;
pub const pthread_cond_init = std.c.pthread_cond_init;
pub const pthread_cond_destroy = std.c.pthread_cond_destroy;
pub const pthread_cond_wait = std.c.pthread_cond_wait;
pub const pthread_cond_timedwait = std.c.pthread_cond_timedwait;
pub const pthread_cond_signal = std.c.pthread_cond_signal;
pub const pthread_cond_broadcast = std.c.pthread_cond_broadcast;

pub const CLOCK = std.c.CLOCK;

pub const sched_yield = @import("c.zig").sched_yield;
