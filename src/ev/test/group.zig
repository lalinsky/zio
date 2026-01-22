const std = @import("std");
const ev = @import("../root.zig");
const Loop = ev.Loop;
const Timer = ev.Timer;
const Async = ev.Async;
const Group = ev.Group;
const Completion = ev.Completion;

test "group: empty group completes immediately" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var group: Group = .init(.gather);
    loop.add(&group.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, group.c.state);
    try group.getResult();
}

test "group: single completion" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var group: Group = .init(.gather);

    group.add(&timer.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectEqual(.dead, group.c.state);
    try timer.getResult();
    try group.getResult();
}

test "group: multiple completions" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var timer2: Timer = .init(.{ .duration = .fromMilliseconds(20) });
    var timer3: Timer = .init(.{ .duration = .fromMilliseconds(30) });
    var group: Group = .init(.gather);

    group.add(&timer1.c);
    group.add(&timer2.c);
    group.add(&timer3.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, timer1.c.state);
    try std.testing.expectEqual(.dead, timer2.c.state);
    try std.testing.expectEqual(.dead, timer3.c.state);
    try std.testing.expectEqual(.dead, group.c.state);

    try timer1.getResult();
    try timer2.getResult();
    try timer3.getResult();
    try group.getResult();
}

test "group: callback invoked when all complete" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Ctx = struct {
        group_callback_order: usize = 0,
        timer1_callback_order: usize = 0,
        timer2_callback_order: usize = 0,
        order: usize = 0,

        fn groupCallback(_: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.order += 1;
            self.group_callback_order = self.order;
        }

        fn timer1Callback(_: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.order += 1;
            self.timer1_callback_order = self.order;
        }

        fn timer2Callback(_: *Loop, c: *Completion) void {
            const self: *@This() = @ptrCast(@alignCast(c.userdata.?));
            self.order += 1;
            self.timer2_callback_order = self.order;
        }
    };

    var ctx: Ctx = .{};

    var timer1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    timer1.c.userdata = &ctx;
    timer1.c.callback = Ctx.timer1Callback;

    var timer2: Timer = .init(.{ .duration = .fromMilliseconds(20) });
    timer2.c.userdata = &ctx;
    timer2.c.callback = Ctx.timer2Callback;

    var group: Group = .init(.gather);
    group.c.userdata = &ctx;
    group.c.callback = Ctx.groupCallback;

    group.add(&timer1.c);
    group.add(&timer2.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    // Group callback should be called after both timer callbacks
    try std.testing.expect(ctx.group_callback_order > ctx.timer1_callback_order);
    try std.testing.expect(ctx.group_callback_order > ctx.timer2_callback_order);
}

test "group: cancel cancels all children" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var timer2: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var timer3: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var group: Group = .init(.gather);

    group.add(&timer1.c);
    group.add(&timer2.c);
    group.add(&timer3.c);
    loop.add(&group.c);

    // Cancel the group
    loop.cancel(&group.c);

    try loop.run(.until_done);

    // All children should be canceled
    try std.testing.expectError(error.Canceled, timer1.getResult());
    try std.testing.expectError(error.Canceled, timer2.getResult());
    try std.testing.expectError(error.Canceled, timer3.getResult());

    // Group should also be canceled
    try std.testing.expectError(error.Canceled, group.getResult());
}

test "group: child error does not affect group result" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var timer2: Timer = .init(.{ .duration = .fromMilliseconds(1000) }); // Will be canceled
    var group: Group = .init(.gather);

    group.add(&timer1.c);
    group.add(&timer2.c);
    loop.add(&group.c);

    // Cancel just timer2, not the group
    loop.cancel(&timer2.c);

    try loop.run(.until_done);

    // timer1 should succeed
    try timer1.getResult();

    // timer2 should be canceled
    try std.testing.expectError(error.Canceled, timer2.getResult());

    // Group should succeed (user is responsible for checking children)
    try group.getResult();
}

test "group: mixed completion types" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var async_handle: Async = .init();
    var group: Group = .init(.gather);

    group.add(&timer.c);
    group.add(&async_handle.c);
    loop.add(&group.c);

    // Notify async immediately
    async_handle.notify();

    try loop.run(.until_done);

    try std.testing.expectEqual(.dead, timer.c.state);
    try std.testing.expectEqual(.dead, async_handle.c.state);
    try std.testing.expectEqual(.dead, group.c.state);

    try timer.getResult();
    try async_handle.getResult();
    try group.getResult();
}

