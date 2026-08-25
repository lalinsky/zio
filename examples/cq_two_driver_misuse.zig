//! Two tasks selecting over ONE CompletionQueue: the documented misuse
//! (the queue has a single-driver contract). Under the claims protocol the
//! second registration finds the queue's registration slot occupied and
//! panics at the point of misuse, in every optimize mode.
//!
//! This is a death test driven externally: the EXPECTED outcome is an abort
//! with the panic message
//!
//!   CompletionQueue: selected from two tasks; one task must drive the queue
//!
//! A harness accepts only that abort (SIGABRT, or the message). Exit 3
//! means the misuse ran for the full window without a panic: the check
//! failed. Any other exit means the example itself failed to run. (The
//! pre-claims protocol accepted two drivers silently and corrupted the
//! claim accounting instead: each driver could take a valid claim on one
//! completion, and one select later won with nothing to take, surfacing
//! as a `getResult` assert far from the cause.)
//!
//! Run: `zig build examples -Dexample=cq-two-driver-misuse && ./zig-out/bin/cq-two-driver-misuse`
const std = @import("std");
const zio = @import("zio");

fn driver(cq: *zio.CompletionQueue, label: []const u8) !void {
    var served: u64 = 0;
    while (true) {
        const winner = try zio.select(.{ .io = cq });
        const c = winner.io catch break;
        served += 1;
        // Re-arm, as the maintainer's two-driver walk has both drivers do.
        c.cast(zio.ev.Async).getResult() catch {};
        try cq.submit(c);
        if (served % 1000 == 0) std.debug.print("{s}: {d}\n", .{ label, served });
    }
}

fn feeder(mails: []zio.ev.Async, stop: *std.atomic.Value(bool)) !void {
    while (!stop.load(.acquire)) {
        for (mails) |*m| m.notify();
        try zio.yield();
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const rt = try zio.Runtime.init(gpa, .{ .executors = .auto });
    defer rt.deinit();

    var handle = try rt.spawn(struct {
        fn go(runtime: *zio.Runtime) !void {
            var cq = zio.CompletionQueue.init();
            var mails: [4]zio.ev.Async = @splat(zio.ev.Async.init());
            for (&mails) |*m| try cq.submit(&m.c);

            var stop = std.atomic.Value(bool).init(false);
            var feed = try runtime.spawn(feeder, .{ mails[0..], &stop });
            defer {
                stop.store(true, .release);
                feed.join() catch {};
            }

            std.debug.print("expect a panic: two tasks now drive one queue\n", .{});
            var a = try runtime.spawn(driver, .{ &cq, "driver-a" });
            defer a.cancel();
            var b = try runtime.spawn(driver, .{ &cq, "driver-b" });
            defer b.cancel();

            // Give the two drivers ample time to overlap their parks. If we
            // are still alive after this, the misuse went undetected.
            try runtime.sleep(.fromSeconds(5));
        }
    }.go, .{rt});
    try handle.join();

    std.debug.print("MISUSE NOT DETECTED: two drivers ran without a panic\n", .{});
    std.process.exit(3);
}
