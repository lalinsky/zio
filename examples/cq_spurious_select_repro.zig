//! Reproducer for a select CompletionQueue arm winning with the queue EMPTY
//! and OPEN: `getResult` hits `std.debug.assert(drained)` (Debug and
//! ReleaseSafe abort with a stack through completion_queue.zig getResult and
//! select.zig:465), or returns `error.Closed` for an open queue in
//! ReleaseFast.
//!
//! Single-driver by construction: each queue is owned by exactly ONE task,
//! which consumes it through the select arm and through `next()` pops
//! between selects, strictly sequentially, and tears it down with
//! `close(); cancelAll(.keep);` drain.
//!
//! The route (all in one driver task): `ownerCallback` is publish-then-wake
//! and the two halves are not atomic. In the window between the `completed`
//! push (mutex unlocked) and the `Futex.wake`, the driver's channel arm wins
//! a select, the CQ arm's `cancelWait` succeeds (the wake has not dequeued
//! anything yet, so no in-flight signal is counted — correctly), the driver
//! pops the published item via `next()` and resubmits, and the NEXT select
//! registers a fresh waiter on the same signal word. The old wake then
//! fires, dequeues the new waiter, and claims the new select's CQ arm with
//! nothing to take.
//!
//! Run: `zig build examples -Dexample=cq-spurious-select-repro && ./zig-out/bin/cq-spurious-select-repro`
//! Args: [workers] [generations] [selects_per_gen], default 8 20000 64.
//! Reproduces within ~1 s on macOS/kqueue and Linux/io_uring, Debug and
//! ReleaseSafe, with 8 workers; 1-2 workers run clean (the window needs
//! runtime-wide concurrency; each queue still has exactly one driver).
//! On plain main the `getResult` assert aborts (exit 134). On this branch,
//! where the assert is replaced by a tolerant `error.Closed`, the repro
//! detects the spurious win itself: a SPURIOUS line and exit 2.
//! Exit 0 = no reproduction within the budget.
const std = @import("std");
const zio = @import("zio");

const Shared = struct {
    ch: *zio.Channel(u64),
    stop: std.atomic.Value(bool) = .init(false),
    /// The write end of the driver's current socketpair, -1 between
    /// generations. The flooder feeds it so recv completions keep coming
    /// from the backend's harvest path. Guarded by `feed_mu`, together
    /// with the close of the descriptor: an atomic value alone does not
    /// protect the descriptor lifetime, and a write racing the close
    /// could land on a reused descriptor number.
    feed_mu: zio.Mutex = .init,
    feed_fd: std.c.fd_t = -1,
};

fn flooder(sh: *Shared) !void {
    // Keep the channel arm ready most of the time, and keep the driver's
    // socket fed; yield so the driver runs.
    while (!sh.stop.load(.acquire)) {
        sh.ch.trySend(1) catch {};
        {
            try sh.feed_mu.lock();
            defer sh.feed_mu.unlock();
            if (sh.feed_fd >= 0) _ = std.c.write(sh.feed_fd, "y", 1);
        }
        try zio.yield();
    }
}

