// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Darwin DNS resolver using libinfo's getaddrinfo_async_start.
//! Uses a mach port monitored via kqueue to get notified when the
//! async DNS result is ready, avoiding blocking a thread pool slot.

const std = @import("std");
const os_net = @import("../os/net.zig");
const darwin = @import("../os/darwin.zig");
const common = @import("../common.zig");
const ev = @import("../ev/root.zig");
const dns = @import("root.zig");

pub const Result = @import("posix.zig").Result;

const LookupContext = struct {
    result: ?*os_net.addrinfo = null,
    status: i32 = 0,
};

fn libinfoCallback(status: i32, result: ?*std.c.addrinfo, context: ?*anyopaque) callconv(.c) void {
    const ctx: *LookupContext = @ptrCast(@alignCast(context));
    ctx.status = status;
    ctx.result = result;
}

/// Buffer for receiving a mach message (header + trailer).
const MachMsgRcv = extern struct {
    header: darwin.mach_msg_header_t,
    _trailer: [32]u8,
};

pub fn lookup(options: dns.LookupOptions) dns.LookupError!Result {
    var buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const name_c = allocator.dupeZ(u8, options.name) catch return error.OutOfMemory;
    const port_c = std.fmt.allocPrintSentinel(allocator, "{d}", .{options.port}, 0) catch return error.OutOfMemory;

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = if (options.family) |f| switch (f) {
        .ipv4 => os_net.AF.INET,
        .ipv6 => os_net.AF.INET6,
    } else os_net.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;
    hints.protocol = std.posix.IPPROTO.TCP;
    if (options.canonical_name) {
        hints.flags.CANONNAME = true;
    }

    var machport: darwin.mach_port_t = 0;
    var ctx: LookupContext = .{};

    const rc = darwin.getaddrinfo_async_start(
        &machport,
        name_c.ptr,
        port_c.ptr,
        &hints,
        libinfoCallback,
        @ptrCast(&ctx),
    );

    if (rc != 0 or machport == 0) {
        return error.Unexpected;
    }

    // Wait for the mach port to receive a message via kqueue
    var mp = ev.MachPort.init(machport);
    common.waitForIo(&mp.c) catch |err| switch (err) {
        error.Canceled => {
            darwin.getaddrinfo_async_cancel(machport);
            return error.Canceled;
        },
    };

    _ = mp.getResult() catch {
        darwin.getaddrinfo_async_cancel(machport);
        return error.Unexpected;
    };

    // Receive the mach message from the port
    var msg: MachMsgRcv = undefined;
    const status = darwin.mach_msg(
        &msg.header,
        darwin.MACH_RCV_MSG,
        0,
        @sizeOf(MachMsgRcv),
        machport,
        0, // MACH_MSG_TIMEOUT_NONE
        darwin.MACH_PORT_NULL,
    );
    if (status != 0) { // KERN_SUCCESS = 0
        return error.Unexpected;
    }

    // Process the reply — fires libinfoCallback synchronously
    const reply_rc = darwin.getaddrinfo_async_handle_reply(&msg.header);
    if (reply_rc != 0) {
        if (ctx.result) |r| os_net.freeaddrinfo(r);
        return error.Unexpected;
    }

    if (ctx.status != 0) {
        if (ctx.result) |r| os_net.freeaddrinfo(r);
        return eaiToLookupError(ctx.status);
    }

    return .{
        .head = ctx.result,
        .current = ctx.result,
        .return_canonical_name = options.canonical_name,
    };
}

fn eaiToLookupError(status: i32) dns.LookupError {
    const err: std.c.EAI = @enumFromInt(status);
    return switch (err) {
        .ADDRFAMILY => error.AddressFamilyNotSupported,
        .AGAIN => error.TemporaryNameServerFailure,
        .FAIL => error.NameServerFailure,
        .FAMILY => error.AddressFamilyNotSupported,
        .MEMORY => error.OutOfMemory,
        .NODATA => error.HostLacksNetworkAddresses,
        .NONAME => error.UnknownHostName,
        .SERVICE => error.ServiceUnavailable,
        .SYSTEM => error.SystemResources,
        else => error.Unexpected,
    };
}
