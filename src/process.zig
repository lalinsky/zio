// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const posix = @import("os/posix.zig");
const windows = @import("os/windows.zig");

pub const Id = switch (builtin.os.tag) {
    .windows => windows.DWORD,
    else => posix.pid_t,
};

pub fn getCurrentId() Id {
    return switch (builtin.os.tag) {
        .windows => windows.GetCurrentProcessId(),
        else => posix.getpid(),
    };
}

test "getCurrentId" {
    const pid = getCurrentId();
    try std.testing.expect(pid > 0);
}
