// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Windows DNS resolver using GetAddrInfoExW with async completion.
//!
//! GetAddrInfoExW delivers its completion on a Windows thread-pool thread. That
//! thread must NOT signal the waiter directly: the waiting task could observe the
//! signal, return, reclaim its frame and even finish (freeing the task) while the
//! thread-pool thread is still inside signal() — a cross-thread use-after-free,
//! the same class fixed for blockInPlace (see a51830a).
//!
//! Instead the callback only wakes the event loop via an `ev.Async`; the loop
//! thread — which also owns the waiting task — performs the actual waiter signal
//! and task resume, so there is no cross-thread reclaim. The context is heap
//! allocated and reference counted (one ref for `lookup`, one for the pending
//! callback) so it outlives the callback even in the narrow window where the
//! callback still touches `async_handle` after making it completable. `lookup`
//! always waits for the callback (even on cancellation, after asking Windows to
//! cancel the request), which also keeps the loop alive until the callback runs.
//!
//! Without an executor there is no loop to hand off to, so we fall back to a
//! direct blocking wait (the pre-existing no-runtime path).

const std = @import("std");
const windows = @import("../os/windows.zig");
const os_net = @import("../os/net.zig");
const common = @import("../common.zig");
const ev = @import("../ev/root.zig");
const runtime = @import("../runtime.zig");
const Waiter = common.Waiter;
const dns = @import("root.zig");

const ADDRINFOEXW = windows.ADDRINFOEXW;

/// Builds the UTF-16 name/port and hints for GetAddrInfoExW.
const Query = struct {
    name_wide: [256:0]u16 = undefined,
    port_wide: [8:0]u16 = undefined,
    hints: ADDRINFOEXW = undefined,

    fn init(options: dns.LookupOptions) error{UnknownHostName}!Query {
        var q: Query = .{};
        const name_len = std.unicode.utf8ToUtf16Le(&q.name_wide, options.name) catch return error.UnknownHostName;
        q.name_wide[name_len] = 0;

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{options.port}) catch unreachable;
        const port_len = std.unicode.utf8ToUtf16Le(&q.port_wide, port_str) catch unreachable;
        q.port_wide[port_len] = 0;

        q.hints = std.mem.zeroes(ADDRINFOEXW);
        q.hints.ai_family = if (options.family) |f| switch (f) {
            .ipv4 => @as(i32, os_net.AF.INET),
            .ipv6 => @as(i32, os_net.AF.INET6),
        } else @as(i32, os_net.AF.UNSPEC);
        q.hints.ai_socktype = os_net.SOCK.STREAM;
        q.hints.ai_protocol = os_net.IPPROTO.TCP;
        if (options.canonical_name_buffer != null) {
            q.hints.ai_flags = @bitCast(windows.AI{ .CANONNAME = true });
        }
        return q;
    }
};

/// Heap-allocated, reference-counted context for a loop-delivered async lookup.
const LoopContext = struct {
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    async_handle: ev.Async,
    err: u32 = 0,
    refs: std.atomic.Value(u8),
    allocator: std.mem.Allocator,

    fn unref(self: *LoopContext) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.allocator.destroy(self);
        }
    }
};

fn loopCallback(dwError: u32, _: u32, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) void {
    const ctx: *LoopContext = @fieldParentPtr("overlapped", lpOverlapped.?);
    ctx.err = dwError;
    // Hand off to the loop; do NOT touch the waiter/task from this foreign thread.
    // The loop thread performs the waiter signal + task resume.
    ctx.async_handle.notify();
    // Release the callback's reference last, after all context access is done.
    ctx.unref();
}

pub fn lookup(
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
) dns.LookupError!usize {
    os_net.ensureWSAInitialized();
    if (runtime.getCurrentExecutorOrNull()) |exec| {
        return lookupOnLoop(exec, storage, options);
    }
    return lookupBlocking(storage, options);
}

