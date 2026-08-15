// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Smoke test for stderr locking through `debug_io`, run by `check.sh --full`.
//! Logs a tagged line from every context the stderr lock classifies -- tasks,
//! a foreign thread, a pool worker, a no-suspend region, and a no-suspend
//! divert while a task holds the user lock across a suspension. The check
//! script asserts every tag came out; ordering between the two sinks is
//! unspecified by design and deliberately not checked. With `--panic` it
//! instead panics while holding the stderr lock on a task stack, and the
//! check script asserts the panic message still made it out (the crash
//! handler takes over the mounted task's lock).

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

/// Holds the user stderr lock across a suspension: the case the lock exists
/// for. Waiting tasks must park; no-suspend callers must divert.
fn holder() !void {
    var buf: [128]u8 = undefined;
    const ls = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    try ls.file_writer.interface.print("smoke: holder before sleep\n", .{});
    try zio.sleep(.fromMilliseconds(100));
    try ls.file_writer.interface.print("smoke: holder after sleep\n", .{});
}

/// Logs from a no-suspend region while the holder task owns the user lock:
/// must divert to the scheduler sink instead of waiting.
fn divertLogger() !void {
    try zio.sleep(.fromMilliseconds(30));
    zio.beginNoSuspend();
    defer zio.endNoSuspend();
    std.log.info("smoke: no-suspend divert", .{});
}

/// Logs normally while the holder task owns the user lock: must park until
/// the holder releases.
fn parkedLogger() !void {
    try zio.sleep(.fromMilliseconds(30));
    std.log.info("smoke: waited for user lock", .{});
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

    var h = try rt.spawn(holder, .{});
    var d = try rt.spawn(divertLogger, .{});
    var p = try rt.spawn(parkedLogger, .{});
    try h.join();
    try d.join();
    try p.join();

    std.log.info("smoke: done", .{});
}
