// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

/// FreeBSD specific system calls and definitions

// umtx operations
// Reference: https://github.com/freebsd/freebsd-src/blob/main/sys/sys/umtx.h
pub const UMTX_OP_WAIT_UINT: c_int = 11;
pub const UMTX_OP_WAKE: c_int = 3;

pub extern "c" fn _umtx_op(obj: *const u32, op: c_int, val: c_ulong, uaddr: ?*anyopaque, uaddr2: ?*anyopaque) c_int;
