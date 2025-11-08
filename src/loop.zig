const std = @import("std");
const Backend = @import("backend.zig").Backend;
const Completion = @import("completion.zig").Completion;
const Cancel = @import("completion.zig").Cancel;
const NetClose = @import("completion.zig").NetClose;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const Queue = @import("queue.zig").Queue;
const Heap = @import("heap.zig").Heap;
const Work = @import("completion.zig").Work;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
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

pub fn SimpleStack(comptime T: type) type {
    return struct {
        head: ?*T = null,

        pub fn push(self: *@This(), value: *T) void {
            value.next = self.head;
            self.head = value;
        }

        pub fn pop(self: *@This()) ?*T {
            const head = self.head orelse return null;
            self.head = head.next;
            return head;
        }
    };
}

pub fn AtomicStack(comptime T: type) type {
    return struct {
        head: std.atomic.Value(?*T) = .init(null),

        pub fn push(self: *@This(), value: *T) void {
            var head = self.head.load(.acquire);
            while (true) {
                value.next = head;
                if (self.head.cmpxchgWeak(head, value, .acq_rel, .acquire)) |prev_value| {
                    head = prev_value;
                    continue;
                }
                break;
            }
        }

        pub fn popAll(self: *@This()) SimpleStack(T) {
            const head = self.head.swap(null, .acq_rel);
            return .{ .head = head };
        }
    };
}

pub const LoopState = struct {
    loop: *Loop,

    initialized: bool = false,
    running: bool = false,
    stopped: bool = false,

    active: usize = 0,

    now_ms: u64 = 0,
    timers: TimerHeap = .{ .context = {} },

    submissions: Queue(Completion) = .{},
    async_handles: Queue(Completion) = .{},

    work_completions: AtomicStack(Completion) = .{},

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
        if (was_active) {
            self.timers.remove(timer);
        }
    }
};

pub const Loop = struct {
    state: LoopState,
    backend: Backend,

    thread_pool: ?*ThreadPool = null,

    max_wait_ms: u64 = 60 * std.time.ms_per_s,

    pub const Options = struct {
        thread_pool: ?*ThreadPool = null,
    };

    pub fn init(self: *Loop, options: Options) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
            .thread_pool = options.thread_pool,
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
        return self.state.stopped or (self.state.active == 0 and self.state.submissions.empty());
    }

    /// Wake up the loop from blocking poll/epoll (thread-safe)
    pub fn wake(self: *Loop) void {
        self.backend.wake();
    }

    pub fn run(self: *Loop, mode: RunMode) !void {
        std.debug.assert(self.state.initialized);
        if (self.state.stopped) return;
        switch (mode) {
            .no_wait => try self.tick(false),
            .once => try self.tick(true),
            .until_done => while (!self.done()) {
                try self.tick(true);
            },
        }
    }

    pub fn add(self: *Loop, c: *Completion) void {
        switch (c.op) {
            .timer => {
                const timer = c.cast(Timer);
                self.state.setTimer(timer);
                return;
            },
            .async => {
                const async_handle = c.cast(Async);
                // Set loop reference and add to async_handles queue
                async_handle.loop = self;
                async_handle.c.state = .running;
                self.state.active += 1;
                self.state.async_handles.push(&async_handle.c);
                return;
            },
            .work => {
                const work = c.cast(Work);
                if (self.thread_pool) |thread_pool| {
                    work.loop = self;
                    work.c.state = .adding;
                    self.state.active += 1;
                    thread_pool.submit(work);
                } else {
                    work.loop = self;
                    work.c.state = .running;
                    work.result = error.NoThreadPool;
                    self.state.active += 1;
                    work.state.store(.completed, .release);
                    self.state.markCompleted(&work.c);
                }
                return;
            },
            else => {
                if (c.op == .cancel) {
                    const cancel = c.cast(Cancel);
                    switch (cancel.cancel_c.op) {
                        .timer => {
                            const timer = cancel.cancel_c.cast(Timer);
                            self.state.active += 1; // Count the cancel operation
                            timer.c.canceled = &cancel.c;
                            cancel.result = {};
                            self.state.clearTimer(timer);
                            self.state.markCompleted(&timer.c);
                            return;
                        },
                        .work => {
                            const work = cancel.cancel_c.cast(Work);
                            self.state.active += 1; // Count the cancel operation

                            if (self.thread_pool) |thread_pool| {
                                // Try to atomically cancel the work
                                // This will CAS from .pending to .canceled if work hasn't started
                                if (thread_pool.cancel(work)) {
                                    // Successfully canceled, work was removed from queue
                                    work.result = error.Canceled;
                                    self.state.markCompleted(&work.c);
                                }
                                // If cancel failed, work is already running/completed
                                // The thread pool will complete it and the cancel completion
                            } else {
                                // No thread pool
                                if (work.c.state == .completed) {
                                    cancel.result = error.AlreadyCompleted;
                                    self.state.markCompleted(&cancel.c);
                                } else {
                                    cancel.result = {};
                                    work.result = error.Canceled;
                                    self.state.markCompleted(&work.c);
                                }
                            }
                            return;
                        },
                        else => {},
                    }
                }
                self.state.submit(c);
                return;
            },
        }
    }

    fn checkTimers(self: *Loop) ?u64 {
        self.state.updateNow();
        while (self.state.timers.peek()) |timer| {
            if (timer.deadline_ms > self.state.now_ms) {
                return timer.deadline_ms - self.state.now_ms;
            }
            timer.result = {};
            self.state.clearTimer(timer);
            self.state.markCompleted(&timer.c);
        }
        return null;
    }

    pub fn processAsyncHandles(self: *Loop) void {
        // Drain the async_impl wakeup fd if it was triggered
        if (self.backend.async_impl) |*impl| {
            impl.drain();
        }

        // Check all async handles for pending notifications
        var c = self.state.async_handles.head;
        while (c) |completion| {
            const next = completion.next;
            const async_handle = completion.cast(Async);
            const was_pending = async_handle.pending.swap(0, .acquire);
            if (was_pending != 0) {
                // This handle was notified - remove from queue and complete it
                _ = self.state.async_handles.remove(completion);
                async_handle.result = {};
                self.state.markCompleted(&async_handle.c);
            }
            c = next;
        }
    }

    pub fn processWorkCompletions(self: *Loop) void {
        var stack = self.state.work_completions.popAll();
        while (stack.pop()) |completion| {
            self.state.markCompleted(completion);
        }
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.done()) return;

        const timer_timeout_ms = self.checkTimers();

        var timeout_ms: u64 = 0;
        if (wait) {
            // If we have submissions pending, process them immediately
            if (!self.state.submissions.empty()) {
                timeout_ms = 0;
            } else if (timer_timeout_ms) |t| {
                // Use timer timeout, capped at max_wait_ms
                timeout_ms = @min(t, self.max_wait_ms);
            } else {
                // No timers, wait for blocking I/O
                timeout_ms = self.max_wait_ms;
            }
        }

        try self.backend.tick(&self.state, timeout_ms);

        // Process any work completions from thread pool
        self.processWorkCompletions();

        // Check timers again, to trigger the one that set timeout for the tick
        _ = self.checkTimers();
    }
};

test {
    _ = @import("tests.zig");
}
