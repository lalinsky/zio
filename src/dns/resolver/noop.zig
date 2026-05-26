// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const dns = @import("../root.zig");

/// Stub resolver used on platforms where the native resolver is not supported.
/// Always falls through to the platform getaddrinfo implementation.
pub const NoResolver = struct {
    pub fn init(_: std.mem.Allocator) NoResolver {
        return .{};
    }

    pub fn deinit(_: *NoResolver) void {}

    pub fn lookup(
        _: *NoResolver,
        _: []dns.LookupResult,
        _: dns.LookupOptions,
    ) dns.ResolverError!usize {
        return error.UseSystemResolver;
    }
};
