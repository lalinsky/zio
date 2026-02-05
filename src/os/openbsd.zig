// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

/// OpenBSD specific system calls and definitions

// futex operations (OpenBSD has 64 futex buckets)
// Reference: https://github.com/openbsd/src/blob/master/sys/sys/futex.h
pub const FUTEX_WAIT: c_int = 1;
pub const FUTEX_WAKE: c_int = 2;
pub const FUTEX_PRIVATE_FLAG: c_int = 128;

pub extern "c" fn futex(uaddr: *const u32, op: c_int, val: c_int, timeout: ?*const std.posix.timespec, uaddr2: ?*u32) c_int;
