// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// NetBSD specific system calls and definitions

// LWP (Light Weight Process) park/unpark operations
// Reference: https://github.com/NetBSD/src/blob/trunk/sys/sys/lwp.h
pub extern "c" fn _lwp_self() c_int;

pub extern "c" fn ___lwp_park60(
    clock_id: c_int,
    flags: c_int,
    ts: ?*const std.posix.timespec,
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

pub const sched_yield = @import("c.zig").sched_yield;
