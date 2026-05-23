// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Native DNS resolver — reads /etc/hosts, /etc/resolv.conf,
//! and sends DNS queries directly via UDP/TCP. Falls back to
//! the platform getaddrinfo when disabled or unavailable.

const std = @import("std");
const dns = @import("../root.zig");

pub const Resolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    pub fn lookup(
        _: *Resolver,
        storage: []dns.LookupResult,
        _: dns.LookupOptions,
    ) dns.LookupError!usize {
        _ = storage;
        return error.UnknownHostName;
    }
};