fn driver(sh: *Shared, generations: u64, selects_per_gen: u64, spurious: *std.atomic.Value(u64)) !void {
    var g: u64 = 0;
    while (g < generations) : (g += 1) {
        // A fresh queue, ops, and socketpair every generation, on this
        // coroutine's stack: the addresses recycle, as they do for a
        // connection struct. The recv op makes the completion source the
        // backend's own CQE harvest, as a server's socket recv is.
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
        // Darwin's socketpair takes no NONBLOCK flag; set it portably.
        for (fds) |fd| {
            const fl = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, 1 << @bitOffsetOf(std.c.O, "NONBLOCK")));
        }
        // Prime some bytes so recv completes quickly, and keep feeding.
        _ = std.c.write(fds[1], "xxxxxxxx", 8);
        {
            try sh.feed_mu.lock();
            defer sh.feed_mu.unlock();
            sh.feed_fd = fds[1];
        }
        // Clear and close under one mutex hold, so the flooder can never
        // write to a closed (and possibly reused) descriptor. Runs after
        // the queue teardown below: the operations reference these fds.
        defer {
            sh.feed_mu.lockUncancelable();
            defer sh.feed_mu.unlock();
            sh.feed_fd = -1;
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }

        var cq = zio.CompletionQueue.init();
        // Error paths (the SPURIOUS detection included) must not unwind past
        // live operations: their callbacks would touch this dead frame. The
        // normal path runs the explicit teardown at the end of the
        // generation instead, so this fires only on early returns.
        errdefer {
            cq.close();
            cq.cancelAll(.keep);
            while (cq.next()) |_| {}
        }
        var recv_buf: [64]u8 = undefined;
        var iov: [1]std.c.iovec = undefined;
        var recv_op = zio.ev.NetRecv.init(fds[0], zio.ev.ReadBuf.fromSlice(&recv_buf, &iov), .{});
        try cq.submit(&recv_op.c);
        var t1 = zio.ev.Timer.init(.{ .duration = .fromMicroseconds(50) });
        try cq.submit(&t1.c);
        var closed_by_us = false;

        var s: u64 = 0;
        while (s < selects_per_gen) : (s += 1) {
            const winner = try zio.select(.{
                .io = &cq,
                .msg = sh.ch.asyncReceive(),
            });
            switch (winner) {
                .io => |r| {
                    const c = r catch |err| {
                        if (err == error.Closed and !closed_by_us) {
                            _ = spurious.fetchAdd(1, .monotonic);
                            std.debug.print("SPURIOUS error.Closed on an open queue (gen={d} select={d})\n", .{ g, s });
                            return error.Spurious;
                        }
                        return err;
                    };
                    // Re-arm whichever op completed, as a server re-arms its
                    // recv. getResult inside select already popped it.
                    if (c == &recv_op.c) {
                        recv_op = zio.ev.NetRecv.init(fds[0], zio.ev.ReadBuf.fromSlice(&recv_buf, &iov), .{});
                        try cq.submit(&recv_op.c);
                    } else if (c == &t1.c) {
                        t1 = zio.ev.Timer.init(.{ .duration = .fromMicroseconds(50) });
                        try cq.submit(&t1.c);
                    }
                },
                .msg => |r| {
                    _ = r catch {};
                    // The second consumption path: a non-blocking pop between
                    // selects, exactly like a driver's poll turn.
                    while (cq.next()) |c| {
                        if (c == &recv_op.c) {
                            recv_op = zio.ev.NetRecv.init(fds[0], zio.ev.ReadBuf.fromSlice(&recv_buf, &iov), .{});
                            try cq.submit(&recv_op.c);
                        } else if (c == &t1.c) {
                            t1 = zio.ev.Timer.init(.{ .duration = .fromMicroseconds(50) });
                            try cq.submit(&t1.c);
                        }
                    }
                },
            }
        }

        // Teardown, as a connection does it: close, cancel with results
        // kept, drain.
        closed_by_us = true;
        cq.close();
        cq.cancelAll(.keep);
        while (cq.next()) |_| {}
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var workers: u32 = 8;
    var generations: u64 = 20000;
    var selects_per_gen: u64 = 64;
    if (args.next()) |a| workers = try std.fmt.parseInt(u32, a, 10);
    if (args.next()) |a| generations = try std.fmt.parseInt(u64, a, 10);
    if (args.next()) |a| selects_per_gen = try std.fmt.parseInt(u64, a, 10);

    const rt = try zio.Runtime.init(gpa, .{ .executors = .auto });
    defer rt.deinit();

    var handle = try rt.spawn(struct {
        fn go(runtime: *zio.Runtime, alloc: std.mem.Allocator, n_workers: u32, gens: u64, spg: u64) !void {
            var spurious: std.atomic.Value(u64) = .init(0);
            const bufs = try alloc.alloc([4]u64, n_workers);
            defer alloc.free(bufs);
            const chans = try alloc.alloc(zio.Channel(u64), n_workers);
            defer alloc.free(chans);
            const shs = try alloc.alloc(Shared, n_workers);
            defer alloc.free(shs);
            var drivers = try alloc.alloc(zio.JoinHandle(@typeInfo(@TypeOf(driver)).@"fn".return_type.?), n_workers);
            defer alloc.free(drivers);
            var flooders = try alloc.alloc(zio.JoinHandle(@typeInfo(@TypeOf(flooder)).@"fn".return_type.?), n_workers);
            defer alloc.free(flooders);

            var i: u32 = 0;
            while (i < n_workers) : (i += 1) {
                chans[i] = zio.Channel(u64).init(&bufs[i]);
                shs[i] = .{ .ch = &chans[i] };
                flooders[i] = try runtime.spawn(flooder, .{&shs[i]});
                drivers[i] = try runtime.spawn(driver, .{ &shs[i], gens, spg, &spurious });
            }
            var failed = false;
            i = 0;
            while (i < n_workers) : (i += 1) {
                drivers[i].join() catch {
                    failed = true;
                };
                shs[i].stop.store(true, .release);
                flooders[i].join() catch {};
            }
            const n = spurious.load(.acquire);
            if (failed or n > 0) {
                std.debug.print("RESULT spurious={d}\n", .{n});
                std.process.exit(2);
            }
            std.debug.print("clean: {d} workers x {d} generations x {d} selects\n", .{ n_workers, gens, spg });
        }
    }.go, .{ rt, gpa, workers, generations, selects_per_gen });
    try handle.join();
}
