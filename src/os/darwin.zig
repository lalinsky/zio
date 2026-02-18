// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

/// Darwin/macOS specific system calls and definitions

// ulock operations (__ulock_wait/__ulock_wake)
// These are undocumented but stable APIs (Darwin 16+, macOS 10.12+)
// Used internally by LLVM libc++
// Reference: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/ulock.h

pub const UL_COMPARE_AND_WAIT: u32 = 1;
pub const ULF_NO_ERRNO: u32 = 0x01000000;
pub const ULF_WAKE_ALL: u32 = 0x100;
pub const ULF_WAKE_THREAD: u32 = 0x200;

pub extern "c" fn __ulock_wait(operation: u32, addr: ?*const anyopaque, value: u64, timeout_us: u32) c_int;
pub extern "c" fn __ulock_wake(operation: u32, addr: ?*const anyopaque, wake_value: u64) c_int;

// os_unfair_lock operations
// Efficient low-level lock (macOS 10.12+, iOS 10.0+)
// Reference: https://developer.apple.com/documentation/os/os_unfair_lock

pub const os_unfair_lock_t = *os_unfair_lock_s;
pub const os_unfair_lock_s = extern struct {
    _os_unfair_lock_opaque: u32,
};

pub const OS_UNFAIR_LOCK_INIT: os_unfair_lock_s = .{ ._os_unfair_lock_opaque = 0 };

pub extern "c" fn os_unfair_lock_lock(lock: os_unfair_lock_t) void;
pub extern "c" fn os_unfair_lock_unlock(lock: os_unfair_lock_t) void;
pub extern "c" fn os_unfair_lock_trylock(lock: os_unfair_lock_t) bool;

pub const sched_yield = @import("c.zig").sched_yield;

// Mach message types (not re-exported by std.c in Zig 0.15)

pub const mach_port_t = std.c.mach_port_t;

pub const mach_msg_header_t = extern struct {
    msgh_bits: std.c.mach_msg_bits_t,
    msgh_size: std.c.mach_msg_size_t,
    msgh_remote_port: std.c.mach_port_t,
    msgh_local_port: std.c.mach_port_t,
    msgh_voucher_port: std.c.mach_port_name_t,
    msgh_id: std.c.mach_msg_id_t,
};

pub const MACH_RCV_MSG: std.c.mach_msg_option_t = 2;
pub const MACH_PORT_NULL: std.c.mach_port_t = 0;

pub extern "c" fn mach_msg(
    msg: *mach_msg_header_t,
    option: std.c.mach_msg_option_t,
    send_size: std.c.mach_msg_size_t,
    rcv_size: std.c.mach_msg_size_t,
    rcv_name: std.c.mach_port_name_t,
    timeout: std.c.mach_msg_timeout_t,
    notify: std.c.mach_port_name_t,
) std.c.kern_return_t;

// libinfo async DNS resolution

pub const getaddrinfo_async_callback = *const fn (i32, ?*std.c.addrinfo, ?*anyopaque) callconv(.c) void;

pub extern "c" fn getaddrinfo_async_start(
    port: *mach_port_t,
    hostname: ?[*:0]const u8,
    servname: ?[*:0]const u8,
    hints: ?*const std.c.addrinfo,
    callback: getaddrinfo_async_callback,
    context: ?*anyopaque,
) i32;

pub extern "c" fn getaddrinfo_async_handle_reply(msg: *mach_msg_header_t) i32;
pub extern "c" fn getaddrinfo_async_cancel(port: mach_port_t) void;

const std = @import("std");
