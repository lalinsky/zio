// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");

pub const IpAddress = net.IpAddress;
pub const HostName = net.HostName;

pub const LookupOptions = struct {
    name: []const u8,
    port: u16,
    family: ?IpAddress.Family = null,
    canonical_name: bool = false,
};

pub const LookupResult = union(enum) {
    address: IpAddress,
    canonical_name: HostName,
};

pub const LookupError = error{
    HostLacksNetworkAddresses,
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyNotSupported,
    OutOfMemory,
    UnknownHostName,
    ServiceUnavailable,
    Unexpected,
    ProcessFdQuotaExceeded,
    SystemResources,
    Canceled,
    RuntimeShutdown,
    Closed,
    NoThreadPool,
} || std.posix.UnexpectedError;

pub const impl = switch (builtin.os.tag) {
    .windows => @import("windows.zig"),
    else => @import("posix.zig"),
};

pub const Result = impl.Result;
pub const lookup = impl.lookup;
