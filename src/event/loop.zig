const std = @import("std");
const Backend = @import("backend.zig").Backend;
const Completion = @import("completion.zig").Completion;
const Cancel = @import("completion.zig").Cancel;
const NetClose = @import("completion.zig").NetClose;
const Timer = @import("completion.zig").Timer;
const Queue = @import("queue.zig").Queue;
const Heap = @import("heap.zig").Heap;
const time = @import("time.zig");
const socket = @import("os/posix/socket.zig");

pub const RunMode = enum {
    no_wait,
    once,
    until_done,
};

fn timerDeadlineLess(_: void, a: *Timer, b: *Timer) bool {
    return a.deadline_ms < b.deadline_ms;
}

const TimerHeap = Heap(Timer, void, timerDeadlineLess);

pub const LoopState = struct {
    loop: *Loop,

    initialized: bool = false,
    running: bool = false,
    stopped: bool = false,

    active: usize = 0,

    now_ms: u64 = 0,
    timers: TimerHeap = .{ .context = {} },

    submissions: Queue(Completion) = .{},

    pub fn markCompleted(self: *LoopState, completion: *Completion) void {
        if (completion.canceled) |cancel_c| {
            self.markCompleted(cancel_c);
        }
        completion.state = .completed;
        self.active -= 1;
        completion.call(self.loop);
    }

    pub fn markRunning(self: *LoopState, completion: *Completion) void {
        _ = self;
        completion.state = .running;
    }

    pub fn submit(self: *LoopState, completion: *Completion) void {
        completion.state = .adding;
        self.active += 1;
        self.submissions.push(completion);
    }

    pub fn updateNow(self: *LoopState) void {
        self.now_ms = time.now(.monotonic);
    }

    pub fn setTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = self.now_ms +| timer.delay_ms;
        timer.c.state = .running;
        if (was_active) {
            self.timers.remove(timer);
        } else {
            self.active += 1;
        }
        self.timers.insert(timer);
    }

    pub fn clearTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.deadline_ms > 0;
        timer.deadline_ms = 0;
        timer.c.state = .completed;
        if (was_active) {
            self.timers.remove(timer);
            self.active -= 1;
        }
    }
};

pub const Loop = struct {
    state: LoopState,
    backend: Backend,

    max_wait_ms: u64 = 60 * std.time.ms_per_s,

    pub fn init(self: *Loop) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
        };

        socket.ensureWSAInitialized();
        self.state.updateNow();

        try self.backend.init(std.heap.page_allocator);
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
        return self.state.stopped or self.state.active == 0;
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
                const timer = c.cast(Timer);
                self.state.setTimer(timer);
                return;
            },
            else => {
                if (c.op == .cancel) {
                    const cancel = c.cast(Cancel);
                    if (cancel.cancel_c.op == .timer) {
                        const timer = cancel.cancel_c.cast(Timer);
                        self.state.clearTimer(timer);
                        return;
                    }
                }
                self.state.submit(c);
                return;
            },
        }
    }

    fn checkTimers(self: *Loop) u64 {
        self.state.updateNow();
        var timeout_ms: u64 = self.max_wait_ms;
        while (self.state.timers.peek()) |timer| {
            if (timer.deadline_ms > self.state.now_ms) {
                timeout_ms = @min(timer.deadline_ms - self.state.now_ms, self.max_wait_ms);
                break;
            }
            timer.result = {};
            self.state.clearTimer(timer);
            timer.c.call(self);
        }
        return timeout_ms;
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.state.stopped) return;

        var timeout_ms: u64 = checkTimers(self);
        if (!wait) {
            timeout_ms = 0;
        }

        try self.backend.tick(&self.state, timeout_ms);

        // Check times again, to trigger the one that set timeout for the tick
        _ = checkTimers(self);
    }
};

test {
    _ = @import("tests.zig");
}
