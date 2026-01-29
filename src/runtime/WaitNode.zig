// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const WaitNode = @This();

vtable: *const VTable,

// For participation in wait queues
prev: ?*WaitNode = null,
next: ?*WaitNode = null,
in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},

// User data associated with this wait node
userdata: usize = undefined,

pub const VTable = struct {
    // Called when this node should be woken
    wake: *const fn (self: *WaitNode) void = defaultWake,
};

fn defaultWake(self: *WaitNode) void {
    // Default wake implementation does nothing
    _ = self;
}

/// Wake this wait node
pub fn wake(self: *WaitNode) void {
    self.vtable.wake(self);
}
