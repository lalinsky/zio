// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Smoke test for stderr locking through `debug_io`, run by `check.sh --full`.
//! Logs a tagged line from every context the stderr lock classifies that user
//! code can reach -- tasks, a foreign thread, a pool worker -- plus a task
//! holding the lock across a suspension while another task waits for it. With
//! `--panic` it instead panics while holding the stderr lock on a task stack,
//! and the check script asserts the panic message still made it out (the crash
//! handler takes over the mounted task's lock).
//!
//! Presence of a tag only proves the call returned, so the one property worth
//! asserting is checked in-process instead: a task waiting on a lock the holder
//! owns across a suspension must not proceed until the holder releases it. That
//! is what emits `smoke: order ok`, and the check script requires it.
//!
//! The remaining classification -- a no-suspend caller diverting to the
//! scheduler sink rather than waiting for a task holder -- cannot be set up from
//! user code, since `beginNoSuspend` is deliberately not exported. It is covered
//! by the unit tests in `src/stderr.zig`.

const std = @import("std");
const zio = @import("zio");

pub const std_options: std.Options = .{ .log_level = .info };
pub const std_options_debug_io = zio.debug_io;

fn taskLog(id: usize) void {
    std.log.info("smoke: task {d}", .{id});
}

fn poolWorker() void {
    std.log.info("smoke: pool worker", .{});
}

/// Coordination between the holder and the task that waits for it. `released`
/// is what makes the wait observable: the waiter checks it after its own log
/// call returns, so an implementation that let the waiter through early fails
/// rather than producing the same output.
const Contend = struct {
    has_lock: zio.Event = .init,
    released: std.atomic.Value(bool) = .init(false),
};

/// Holds the user stderr lock across a suspension: the case the lock exists
/// for. A task waiting for it must park until this releases.
fn holder(c: *Contend) !void {
    var buf: [128]u8 = undefined;
    const ls = std.debug.lockStderr(&buf);
    try ls.file_writer.interface.print("smoke: holder before sleep\n", .{});
    c.has_lock.set();
    try zio.sleep(.fromMilliseconds(100));
    try ls.file_writer.interface.print("smoke: holder after sleep\n", .{});
    // Ordered before the unlock, so a waiter that was genuinely blocked always
    // observes it as true once it gets through.
    c.released.store(true, .release);
    std.debug.unlockStderr();
}

/// Logs while the holder owns the user lock: must park until it is released.
fn parkedLogger(c: *Contend) !void {
    try c.has_lock.wait();
    std.log.info("smoke: waited for user lock", .{});
    if (!c.released.load(.acquire)) {
        std.log.err("smoke: logged while the holder still owned the lock", .{});
        return error.LockNotHonored;
    }
    std.log.info("smoke: order ok", .{});
}

fn foreignThread() void {
    std.log.info("smoke: foreign thread", .{});
}

fn panicker() !void {
    var buf: [128]u8 = undefined;
    const ls = std.debug.lockStderr(&buf);
    try ls.file_writer.interface.print("smoke: panicking while holding stderr\n", .{});
    // Deliberately still holding the lock: the crash handler must take it
    // over to print the panic message.
    @panic("stderr smoke panic");
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const panic_mode = args.len > 1 and std.mem.eql(u8, args[1], "--panic");

    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(2) });
    defer rt.deinit();

    if (panic_mode) {
        var p = try rt.spawn(panicker, .{});
        try p.join();
        return;
    }

    std.log.info("smoke: main task", .{});

    var tasks: [4]zio.JoinHandle(void) = undefined;
    for (&tasks, 0..) |*t, i| t.* = try rt.spawn(taskLog, .{i});
    for (&tasks) |*t| t.join();

    const thread = try std.Thread.spawn(.{}, foreignThread, .{});
    thread.join();

    var pw = try rt.spawnBlocking(poolWorker, .{});
    pw.join();

    var contend: Contend = .{};
    var h = try rt.spawn(holder, .{&contend});
    var p = try rt.spawn(parkedLogger, .{&contend});
    try h.join();
    try p.join();

    std.log.info("smoke: done", .{});
}
