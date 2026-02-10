// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

const WaitNode = @This();

// For participation in wait queues
prev: ?*WaitNode = null,
next: ?*WaitNode = null,
in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},

// User data associated with this wait node
userdata: usize = undefined,