test "group: race mode first completer wins" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var fast_timer: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var slow_timer: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var group: Group = .init(.race);

    group.add(&fast_timer.c);
    group.add(&slow_timer.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    // Fast timer should complete successfully
    try fast_timer.getResult();

    // Slow timer should be canceled
    try std.testing.expectError(error.Canceled, slow_timer.getResult());

    // Group should succeed (first completer won)
    try group.getResult();
}

test "group: race mode cancels siblings" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var timer2: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var timer3: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var group: Group = .init(.race);

    group.add(&timer1.c);
    group.add(&timer2.c);
    group.add(&timer3.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    // timer1 should complete successfully (it fires first)
    try timer1.getResult();

    // timer2 and timer3 should be canceled
    try std.testing.expectError(error.Canceled, timer2.getResult());
    try std.testing.expectError(error.Canceled, timer3.getResult());

    // Group should succeed
    try group.getResult();
}

test "group: race mode with single child" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var timer: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var group: Group = .init(.race);

    group.add(&timer.c);
    loop.add(&group.c);

    try loop.run(.until_done);

    // Timer should complete successfully
    try timer.getResult();

    // Group should succeed
    try group.getResult();
}

test "group: nested gather inside race (timeout pattern) - ops complete first" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Timeout timer (slow)
    var timeout: Timer = .init(.{ .duration = .fromMilliseconds(1000) });

    // Operations (fast)
    var op1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var op2: Timer = .init(.{ .duration = .fromMilliseconds(20) });

    // Inner gather group for operations
    var ops: Group = .init(.gather);
    ops.add(&op1.c);
    ops.add(&op2.c);

    // Outer race group: timeout vs operations
    var race: Group = .init(.race);
    race.add(&timeout.c);
    race.add(&ops.c);

    loop.add(&race.c);
    try loop.run(.until_done);

    // Operations should complete successfully
    try op1.getResult();
    try op2.getResult();
    try ops.getResult();

    // Timeout should be canceled (operations won the race)
    try std.testing.expectError(error.Canceled, timeout.getResult());

    // Outer race should succeed
    try race.getResult();
}

test "group: nested gather inside race (timeout pattern) - timeout fires first" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Timeout timer (fast)
    var timeout: Timer = .init(.{ .duration = .fromMilliseconds(10) });

    // Operations (slow)
    var op1: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var op2: Timer = .init(.{ .duration = .fromMilliseconds(1000) });

    // Inner gather group for operations
    var ops: Group = .init(.gather);
    ops.add(&op1.c);
    ops.add(&op2.c);

    // Outer race group: timeout vs operations
    var race: Group = .init(.race);
    race.add(&timeout.c);
    race.add(&ops.c);

    loop.add(&race.c);
    try loop.run(.until_done);

    // Timeout should complete successfully (it won the race)
    try timeout.getResult();

    // Operations should be canceled
    try std.testing.expectError(error.Canceled, op1.getResult());
    try std.testing.expectError(error.Canceled, op2.getResult());
    try std.testing.expectError(error.Canceled, ops.getResult());

    // Outer race should succeed
    try race.getResult();
}

test "group: nested gather inside gather" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    var op1: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var op2: Timer = .init(.{ .duration = .fromMilliseconds(20) });
    var op3: Timer = .init(.{ .duration = .fromMilliseconds(30) });

    // Inner gather
    var inner: Group = .init(.gather);
    inner.add(&op1.c);
    inner.add(&op2.c);

    // Outer gather
    var outer: Group = .init(.gather);
    outer.add(&inner.c);
    outer.add(&op3.c);

    loop.add(&outer.c);
    try loop.run(.until_done);

    // All should complete successfully
    try op1.getResult();
    try op2.getResult();
    try op3.getResult();
    try inner.getResult();
    try outer.getResult();
}

test "group: nested race inside gather" {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    // Inner race: fast vs slow
    var fast: Timer = .init(.{ .duration = .fromMilliseconds(10) });
    var slow: Timer = .init(.{ .duration = .fromMilliseconds(1000) });
    var inner: Group = .init(.race);
    inner.add(&fast.c);
    inner.add(&slow.c);

    // Another op in outer gather
    var op: Timer = .init(.{ .duration = .fromMilliseconds(50) });

    // Outer gather waits for both inner race and op
    var outer: Group = .init(.gather);
    outer.add(&inner.c);
    outer.add(&op.c);

    loop.add(&outer.c);
    try loop.run(.until_done);

    // Fast wins inner race, slow is canceled
    try fast.getResult();
    try std.testing.expectError(error.Canceled, slow.getResult());
    try inner.getResult();

    // Op completes normally
    try op.getResult();

    // Outer gather succeeds
    try outer.getResult();
}
