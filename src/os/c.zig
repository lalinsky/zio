// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

/// Common libc declarations shared across POSIX platforms.

// Thread yield
pub extern "c" fn sched_yield() c_int;
