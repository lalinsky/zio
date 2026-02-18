// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Windows DNS resolver using GetAddrInfoExW with async completion callback.
//! Unlike the POSIX implementation which dispatches blocking getaddrinfo to the
//! thread pool, this uses the native Windows async API: the completion callback
//! signals the Waiter directly, avoiding a thread pool slot.

const std = @import("std");
const windows = @import("../os/windows.zig");
const os_net = @import("../os/net.zig");
const common = @import("../common.zig");
const Waiter = common.Waiter;
const dns = @import("root.zig");

const ADDRINFOEXW = windows.ADDRINFOEXW;

/// Context placed on the stack while the async lookup is in flight.
const LookupContext = struct {
    overlapped: windows.OVERLAPPED,
    waiter: Waiter,
    err: u32,
};

fn completionCallback(dwError: u32, _: u32, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) void {
    const ctx: *LookupContext = @fieldParentPtr("overlapped", lpOverlapped.?);
    ctx.err = dwError;
    ctx.waiter.signal();
}

pub const Result = struct {
    head: ?*ADDRINFOEXW,
    current: ?*ADDRINFOEXW,
    return_canonical_name: bool,
    canonical_name_buf: [dns.HostName.max_len]u8,

    pub fn deinit(self: *Result) void {
        if (self.head) |head| {
            windows.FreeAddrInfoExW(head);
        }
    }

    pub fn next(self: *Result) ?dns.LookupResult {
        if (self.return_canonical_name) {
            self.return_canonical_name = false;
            if (self.head) |head| {
                if (head.ai_canonname) |name| {
                    const len = std.unicode.utf16LeToUtf8(&self.canonical_name_buf, std.mem.sliceTo(name, 0)) catch 0;
                    if (len > 0) {
                        return .{ .canonical_name = .{ .bytes = self.canonical_name_buf[0..len] } };
                    }
                }
            }
        }

        while (self.current) |info| {
            self.current = info.ai_next;
            const addr = info.ai_addr orelse continue;
            if (addr.family != os_net.AF.INET and addr.family != os_net.AF.INET6) continue;
            return .{ .address = dns.IpAddress.initPosix(@ptrCast(addr), @intCast(info.ai_addrlen)) };
        }
        return null;
    }
};

pub fn lookup(options: dns.LookupOptions) dns.LookupError!Result {
    os_net.ensureWSAInitialized();

    // Convert name to null-terminated UTF-16
    var name_wide: [256:0]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(&name_wide, options.name) catch return error.UnknownHostName;
    name_wide[name_len] = 0;

    // Format port as null-terminated UTF-16
    var port_wide: [8:0]u16 = undefined;
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{options.port}) catch unreachable;
    const port_len = std.unicode.utf8ToUtf16Le(&port_wide, port_str) catch unreachable;
    port_wide[port_len] = 0;

    var hints: ADDRINFOEXW = std.mem.zeroes(ADDRINFOEXW);
    hints.ai_family = if (options.family) |f| switch (f) {
        .ipv4 => @as(i32, os_net.AF.INET),
        .ipv6 => @as(i32, os_net.AF.INET6),
    } else @as(i32, os_net.AF.UNSPEC);
    hints.ai_socktype = os_net.SOCK.STREAM;
    hints.ai_protocol = os_net.IPPROTO.TCP;
    if (options.canonical_name) {
        hints.ai_flags = @bitCast(windows.AI{ .CANONNAME = true });
    }

    var result: ?*ADDRINFOEXW = null;
    var ctx: LookupContext = .{
        .overlapped = std.mem.zeroes(windows.OVERLAPPED),
        .waiter = .init(),
        .err = 0,
    };
    var cancel_handle: windows.HANDLE = undefined;

    const rc = windows.GetAddrInfoExW(
        @ptrCast(&name_wide),
        @ptrCast(&port_wide),
        windows.NS_DNS,
        null,
        &hints,
        &result,
        null,
        &ctx.overlapped,
        completionCallback,
        &cancel_handle,
    );

    if (rc == 0) {
        return .{
            .head = result,
            .current = result,
            .return_canonical_name = options.canonical_name,
            .canonical_name_buf = undefined,
        };
    }

    if (rc != windows.WSA_IO_PENDING) {
        return winsockToLookupError(rc);
    }

    // Async path: wait for the completion callback to signal
    ctx.waiter.wait(1, .allow_cancel) catch {
        // Cancelled — ask Windows to cancel, then wait for the callback
        _ = windows.GetAddrInfoExCancel(&cancel_handle);
        ctx.waiter.wait(1, .no_cancel);

        if (result) |r| windows.FreeAddrInfoExW(r);
        return error.Canceled;
    };

    if (ctx.err != 0) {
        if (result) |r| windows.FreeAddrInfoExW(r);
        return winsockToLookupError(@intCast(ctx.err));
    }

    return .{
        .head = result,
        .current = result,
        .return_canonical_name = options.canonical_name,
        .canonical_name_buf = undefined,
    };
}

fn winsockToLookupError(err: i32) dns.LookupError {
    const wsa_err: windows.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
    return switch (wsa_err) {
        .EAFNOSUPPORT => error.AddressFamilyNotSupported,
        .EINVAL => error.Unexpected,
        .ESOCKTNOSUPPORT => error.Unexpected,
        .NO_DATA => error.UnknownHostName,
        .NO_RECOVERY => error.NameServerFailure,
        .NOTINITIALISED => error.SystemResources,
        .TRY_AGAIN => error.TemporaryNameServerFailure,
        .TYPE_NOT_FOUND => error.ServiceUnavailable,
        .NOT_ENOUGH_MEMORY => error.SystemResources,
        .HOST_NOT_FOUND => error.UnknownHostName,
        else => error.Unexpected,
    };
}
