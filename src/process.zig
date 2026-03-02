// SPDX-FileCopyrightText: 2026 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");

const posix = @import("os/posix.zig");
const windows = @import("os/windows.zig");

pub const Id = switch (builtin.os.tag) {
    .windows => windows.DWORD,
    else => posix.pid_t,
};

pub const Child = struct {
    id: Id,

    pub const Status = union(enum) {
        exited: u8,
        signal: u32,
        stopped: u32,
        unknown: u32,
    };

    pub fn kill(self: *Child) !void {
        _ = self;
        @panic("TODO");
    }

    pub fn terminate(self: *Child) !void {
        _ = self;
        @panic("TODO");
    }

    pub fn wait(self: *Child) !Status {
        _ = self;
        @panic("TODO");
    }
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
