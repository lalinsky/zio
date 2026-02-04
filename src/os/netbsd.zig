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
