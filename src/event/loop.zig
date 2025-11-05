const std = @import("std");
const Backend = @import("backend.zig").Backend;
const Completion = @import("completion.zig").Completion;
const Timer = @import("timer.zig").Timer;
const TimerHeap = @import("timer.zig").TimerHeap;
const time = @import("time.zig");

pub const RunMode = enum {
    no_wait,
    once,
    until_done,
};

pub const Loop = struct {
    state: State,
    backend: Backend,
    timers: TimerHeap,
    active: usize = 0,
    now_ms: u64 = 0,
    max_wait_ms: u64 = 60 * std.time.ms_per_s,

    const State = packed struct {
        initialized: bool = false,
        running: bool = false,
        stopped: bool = false,
    };

    pub fn init(self: *Loop) !void {
        self.* = .{
            .state = .{},
            .timers = .{ .context = {} },
            .backend = undefined,
            .now_ms = time.now(.monotonic),
        };

        try self.backend.init();
        errdefer self.backend.deinit();

        self.state.initialized = true;
    }

    pub fn deinit(self: *Loop) void {
        self.backend.deinit();
    }

    pub fn stop(self: *Loop) void {
        self.state.stopped = true;
    }

    pub fn stopped(self: *const Loop) bool {
        return self.state.stopped;
    }

    pub fn done(self: *const Loop) bool {
        return self.state.stopped or self.active == 0;
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        std.debug.assert(self.state.initialized);
        if (self.state.stopped) return;
        switch (mode) {
            .no_wait => try self.tick(false),
            .once => try self.tick(true),
            .until_done => while (!self.done()) try self.tick(true),
        }
    }

    pub fn add(self: *Loop, c: *Completion) void {
        switch (c.op) {
            .timer => {
                setTimer(self, .fromCompletion(c));
            },
            else => {
                @panic("TODO");
            },
        }
    }

    pub fn cancel(self: *Loop, c: *Completion) void {
        switch (c.op) {
            .timer => {
                clearTimer(self, .fromCompletion(c));
            },
            else => {
                @panic("TODO");
            },
        }
    }

    fn setTimer(self: *Loop, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = self.now_ms +| timer.delay_ms;
        timer.c.state = .active;
        if (was_active) {
            self.timers.remove(timer);
        } else {
            self.active += 1;
        }
        self.timers.insert(timer);
    }

    fn clearTimer(self: *Loop, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = 0;
        timer.c.state = .dead;
        if (was_active) {
            self.timers.remove(timer);
            self.active -= 1;
        }
    }

    fn checkTimers(self: *Loop) u64 {
        self.now_ms = time.now(.monotonic);
        var timeout_ms: u64 = 0;
        while (self.timers.peek()) |timer| {
            if (timer.deadline_ms > self.now_ms) {
                timeout_ms = @min(timer.deadline_ms - self.now_ms, self.max_wait_ms);
                break;
            }
            const action = timer.c.call(self);
            switch (action) {
                .rearm => self.setTimer(timer),
                .disarm => self.clearTimer(timer),
            }
        }
        return timeout_ms;
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.state.stopped) return;

        var timeout_ms: u64 = checkTimers(self);
        if (!wait) {
            timeout_ms = 0;
        }

        try self.backend.tick(timeout_ms);

        // Check times again, to trigger the one that set timeout for the tick
        _ = checkTimers(self);
    }
};

test "Loop: empty run(.no_wait)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.no_wait);
}

test "Loop: empty run(.once)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.once);
}

test "Loop: empty run(.until_done)" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.until_done);
}

test "Loop: timer iters" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state == .active) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(11, n_iter);
}

test "Loop: timer iters cancel" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    var timer: Timer = .init(5);
    loop.add(&timer.c);

    var n_iter: usize = 0;
    while (timer.c.state == .active) {
        if (n_iter >= 10) {
            try loop.run(.once);
        } else {
            if (n_iter == 5) {
                loop.cancel(&timer.c);
            }
            try loop.run(.no_wait);
        }
        n_iter += 1;
    }
    try std.testing.expectEqual(6, n_iter);
}

test {
    std.testing.refAllDecls(@This());
}
