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
const FileOpen = @import("completion.zig").FileOpen;
const FileClose = @import("completion.zig").FileClose;
const FileRead = @import("completion.zig").FileRead;
const FileWrite = @import("completion.zig").FileWrite;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const time = @import("os/time.zig");
const net = @import("os/net.zig");
const common = @import("backends/common.zig");

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
        if (completion.canceled) |cancel| {
            // Cancel should NEVER be completed before the target operation
            std.debug.assert(cancel.c.state != .completed);
            self.markCompleted(&cancel.c);
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

    allocator: std.mem.Allocator,
    thread_pool: ?*ThreadPool = null,

    max_wait_ms: u64 = 60 * std.time.ms_per_s,

    pub const Options = struct {
        allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_pool: ?*ThreadPool = null,
    };

    pub fn init(self: *Loop, options: Options) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
            .allocator = options.allocator,
            .thread_pool = options.thread_pool,
        };

        net.ensureWSAInitialized();
        self.state.updateNow();

        try self.backend.init(options.allocator);
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

    pub fn add(self: *Loop, completion: *Completion) void {
        std.debug.assert(completion.state == .new);

        if (completion.canceled) |cancel| {
            // Directly mark it as canceled
            cancel.c.setResult(.cancel, {});
            completion.setError(error.Canceled);
            self.state.active += 1;
            self.state.markCompleted(completion);
            return;
        }

        switch (completion.op) {
            .timer => {
                const timer = completion.cast(Timer);
                self.state.setTimer(timer);
                return;
            },
            .async => {
                const async = completion.cast(Async);
                async.loop = self;
                async.c.state = .running;
                self.state.active += 1;
                self.state.async_handles.push(&async.c);
                return;
            },
            .work => {
                const work = completion.cast(Work);
                work.loop = self;
                work.c.state = .running;
                self.state.active += 1;
                if (self.thread_pool) |thread_pool| {
                    thread_pool.submit(work);
                } else {
                    work.state.store(.completed, .release);
                    work.c.setError(error.NoThreadPool);
                    self.state.markCompleted(&work.c);
                }
                return;
            },
            else => {
                if (completion.op == .cancel) {
                    const cancel = completion.cast(Cancel);

                    if (cancel.cancel_c.canceled != null) {
                        completion.setError(error.AlreadyCanceled);
                        self.state.active += 1;
                        self.state.markCompleted(completion);
                        return;
                    }

                    if (cancel.cancel_c.state == .completed) {
                        completion.setError(error.AlreadyCompleted);
                        self.state.active += 1;
                        self.state.markCompleted(completion);
                        return;
                    }

                    cancel.cancel_c.canceled = cancel;

                    if (cancel.cancel_c.state == .new) {
                        // Completion hasn't been added yet - just mark it as canceled
                        // When it gets added, the early-exit check at the start of add() will catch it
                        // and complete both the target and this cancel operation
                        self.state.active += 1;
                        return;
                    }

                    if (cancel.cancel_c.state == .adding) {
                        // Completion is in the submissions queue being processed
                        // The backend will catch it in processSubmissions via the canceled field check
                        // and complete both the target and this cancel operation
                        self.state.active += 1;
                        return;
                    }

                    switch (cancel.cancel_c.op) {
                        .timer => {
                            const timer = cancel.cancel_c.cast(Timer);
                            self.state.active += 1; // Count the cancel operation
                            completion.setResult(.cancel, {});
                            timer.c.setError(error.Canceled);
                            self.state.clearTimer(timer);
                            self.state.markCompleted(&timer.c);
                            return;
                        },
                        .async => {
                            const async_handle = cancel.cancel_c.cast(Async);
                            self.state.active += 1; // Count the cancel operation
                            completion.setResult(.cancel, {});
                            async_handle.c.setError(error.Canceled);
                            _ = self.state.async_handles.remove(&async_handle.c);
                            self.state.markCompleted(&async_handle.c);
                            return;
                        },
                        .work => {
                            const work = cancel.cancel_c.cast(Work);
                            std.debug.assert(work.linked == null); // User Work should never have linked set
                            self.state.active += 1; // Count the cancel operation

                            if (self.thread_pool) |thread_pool| {
                                // Try to atomically cancel the work
                                // This will CAS from .pending to .canceled if work hasn't started
                                if (thread_pool.cancel(work)) {
                                    // Successfully canceled, work was removed from queue
                                    completion.setResult(.cancel, {});
                                    work.c.setError(error.Canceled);
                                    self.state.markCompleted(&work.c);
                                }
                                // If cancel failed, work is already running/completed
                                // The thread pool will complete it and the cancel completion
                            } else {
                                // No thread pool - work is always immediately completed with error.NoThreadPool
                                std.debug.assert(work.c.state == .completed);
                                completion.setError(error.AlreadyCompleted);
                                self.state.markCompleted(&cancel.c);
                            }
                            return;
                        },
                        .file_open, .file_close, .file_read, .file_write => {
                            // File ops on backends without native support use internal Work
                            if (!Backend.supports_file_ops) {
                                self.state.active += 1; // Count the cancel operation

                                const work = switch (cancel.cancel_c.op) {
                                    .file_open => &cancel.cancel_c.cast(FileOpen).internal.work,
                                    .file_close => &cancel.cancel_c.cast(FileClose).internal.work,
                                    .file_read => &cancel.cancel_c.cast(FileRead).internal.work,
                                    .file_write => &cancel.cancel_c.cast(FileWrite).internal.work,
                                    else => unreachable,
                                };

                                if (self.thread_pool) |thread_pool| {
                                    if (thread_pool.cancel(work)) {
                                        // Successfully canceled the internal work
                                        completion.setResult(.cancel, {});
                                        cancel.cancel_c.setError(error.Canceled);
                                        self.state.markCompleted(cancel.cancel_c);
                                    }
                                    // If cancel failed, work is running/completed and will complete normally
                                } else {
                                    // No thread pool - file op should already be completed with error.Unexpected
                                    std.debug.assert(cancel.cancel_c.state == .completed);
                                    completion.setError(error.AlreadyCompleted);
                                    self.state.markCompleted(completion);
                                }
                                return;
                            }
                        },
                        else => {},
                    }
                }
                self.state.submit(completion);
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
            timer.c.setResult(.timer, {});
            self.state.clearTimer(timer);
            self.state.markCompleted(&timer.c);
        }
        return null;
    }

    pub fn processAsyncHandles(self: *Loop) void {
        // Check all async handles for pending notifications
        var c = self.state.async_handles.head;
        while (c) |completion| {
            const next = completion.next;
            const async_handle = completion.cast(Async);
            const was_pending = async_handle.pending.swap(0, .acquire);
            if (was_pending != 0) {
                // This handle was notified - remove from queue and complete it
                _ = self.state.async_handles.remove(completion);
                completion.setResult(.async, {});
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

    fn submitFileOpToThreadPool(self: *Loop, completion: *Completion) error{NoThreadPool}!void {
        const tp = self.thread_pool orelse return error.NoThreadPool;

        switch (completion.op) {
            .file_open => {
                const file_open = completion.cast(FileOpen);
                file_open.internal.allocator = self.allocator;
                file_open.internal.work = Work.init(common.fileOpenWork, null);
                file_open.internal.work.loop = self;
                file_open.internal.work.linked = completion;
                tp.submit(&file_open.internal.work);
            },
            .file_close => {
                const file_close = completion.cast(FileClose);
                file_close.internal.work = Work.init(common.fileCloseWork, null);
                file_close.internal.work.loop = self;
                file_close.internal.work.linked = completion;
                tp.submit(&file_close.internal.work);
            },
            .file_read => {
                const file_read = completion.cast(FileRead);
                file_read.internal.work = Work.init(common.fileReadWork, null);
                file_read.internal.work.loop = self;
                file_read.internal.work.linked = completion;
                tp.submit(&file_read.internal.work);
            },
            .file_write => {
                const file_write = completion.cast(FileWrite);
                file_write.internal.work = Work.init(common.fileWriteWork, null);
                file_write.internal.work.loop = self;
                file_write.internal.work.linked = completion;
                tp.submit(&file_write.internal.work);
            },
            else => unreachable,
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

        // Process submissions - separate cancels from regular submissions
        var cancels: Queue(Completion) = .{};
        var submissions: Queue(Completion) = .{};

        while (self.state.submissions.pop()) |completion| {
            // Handle already-canceled completions
            if (completion.canceled) |cancel| {
                cancel.c.setResult(.cancel, {});
                completion.setError(error.Canceled);
                self.state.markCompleted(completion);
                continue;
            }
            // Separate cancel operations
            if (completion.op == .cancel) {
                cancels.push(completion);
                continue;
            }

            // For backends without native file ops support, route to thread pool
            if (!Backend.supports_file_ops) {
                const is_file_op = switch (completion.op) {
                    .file_open, .file_close, .file_read, .file_write => true,
                    else => false,
                };

                if (is_file_op) {
                    self.submitFileOpToThreadPool(completion) catch {
                        // No thread pool configured
                        completion.setError(error.Unexpected);
                        self.state.markCompleted(completion);
                        continue;
                    };
                    self.state.markRunning(completion);
                    continue;
                }
            }

            // Regular submissions
            submissions.push(completion);
        }

        // Process regular submissions through backend
        try self.backend.processSubmissions(&self.state, &submissions);

        // Process cancellations through backend
        try self.backend.processCancellations(&self.state, &cancels);

        const timed_out = try self.backend.tick(&self.state, timeout_ms);

        // Process any work completions from thread pool
        self.processWorkCompletions();

        // Only check timers again if we timed out (avoids syscall when woken by I/O)
        if (timed_out) {
            _ = self.checkTimers();
        }
    }
};

test {
    _ = @import("tests.zig");
}
