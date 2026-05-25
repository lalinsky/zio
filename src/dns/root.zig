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
    canonical_name_buffer: ?*[HostName.max_len]u8 = null,
};

pub const LookupResult = union(enum) {
    address: IpAddress,
    canonical_name: HostName,
};

pub const LookupError = error{
    HostLacksNetworkAddresses,
    TemporaryNameServerFailure,
    NameServerFailure,
    AddressFamilyUnsupported,
    OutOfMemory,
    UnknownHostName,
    ServiceUnavailable,
    Unexpected,
    ProcessFdQuotaExceeded,
    SystemResources,
    Canceled,
    RuntimeShutdown,
    NoThreadPool,
    TooManyAddresses,
};

const Executor = @import("../runtime.zig").Executor;
const backend = @import("../ev/backend.zig");

pub const impl = if (builtin.os.tag == .windows)
    @import("windows.zig")
else if (builtin.os.tag.isDarwin() and backend.backend == .kqueue)
    @import("darwin.zig")
else
    @import("posix.zig");

pub fn lookup(
    storage: []LookupResult,
    options: LookupOptions,
) LookupError!usize {
    if (Executor.current) |exec| {
        if (exec.runtime.resolver) |*resolver| {
            return resolver.lookup(storage, options);
        }
    }
    return impl.lookup(storage, options);
}

pub const Resolver = if (builtin.os.tag != .windows)
    @import("resolver/root.zig").Resolver
else
    @import("resolver/noop.zig").NoResolver;
