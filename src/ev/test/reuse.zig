// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Tests for what a completion's own callback may do with it: add it again,
//! reuse its memory for another operation, or free it.

const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const completion = @import("../completion.zig");
const Completion = completion.Completion;
const Timer = completion.Timer;
const Async = completion.Async;

test "Completion: callback adds its own completion again" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Ctx = struct {
        count: usize = 0,

        fn cb(l: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.count += 1;
            if (self.count < 3) l.add(c);
        }
    };
    var ctx: Ctx = .{};

    var timer: Timer = .init(.{ .duration = .zero });
    timer.c.callback = Ctx.cb;
    timer.c.userdata = &ctx;
    loop.add(&timer.c);
    try loop.run();

    try std.testing.expectEqual(3, ctx.count);
}

test "Completion: callback reuses its memory for another operation" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Slot = union(enum) {
        timer: Timer,
        async: Async,
    };
    const Ctx = struct {
        slot: Slot,
        async_done: bool = false,

        fn timerDone(l: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.slot = .{ .async = .init() };
            self.slot.async.c.callback = asyncDone;
            self.slot.async.c.userdata = self;
            l.add(&self.slot.async.c);
            self.slot.async.notify();
        }

        fn asyncDone(_: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.async_done = true;
        }
    };
    var ctx: Ctx = .{ .slot = .{ .timer = .init(.{ .duration = .zero }) } };
    ctx.slot.timer.c.callback = Ctx.timerDone;
    ctx.slot.timer.c.userdata = &ctx;
    loop.add(&ctx.slot.timer.c);
    try loop.run();

    try std.testing.expect(ctx.async_done);
}

test "Completion: callback frees its own completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Ctx = struct {
        fn cb(_: *Loop, c: *Completion) void {
            std.testing.allocator.destroy(c.cast(Timer));
        }
    };

    const timer = try std.testing.allocator.create(Timer);
    timer.* = .init(.{ .duration = .zero });
    timer.c.callback = Ctx.cb;
    loop.add(&timer.c);
    try loop.run();
}