fn lookupOnLoop(
    exec: *runtime.Executor,
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
) dns.LookupError!usize {
    var query = try Query.init(options);

    const allocator = exec.runtime.allocator;
    const ctx = allocator.create(LoopContext) catch return error.OutOfMemory;
    // Two references: one for us, one for the pending completion callback. If the
    // call completes synchronously (or fails), no callback fires and we drop both.
    ctx.* = .{
        .async_handle = ev.Async.init(),
        .refs = std.atomic.Value(u8).init(2),
        .allocator = allocator,
    };

    var result: ?*ADDRINFOEXW = null;
    var cancel_handle: windows.HANDLE = undefined;

    const rc = windows.GetAddrInfoExW(
        @ptrCast(&query.name_wide),
        @ptrCast(&query.port_wide),
        windows.NS_DNS,
        null,
        &query.hints,
        &result,
        null,
        &ctx.overlapped,
        loopCallback,
        &cancel_handle,
    );

    if (rc == 0) {
        // Completed synchronously — no callback will fire, so drop both refs.
        ctx.unref();
        ctx.unref();
        return fillBuffers(storage, options, result);
    }
    if (rc != windows.WSA_IO_PENDING) {
        ctx.unref();
        ctx.unref();
        return winsockToLookupError(rc);
    }

    // Async path: the callback owns one ref and will fire exactly once. Submit the
    // async to the loop and wait for the loop to deliver the completion. Query
    // buffers live on this stack and must stay valid until the callback fires, so
    // we always wait for it — on cancellation we ask Windows to cancel, then still
    // wait for the guaranteed callback.
    var waiter = Waiter.init();
    ctx.async_handle.c.userdata = &waiter;
    ctx.async_handle.c.callback = Waiter.callback;
    exec.loop.add(&ctx.async_handle.c);

    var canceled = false;
    waiter.wait(1, .allow_cancel) catch {
        canceled = true;
        _ = windows.GetAddrInfoExCancel(&cancel_handle);
        waiter.wait(1, .no_cancel);
    };

    const err = ctx.err;
    ctx.unref();

    if (canceled) {
        if (result) |r| windows.FreeAddrInfoExW(r);
        return error.Canceled;
    }
    if (err != 0) {
        if (result) |r| windows.FreeAddrInfoExW(r);
        return winsockToLookupError(@intCast(err));
    }
    return fillBuffers(storage, options, result);
}

/// No-executor fallback: block the calling thread on the completion. There is no
/// event loop to hand off to here, so the callback signals the waiter directly.
/// This path is only reached outside any runtime, where the frame cannot be
/// reclaimed by another task mid-signal.
const BlockingContext = struct {
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    waiter: Waiter,
    err: u32 = 0,
};

fn blockingCallback(dwError: u32, _: u32, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) void {
    const ctx: *BlockingContext = @fieldParentPtr("overlapped", lpOverlapped.?);
    ctx.err = dwError;
    ctx.waiter.signal();
}

fn lookupBlocking(
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
) dns.LookupError!usize {
    var query = try Query.init(options);

    var result: ?*ADDRINFOEXW = null;
    var ctx: BlockingContext = .{ .waiter = .init() };
    var cancel_handle: windows.HANDLE = undefined;

    const rc = windows.GetAddrInfoExW(
        @ptrCast(&query.name_wide),
        @ptrCast(&query.port_wide),
        windows.NS_DNS,
        null,
        &query.hints,
        &result,
        null,
        &ctx.overlapped,
        blockingCallback,
        &cancel_handle,
    );

    if (rc == 0) return fillBuffers(storage, options, result);
    if (rc != windows.WSA_IO_PENDING) return winsockToLookupError(rc);

    ctx.waiter.wait(1, .allow_cancel) catch {
        _ = windows.GetAddrInfoExCancel(&cancel_handle);
        ctx.waiter.wait(1, .no_cancel);
        if (result) |r| windows.FreeAddrInfoExW(r);
        return error.Canceled;
    };

    if (ctx.err != 0) {
        if (result) |r| windows.FreeAddrInfoExW(r);
        return winsockToLookupError(@intCast(ctx.err));
    }
    return fillBuffers(storage, options, result);
}

fn fillBuffers(
    storage: []dns.LookupResult,
    options: dns.LookupOptions,
    head: ?*ADDRINFOEXW,
) dns.LookupError!usize {
    defer if (head) |h| windows.FreeAddrInfoExW(h);

    var i: usize = 0;

    if (options.canonical_name_buffer) |cname_buf| {
        if (head) |h| {
            if (h.ai_canonname) |name_ptr| {
                if (i >= storage.len) return i;
                const name_slice = std.mem.sliceTo(name_ptr, 0);
                const len = std.unicode.utf16LeToUtf8(cname_buf, name_slice) catch return error.UnknownHostName;
                cname_buf[len] = 0;
                storage[i] = .{ .canonical_name = .{ .bytes = cname_buf[0..len] } };
                i += 1;
            }
        }
    }

    var current: ?*ADDRINFOEXW = head;
    while (current) |info| : (current = info.ai_next) {
        const addr = info.ai_addr orelse continue;
        if (addr.family != os_net.AF.INET and addr.family != os_net.AF.INET6) continue;
        if (i >= storage.len) return error.TooManyAddresses;
        storage[i] = .{ .address = dns.IpAddress.initPosix(@ptrCast(addr), @intCast(info.ai_addrlen)) };
        i += 1;
    }

    return i;
}

fn winsockToLookupError(err: i32) dns.LookupError {
    const wsa_err: windows.WinsockError = @enumFromInt(@as(u16, @intCast(err)));
    return switch (wsa_err) {
        .EAFNOSUPPORT => error.AddressFamilyUnsupported,
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
