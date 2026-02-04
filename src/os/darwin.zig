// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

/// Darwin/macOS specific system calls and definitions

// ulock operations (__ulock_wait/__ulock_wake)
// These are undocumented but stable APIs (Darwin 16+, macOS 10.12+)
// Used internally by LLVM libc++
// Reference: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/ulock.h

pub const UL_COMPARE_AND_WAIT: u32 = 1;
pub const ULF_WAKE_THREAD: u32 = 0x100;
pub const ULF_WAKE_ALL: u32 = 0x200;

pub extern "c" fn __ulock_wait(operation: u32, addr: *u32, value: u64, timeout_us: u32) c_int;
pub extern "c" fn __ulock_wake(operation: u32, addr: *u32, wake_value: u64) c_int;
