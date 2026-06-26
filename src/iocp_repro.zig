//! DEBUG (iocp-debug branch only): standalone, runtime-free reproducer for
//! lalinsky/zio#530 — does a single AcceptEx deliver two completion packets?
//!
//! Strips away ALL of zio's machinery (fibers, race-groups, timers, the loop):
//! just raw Winsock + one shared IOCP port + N poller threads, doing serial
//! accepts. Each accept uses a UNIQUE heap OVERLAPPED that is never freed during
//! the run, so a generation stamped into it is reliable (no reuse race) and a
//! stray second completion lands on valid memory and is counted, not a UAF.
//!
//! It toggles the one suspected variable — whether/when the accepted socket is
//! associated with the completion port — and reports completions-per-generation
//! for each variant. If any generation completes more than once, the duplicate
//! is reproduced with that variable, zio-free. Do not merge.

const std = @import("std");
const builtin = @import("builtin");

test "iocp repro: AcceptEx double-completion (#530)" {
    // Comptime-pruned on non-Windows so the Windows-only code below is never
    // analyzed for other targets / the user's linux `zig build test`.
    if (builtin.os.tag == .windows) {
        try impl.run();
    } else {
        return error.SkipZigTest;
    }
}

const impl = struct {
    const windows = @import("os/windows.zig");
    const net = @import("os/net.zig");
    const IpAddress = @import("net.zig").IpAddress;

    const WSAID_ACCEPTEX = windows.GUID{
        .Data1 = 0xb5367df1,
        .Data2 = 0xcbac,
        .Data3 = 0x11cf,
        .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
    };

    const LPFN_ACCEPTEX = *const fn (
        sListenSocket: windows.SOCKET,
        sAcceptSocket: windows.SOCKET,
        lpOutputBuffer: *anyopaque,
        dwReceiveDataLength: windows.DWORD,
        dwLocalAddressLength: windows.DWORD,
        dwRemoteAddressLength: windows.DWORD,
        lpdwBytesReceived: *windows.DWORD,
        lpOverlapped: *windows.OVERLAPPED,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn Sleep(dwMilliseconds: windows.DWORD) callconv(.winapi) void;

    const addr_slot = @sizeOf(windows.sockaddr.storage) + 16;

    const AcceptCtx = struct {
        overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
        gen: u64 = 0,
        accept_sock: windows.SOCKET = undefined,
        buf: [addr_slot * 2]u8 = undefined,
    };

    const Assoc = enum { none, before, after };

    const State = struct {
        iocp: windows.HANDLE,
        completions: []std.atomic.Value(u32), // indexed by gen
        stop: std.atomic.Value(bool) = .init(false),
        assoc: Assoc,
    };

    fn toHandle(s: windows.SOCKET) windows.HANDLE {
        return @ptrCast(s);
    }

    fn poller(st: *State) void {
        var entries: [16]windows.OVERLAPPED_ENTRY = undefined;
        while (!st.stop.load(.acquire)) {
            var removed: windows.ULONG = 0;
            const ok = windows.GetQueuedCompletionStatusEx(st.iocp, &entries, entries.len, &removed, 50, windows.FALSE);
            if (ok == windows.FALSE) continue; // timeout / no entries
            for (entries[0..removed]) |e| {
                const ovl = e.lpOverlapped orelse continue;
                const ctx: *AcceptCtx = @alignCast(@fieldParentPtr("overlapped", ovl));
                if (st.assoc == .after) {
                    _ = windows.CreateIoCompletionPort(toHandle(ctx.accept_sock), st.iocp, 0, 0);
                }
                if (ctx.gen < st.completions.len) {
                    _ = st.completions[ctx.gen].fetchAdd(1, .monotonic);
                }
            }
        }
    }

    const Result = struct { accepts: u64, total: u64, max: u32, dup_gens: u64 };

    fn runVariant(alloc: std.mem.Allocator, assoc: Assoc, n_accepts: u64, n_pollers: usize) !Result {
        const iocp = windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, null, 0, 0) orelse return error.Unexpected;
        defer _ = windows.CloseHandle(iocp);

        // Listening socket.
        const listener = try net.socket(.ipv4, .stream, .ip, .{ .nonblocking = false });
        defer net.close(listener);
        var bind_addr = IpAddress.initIp4(.{ 127, 0, 0, 1 }, 0);
        try net.bind(listener, &bind_addr.any, @sizeOf(windows.sockaddr.in));
        try net.listen(listener, 128);
        // Read back the assigned port.
        var sa: windows.sockaddr = undefined;
        var salen: i32 = @sizeOf(windows.sockaddr);
        if (windows.getsockname(listener, &sa, &salen) != 0) return error.Unexpected;
        const got = IpAddress.initPosix(@ptrCast(&sa), @intCast(salen));
        const port = std.mem.bigToNative(u16, got.in.port);
        _ = windows.CreateIoCompletionPort(toHandle(listener), iocp, 0, 0) orelse return error.Unexpected;

        const acceptex = try loadAcceptEx(listener);

        const completions = try alloc.alloc(std.atomic.Value(u32), n_accepts + 2);
        defer alloc.free(completions);
        for (completions) |*c| c.* = .init(0);

        var st = State{ .iocp = iocp, .completions = completions, .assoc = assoc };

        const pollers = try alloc.alloc(std.Thread, n_pollers);
        defer alloc.free(pollers);
        for (pollers) |*t| t.* = try std.Thread.spawn(.{}, poller, .{&st});

        const connect_addr = IpAddress.initIp4(.{ 127, 0, 0, 1 }, port);

        var gen: u64 = 1;
        while (gen <= n_accepts) : (gen += 1) {
            const ctx = try alloc.create(AcceptCtx); // intentionally never freed during run
            ctx.* = .{ .gen = gen };
            ctx.accept_sock = try net.socket(.ipv4, .stream, .ip, .{ .nonblocking = false });

            if (assoc == .before) {
                _ = windows.CreateIoCompletionPort(toHandle(ctx.accept_sock), iocp, 0, 0);
            }

            var bytes: windows.DWORD = 0;
            const r = acceptex(listener, ctx.accept_sock, &ctx.buf, 0, addr_slot, addr_slot, &bytes, &ctx.overlapped);
            if (r == windows.FALSE and windows.WSAGetLastError() != .IO_PENDING) return error.Unexpected;

            // Trigger the accept by connecting a client.
            const client = try net.socket(.ipv4, .stream, .ip, .{ .nonblocking = false });
            try net.connect(client, &connect_addr.any, @sizeOf(windows.sockaddr.in));

            // Wait for this generation's first completion (bounded).
            var spins: u32 = 0;
            while (st.completions[gen].load(.monotonic) == 0 and spins < 4000) : (spins += 1) {
                Sleep(1);
            }
            net.close(client);
            // Brief window for a possible duplicate completion to arrive.
            Sleep(2);
        }

        // Let any stragglers land.
        Sleep(400);
        st.stop.store(true, .release);
        for (pollers) |t| t.join();

        var total: u64 = 0;
        var max: u32 = 0;
        var dups: u64 = 0;
        var g: u64 = 1;
        while (g <= n_accepts) : (g += 1) {
            const c = completions[g].load(.monotonic);
            total += c;
            if (c > max) max = c;
            if (c > 1) dups += 1;
        }
        return .{ .accepts = n_accepts, .total = total, .max = max, .dup_gens = dups };
    }

    fn loadAcceptEx(sock: windows.SOCKET) !LPFN_ACCEPTEX {
        var func_ptr: LPFN_ACCEPTEX = undefined;
        var bytes: windows.DWORD = 0;
        const rc = windows.WSAIoctl(
            sock,
            windows.SIO_GET_EXTENSION_FUNCTION_POINTER,
            @constCast(&WSAID_ACCEPTEX),
            @sizeOf(windows.GUID),
            @ptrCast(&func_ptr),
            @sizeOf(LPFN_ACCEPTEX),
            &bytes,
            null,
            null,
        );
        if (rc != 0) return error.Unexpected;
        return func_ptr;
    }

    fn run() !void {
        net.ensureWSAInitialized(); // the runtime normally does this; we run runtime-free
        const alloc = std.heap.page_allocator;
        const n: u64 = 1000;
        const variants = [_]struct { name: []const u8, assoc: Assoc }{
            .{ .name = "assoc_none  ", .assoc = .none },
            .{ .name = "assoc_before", .assoc = .before },
            .{ .name = "assoc_after ", .assoc = .after },
        };
        for (variants) |v| {
            const res = try runVariant(alloc, v.assoc, n, 3);
            std.debug.print(
                "REPRO #530 variant={s} accepts={d} total_completions={d} max_per_gen={d} DUP_GENS={d}\n",
                .{ v.name, res.accepts, res.total, res.max, res.dup_gens },
            );
        }
    }
};
