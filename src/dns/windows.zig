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

// DEBUG(#460): canary values so a callback firing on a freed/reused context is
// caught (with its backtrace) instead of silently stomping reused memory.
const DBG_MAGIC_LIVE: u64 = 0x460C_0DE0_460C_0DE0;
const DBG_MAGIC_DEAD: u64 = 0x460D_EAD0_460D_EAD0;
// DEBUG(#460): guard word right after the OVERLAPPED to catch a kernel write that
// runs past a standard 32-byte OVERLAPPED into the following field (async_handle).
const DBG_OVERLAPPED_CANARY: u64 = 0x460C_A6A0_460C_A6A0;

/// Heap-allocated, reference-counted context for a loop-delivered async lookup.
const LoopContext = struct {
    // DEBUG(#460): magic first so a stale callback reads it before anything else.
    magic: u64 = DBG_MAGIC_LIVE,
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
    overlapped_canary: u64 = DBG_OVERLAPPED_CANARY,
    async_handle: ev.Async,
    err: u32 = 0,
    refs: std.atomic.Value(u8),
    allocator: std.mem.Allocator,
    // DEBUG(#460): set true once the context is retired; a callback that sees it
    // set (or magic != LIVE) fired after we thought we were done — the exact
    // "unmonitored Windows thread writes freed memory" bug.
    freed: bool = false,
    // DEBUG(#460): set on the synchronous return paths, where we assume the
    // completion callback will NOT fire (Hole A). If it fires anyway, panic.
    must_not_fire: bool = false,

    fn unref(self: *LoopContext) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            // DEBUG(#460): poison + LEAK (c_allocator, so no leak-detector noise)
            // instead of destroy, so a late callback lands on the dead-magic
            // context and panics rather than corrupting reused memory.
            self.freed = true;
            self.magic = DBG_MAGIC_DEAD;
        }
    }
};

fn loopCallback(dwError: u32, _: u32, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) void {
    const ctx: *LoopContext = @fieldParentPtr("overlapped", lpOverlapped.?);
    // DEBUG(#460): a callback on a dead/reused context is the bug we're hunting.
    if (ctx.magic != DBG_MAGIC_LIVE or ctx.freed) {
        std.debug.panic("DEBUG(#460): DNS loopCallback on freed/reused ctx=0x{x} magic=0x{x} freed={} err={}", .{ @intFromPtr(ctx), ctx.magic, ctx.freed, dwError });
    }
    if (ctx.must_not_fire) {
        std.debug.panic("DEBUG(#460): DNS loopCallback fired after a synchronous GetAddrInfoExW return (Hole A) ctx=0x{x} err={}", .{ @intFromPtr(ctx), dwError });
    }
    if (ctx.overlapped_canary != DBG_OVERLAPPED_CANARY) {
        std.debug.panic("DEBUG(#460): GetAddrInfoExW over-wrote past OVERLAPPED (canary=0x{x}) ctx=0x{x}", .{ ctx.overlapped_canary, @intFromPtr(ctx) });
    }
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

    // DEBUG(#460): allocate the callback context with the C allocator so that
    // poison-and-leak on retirement doesn't trip the test leak detector.
    const allocator = std.heap.c_allocator;
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

    // DEBUG(#460): catch a synchronous over-write past the OVERLAPPED.
    if (ctx.overlapped_canary != DBG_OVERLAPPED_CANARY) {
        std.debug.panic("DEBUG(#460): GetAddrInfoExW (sync) over-wrote past OVERLAPPED (canary=0x{x}) rc={}", .{ ctx.overlapped_canary, rc });
    }

    if (rc == 0) {
        // Completed synchronously — we ASSUME no callback will fire, so drop both
        // refs. DEBUG(#460): mark must_not_fire first so a callback that fires
        // anyway (Hole A) panics instead of stomping the reused context.
        ctx.must_not_fire = true;
        ctx.unref();
        ctx.unref();
        return fillBuffers(storage, options, result);
    }
    if (rc != windows.WSA_IO_PENDING) {
        ctx.must_not_fire = true;
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
    // DEBUG(#460): guard between OVERLAPPED and waiter — a kernel over-write past
    // the OVERLAPPED would land here rather than silently signaling the waiter.
    overlapped_canary: u64 = DBG_OVERLAPPED_CANARY,
    waiter: Waiter,
    err: u32 = 0,
};

fn blockingCallback(dwError: u32, _: u32, lpOverlapped: ?*windows.OVERLAPPED) callconv(.winapi) void {
    const ctx: *BlockingContext = @fieldParentPtr("overlapped", lpOverlapped.?);
    if (ctx.overlapped_canary != DBG_OVERLAPPED_CANARY) {
        std.debug.panic("DEBUG(#460): GetAddrInfoExW over-wrote past OVERLAPPED into blocking waiter (canary=0x{x})", .{ctx.overlapped_canary});
    }
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
