// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const net = @import("../net.zig");
const runtime = @import("../runtime.zig");

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

/// Extended error set used internally by Resolver/NoResolver. Includes
/// UseSystemResolver, which signals the dispatch wrapper to fall back to the
/// platform getaddrinfo rather than propagating an error to the caller.
pub const ResolverError = LookupError || error{UseSystemResolver};

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
    if (options.family) |required_family| {
        if (IpAddress.parseIp(options.name, 0)) |addr| {
            if (addr.getFamily() != required_family) return error.AddressFamilyUnsupported;
        } else |_| {}
    }
    if (runtime.getCurrentExecutorOrNull()) |exec| {
        if (exec.runtime.resolver) |*resolver| {
            if (resolver.lookup(storage, options)) |n| {
                return n;
            } else |err| switch (err) {
                error.UseSystemResolver => {},
                else => |e| return e,
            }
        }
    }
    return impl.lookup(storage, options);
}

pub const Resolver = if (builtin.os.tag != .windows)
    @import("resolver/root.zig").Resolver
else
    @import("resolver/noop.zig").NoResolver;

test {
    _ = @import("test.zig");
}
