// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Native DNS resolver — reads /etc/hosts, /etc/resolv.conf,
//! and sends DNS queries directly via UDP/TCP. Falls back to
//! the platform getaddrinfo when disabled or unavailable.

const resolvconf = @import("resolvconf.zig");
const hosts = @import("hosts.zig");
const resolver = @import("resolver.zig");
const message = @import("message.zig");

pub const Hosts = hosts.Hosts;
pub const ResolvConf = resolvconf.ResolvConf;
pub const Resolver = resolver.Resolver;

test {
    _ = resolvconf;
    _ = hosts;
    _ = resolver;
    _ = message;
}
