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
pub const UMTX_OP_MUTEX_TRYLOCK: c_int = 4;
pub const UMTX_OP_MUTEX_LOCK: c_int = 5;
pub const UMTX_OP_MUTEX_UNLOCK: c_int = 6;
pub const UMTX_OP_CV_WAIT: c_int = 8;
pub const UMTX_OP_CV_SIGNAL: c_int = 9;
pub const UMTX_OP_CV_BROADCAST: c_int = 10;

// umutex flags
pub const UMUTEX_UNOWNED: c_int = 0x0;
pub const UMUTEX_CONTESTED: u32 = 0x80000000;

// Condition variable flags for UMTX_OP_CV_WAIT
pub const CVWAIT_ABSTIME: c_ulong = 0x02;
pub const CVWAIT_CLOCKID: c_ulong = 0x04;

pub const umutex = extern struct {
    m_owner: std.c.pid_t, // lwpid_t - thread ID or 0 if unowned
    m_flags: u32,
    m_ceilings: [2]u32,
    m_rb_lnk: usize,
    m_spare: [2]u32,
};

pub const ucond = extern struct {
    c_has_waiters: u32,
    c_flags: u32,
    c_clockid: u32,
    c_spare: [1]u32,
};

pub extern "c" fn _umtx_op(obj: *const anyopaque, op: c_int, val: c_ulong, uaddr: ?*anyopaque, uaddr2: ?*anyopaque) c_int;
