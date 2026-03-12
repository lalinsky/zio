// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const options = @import("zio_options");
const net = @import("../net.zig");
const Mutex = @import("../sync/Mutex.zig");

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

/// DNS resolver backend type.
pub const ResolverType = enum {
    /// Use system resolver (getaddrinfo or platform-specific async API).
    system,
    /// Use native Zig DNS resolver (pure Zig, no libc for DNS).
    native,
};

const ev_backend = @import("../ev/backend.zig");

/// The selected DNS resolver backend.
pub const resolver_type: ResolverType = blk: {
    if (options.dns_resolver) |resolver_name| {
        if (std.mem.eql(u8, resolver_name, "system")) {
            break :blk .system;
        } else if (std.mem.eql(u8, resolver_name, "native")) {
            break :blk .native;
        } else {
            @compileError("Unknown DNS resolver: " ++ resolver_name);
        }
    }

    // Default: use system resolver
    // Native resolver doesn't support all configurations (mDNS, systemd-resolved, etc.)
    break :blk .system;
};

/// System resolver implementation (getaddrinfo-based).
pub const system = if (builtin.os.tag == .windows)
    @import("windows.zig")
else if (builtin.os.tag.isDarwin() and ev_backend.backend == .kqueue)
    @import("darwin.zig")
else
    @import("posix.zig");

/// Native DNS resolver (pure Zig, no libc for DNS).
pub const native = @import("native/root.zig");

/// The selected implementation.
pub const impl = switch (resolver_type) {
    .system => system,
    .native => native_wrapper,
};

pub const Result = impl.Result;
pub const lookup = impl.lookup;

/// Wrapper to adapt native resolver to the same interface as system resolvers.
const native_wrapper = struct {
    pub const Result = struct {
        inner: native.LookupResult,
        current_idx: usize = 0,
        returned_canonical: bool = false,
        return_canonical_name: bool,
        canonical_name_buf: [HostName.max_len]u8 = undefined,

        pub fn deinit(self: *@This()) void {
            _ = self;
            // Native resolver doesn't allocate
        }

        pub fn next(self: *@This()) ?LookupResult {
            // Return canonical name first if requested
            if (self.return_canonical_name and !self.returned_canonical) {
                self.returned_canonical = true;
                if (self.inner.canonical_name) |cname| {
                    const name_str = cname.toString(&self.canonical_name_buf);
                    if (name_str.len > 0) {
                        return .{ .canonical_name = .{ .bytes = self.canonical_name_buf[0..name_str.len] } };
                    }
                }
            }

            // Return addresses
            if (self.current_idx < self.inner.addresses.len) {
                const addr = self.inner.addresses.buffer[self.current_idx];
                self.current_idx += 1;
                return .{ .address = addr };
            }

            return null;
        }
    };

    // Shared resolver instance (lazy initialized, protected by mutex)
    var resolver: ?native.Resolver = null;
    var resolver_init_error: bool = false;
    var mutex: Mutex = .{};

    pub fn lookup(opts: LookupOptions) LookupError!@This().Result {
        try mutex.lock();
        defer mutex.unlock();

        // Lazy init under lock
        if (resolver_init_error) return error.Unexpected;
        if (resolver == null) {
            resolver = native.Resolver.initFromSystem() catch |err| {
                // Don't latch cancellation as permanent failure
                if (err == error.Canceled) return error.Canceled;
                resolver_init_error = true;
                return error.Unexpected;
            };
        }

        const native_result = resolver.?.lookup(opts.name, opts.port, .{
            .family = opts.family,
        }) catch |err| return switch (err) {
            error.UnknownHostName => error.UnknownHostName,
            error.TemporaryNameServerFailure => error.TemporaryNameServerFailure,
            error.NameServerFailure => error.NameServerFailure,
            error.HostLacksNetworkAddresses => error.HostLacksNetworkAddresses,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            // Map native-specific errors to existing types
            error.InvalidResponse, error.Truncated => error.NameServerFailure,
            error.Timeout, error.NetworkUnreachable, error.ConnectionRefused => error.TemporaryNameServerFailure,
            error.Unexpected => error.Unexpected,
        };

        return .{
            .inner = native_result,
            .return_canonical_name = opts.canonical_name,
        };
    }
};

test {
    _ = native;
    _ = system;
}
