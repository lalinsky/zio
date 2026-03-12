// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Native DNS resolver implementation.
//!
//! This module provides a pure-Zig DNS resolver that communicates directly
//! with DNS servers over UDP/TCP, similar to Go's native resolver.
//!
//! Benefits over getaddrinfo:
//! - Truly async (no thread pool slot consumed)
//! - Better cancellation support
//! - Can query additional record types (SRV, MX, TXT)
//! - No cgo/libc dependency
//!
//! Limitations:
//! - Does not support mDNS (.local domains)
//! - Does not support LLMNR
//! - May not respect systemd-resolved or VPN split-DNS configurations

pub const message = @import("message.zig");
pub const config = @import("config.zig");
pub const hosts = @import("hosts.zig");
pub const resolver = @import("resolver.zig");

pub const Config = config.Config;
pub const Resolver = resolver.Resolver;
pub const LookupError = resolver.LookupError;
pub const LookupResult = resolver.LookupResult;
pub const LookupOptions = resolver.LookupOptions;

pub const Name = message.Name;
pub const Type = message.Type;
pub const Header = message.Header;

test {
    _ = message;
    _ = config;
    _ = hosts;
    _ = resolver;
}
