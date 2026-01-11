const std = @import("std");
const builtin = @import("builtin");
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
const FileCreate = @import("completion.zig").FileCreate;
const FileClose = @import("completion.zig").FileClose;
const FileRead = @import("completion.zig").FileRead;
const FileWrite = @import("completion.zig").FileWrite;
const FileSync = @import("completion.zig").FileSync;
const DirCreateDir = @import("completion.zig").DirCreateDir;
const DirRename = @import("completion.zig").DirRename;
const DirDeleteFile = @import("completion.zig").DirDeleteFile;
const DirDeleteDir = @import("completion.zig").DirDeleteDir;
const FileSize = @import("completion.zig").FileSize;
const FileStat = @import("completion.zig").FileStat;
const DirOpen = @import("completion.zig").DirOpen;
const DirClose = @import("completion.zig").DirClose;
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const time = @import("../os/time.zig");
const net = @import("../os/net.zig");
const common = @import("backends/common.zig");

const log = std.log.scoped(.zevent_loop);

const in_safe_mode = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const LoopGroup = struct {
    shared: Backend.SharedState = .{},
};

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
            head.next = null;
            return head;
        }

        pub fn empty(self: *const @This()) bool {
            return self.head == null;
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

        pub fn empty(self: *const @This()) bool {
            return self.head.load(.acquire) == null;
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
    timer_mutex: if (Backend.capabilities.is_multi_threaded) std.Thread.Mutex else void =
        if (Backend.capabilities.is_multi_threaded) .{} else {},

    async_handles: Queue(Completion) = .{},

    completions: Queue(Completion) = .{},
    work_completions: AtomicStack(Completion) = .{},

    pub fn markCompleted(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .running);
        std.debug.assert(completion.has_result);

        if (completion.canceled_by) |cancel| {
            std.debug.assert(!cancel.c.has_result);
            cancel.c.state = .running; // Set to running before marking completed
            var set = false;
            if (completion.err) |err| {
                if (err == error.Canceled) {
                    cancel.c.setResult(.cancel, {});
                    set = true;
                }
            }
            if (!set) {
                cancel.c.setError(error.AlreadyCompleted);
            }
            self.markCompleted(&cancel.c);
        }

        completion.state = .completed;

        if (self.loop.defer_callbacks) {
            self.completions.push(completion);
        } else {
            self.finishCompletion(completion);
        }
    }

    pub fn finishCompletion(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .completed);

        completion.state = .dead;
        self.active -= 1;
        completion.call(self.loop);
    }

    pub fn markRunning(self: *LoopState, completion: *Completion) void {
        _ = self;
        completion.state = .running;
    }

    pub fn updateNow(self: *LoopState) void {
        self.now_ms = time.now(.monotonic);
    }

    pub fn lockTimers(self: *LoopState) void {
        if (Backend.capabilities.is_multi_threaded) {
            self.timer_mutex.lock();
        }
    }

    pub fn unlockTimers(self: *LoopState) void {
        if (Backend.capabilities.is_multi_threaded) {
            self.timer_mutex.unlock();
        }
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

    loop_group: *LoopGroup,
    internal_loop_group: LoopGroup = .{},

    max_wait_ms: u64 = 60 * std.time.ms_per_s,
    defer_callbacks: bool = true,

    in_add: if (in_safe_mode) bool else void = if (in_safe_mode) false else {},

    const default_queue_size = 256;

    pub const Options = struct {
        allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_pool: ?*ThreadPool = null,
        loop_group: ?*LoopGroup = null,
        queue_size: u16 = default_queue_size,
        defer_callbacks: bool = true,
    };

    pub fn init(self: *Loop, options: Options) !void {
        self.* = .{
            .state = .{ .loop = self },
            .backend = undefined,
            .allocator = options.allocator,
            .thread_pool = options.thread_pool,
            .loop_group = undefined,
            .defer_callbacks = options.defer_callbacks,
        };

        if (options.loop_group) |group| {
            self.loop_group = group;
        } else {
            self.loop_group = &self.internal_loop_group;
        }

        if (options.queue_size == 0) {
            return error.InvalidQueueSize;
        }

        net.ensureWSAInitialized();
        self.state.updateNow();

        try self.backend.init(options.allocator, options.queue_size, &self.loop_group.shared);
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
        return self.state.stopped or (self.state.active == 0 and self.state.completions.empty());
    }

    /// Get the current monotonic timestamp in milliseconds
    pub fn now(self: *const Loop) u64 {
        return self.state.now_ms;
    }

    /// Wake up the loop from another thread (thread-safe)
    pub fn wake(self: *Loop) void {
        self.backend.wake();
    }

    /// Wake up the loop from anywhere, including signal handlers (async-signal-safe)
    pub fn wakeFromAnywhere(self: *Loop) void {
        self.backend.wakeFromAnywhere();
    }

    /// Set or reset a timer with a new delay (works immediately, no completion required)
    pub fn setTimer(self: *Loop, timer: *Timer, delay_ms: u64) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        self.state.updateNow();
        timer.delay_ms = delay_ms;
        self.state.setTimer(timer);
    }

    /// Clear a timer without completing it (works immediately, no cancellation completion required)
    pub fn clearTimer(self: *Loop, timer: *Timer) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        const was_active = timer.deadline_ms > 0;
        self.state.clearTimer(timer);
        if (was_active) {
            // Reset state so timer can be reused
            timer.c.state = .new;
            timer.c.has_result = false;
            timer.c.err = null;
            self.state.active -= 1;
        }
    }

    /// Cancel a completion directly without requiring a Cancel completion struct.
    /// This is a fire-and-forget operation - the completion's callback will still be
    /// invoked when the operation completes (either with error.Canceled or its natural result).
    pub fn cancel(self: *Loop, completion: *Completion) !void {
        return self.cancelInternal(completion, null);
    }

    /// Internal cancel implementation
    fn cancelInternal(self: *Loop, completion: *Completion, cancel_comp: ?*Cancel) !void {
        // Check if already being canceled
        if (completion.canceled) return error.AlreadyCanceled;

        // Check state
        if (completion.state == .completed or completion.state == .dead) {
            return error.AlreadyCompleted;
        }

        if (completion.state == .new) {
            return error.NotStarted;
        }

        if (completion.op == .cancel) {
            return error.Uncancelable;
        }

        // Mark as canceled and set canceled_by
        completion.canceled = true;
        completion.canceled_by = cancel_comp;

        // Perform the cancellation
        switch (completion.op) {
            .timer => {
                const timer = completion.cast(Timer);
                timer.c.setError(error.Canceled);
                self.state.lockTimers();
                self.state.clearTimer(timer);
                self.state.unlockTimers();
                self.state.markCompleted(&timer.c);
            },
            .async => {
                const async_handle = completion.cast(Async);
                async_handle.c.setError(error.Canceled);
                _ = self.state.async_handles.remove(&async_handle.c);
                self.state.markCompleted(&async_handle.c);
            },
            .work => {
                const thread_pool = self.thread_pool orelse unreachable;
                const work = completion.cast(Work);
                thread_pool.cancel(work);
            },

            inline .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .dir_create_dir, .dir_rename, .dir_delete_file, .dir_delete_dir, .file_size, .file_stat, .dir_open, .dir_close, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps => |op| {
                if (!@field(Backend.capabilities, @tagName(op))) {
                    const thread_pool = self.thread_pool orelse unreachable;
                    const op_data = completion.cast(op.toType());
                    thread_pool.cancel(&op_data.internal.work);
                } else {
                    self.backend.cancel(&self.state, completion);
                }
            },

            else => {
                // Backend operations (net_*, etc)
                self.backend.cancel(&self.state, completion);
            },
        }
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
        if (in_safe_mode) {
            if (self.in_add) {
                @panic("recursive call to Loop.add() is not allowed");
            }
            self.in_add = true;
        }
        defer {
            if (in_safe_mode) self.in_add = false;
        }

        // If completion is dead (callback was called), reset it to new state for rearming
        if (completion.state == .dead) {
            completion.reset();
        }

        std.debug.assert(completion.state == .new);

        if (completion.canceled) {
            // Directly mark it as canceled
            completion.setError(error.Canceled);
            self.state.active += 1;
            completion.state = .running;
            self.state.markCompleted(completion);
            return;
        }

        switch (completion.op) {
            .timer => {
                const timer = completion.cast(Timer);
                self.state.lockTimers();
                self.state.setTimer(timer);
                self.state.unlockTimers();
                return;
            },
            .async => {
                const async = completion.cast(Async);
                async.loop = self;
                async.c.state = .running;
                self.state.active += 1;

                // Check if already notified before submission
                if (checkAndSetAsyncResult(async)) {
                    // Already pending - complete immediately
                    self.state.markCompleted(&async.c);
                } else {
                    // Not pending - add to queue to wait for notification
                    self.state.async_handles.push(&async.c);
                }
                return;
            },
            .work => {
                const work = completion.cast(Work);
                work.completion_fn = loopWorkComplete;
                work.completion_context = @ptrCast(self);
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
                    const cancel_comp = completion.cast(Cancel);

                    // Cancel completion is always active and running
                    self.state.active += 1;
                    completion.state = .running;

                    self.cancelInternal(cancel_comp.target, cancel_comp) catch |err| switch (err) {
                        error.AlreadyCanceled, error.AlreadyCompleted, error.Uncancelable => |e| {
                            completion.setError(e);
                            self.state.markCompleted(completion);
                            return;
                        },
                        error.NotStarted => {
                            // Target hasn't been added yet - mark as canceled and wait
                            // When it gets added, the early-exit check at the start of add() will catch it
                            cancel_comp.target.canceled = true;
                            cancel_comp.target.canceled_by = cancel_comp;
                            return;
                        },
                    };

                    return;
                }

                // Regular backend operation
                // Route file operations to thread pool for backends without native support
                switch (completion.op) {
                    inline .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .dir_create_dir, .dir_rename, .dir_delete_file, .dir_delete_dir, .file_size, .file_stat, .dir_open, .dir_close, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps => |op| {
                        if (!@field(Backend.capabilities, @tagName(op))) {
                            self.submitFileOpToThreadPool(completion);
                            return;
                        }
                    },
                    else => {},
                }

                self.backend.submit(&self.state, completion);
                return;
            },
        }
    }

    const TimerCheckResult = struct {
        next_timeout_ms: ?u64,
        fired: bool,
    };

    fn checkTimers(self: *Loop) TimerCheckResult {
        var fired = false;
        var next_timeout_ms: ?u64 = null;

        // Process fired timers in batches to avoid holding the lock during callbacks.
        // This prevents deadlock when callbacks try to set/clear timers.
        while (true) {
            var batch: [4]*Timer = undefined;
            var batch_count: usize = 0;

            self.state.lockTimers();
            self.state.updateNow();
            while (self.state.timers.peek()) |timer| {
                if (timer.deadline_ms > self.state.now_ms) {
                    next_timeout_ms = timer.deadline_ms - self.state.now_ms;
                    break;
                }
                timer.c.setResult(.timer, {});
                self.state.clearTimer(timer);
                batch[batch_count] = timer;
                batch_count += 1;
                if (batch_count >= batch.len) break;
            }
            self.state.unlockTimers();

            // Mark completions outside the lock
            for (batch[0..batch_count]) |timer| {
                self.state.markCompleted(&timer.c);
                fired = true;
            }

            // If we didn't fill the batch, we're done
            if (batch_count < batch.len) break;
        }

        return .{ .next_timeout_ms = next_timeout_ms, .fired = fired };
    }

    /// Check if an async handle is pending and set its result if so.
    /// Returns true if the async was pending and had its result set.
    /// Caller is responsible for managing queues and calling markCompleted.
    fn checkAndSetAsyncResult(async_handle: *Async) bool {
        const was_pending = async_handle.pending.swap(0, .acquire);
        if (was_pending != 0) {
            async_handle.c.setResult(.async, {});
            async_handle.loop = null;
            return true;
        }
        return false;
    }

    /// Standard completion callback for user-submitted Work
    pub fn loopWorkComplete(ctx: ?*anyopaque, work: *Work) void {
        const loop: *Loop = @ptrCast(@alignCast(ctx));
        loop.state.work_completions.push(&work.c);
        loop.wake();
    }

    /// Linked work context for file operations
    pub const LinkedWorkContext = struct {
        loop: *Loop,
        linked: *Completion,
    };

    /// Completion callback for internal file ops with linked completion
    pub fn loopLinkedWorkComplete(ctx: ?*anyopaque, work: *Work) void {
        const context: *LinkedWorkContext = @ptrCast(@alignCast(ctx));
        // Propagate cancel error from work to linked completion
        if (work.c.err) |err| {
            if (!context.linked.has_result) {
                context.linked.setError(err);
            }
        }
        context.loop.state.work_completions.push(context.linked);
        context.loop.wake();
    }

    pub fn processAsyncHandles(self: *Loop) void {
        // Check all async handles for pending notifications
        var c = self.state.async_handles.head;
        while (c) |completion| {
            const next = completion.next;
            const async_handle = completion.cast(Async);
            if (checkAndSetAsyncResult(async_handle)) {
                // This handle was notified - remove from queue and complete it
                _ = self.state.async_handles.remove(completion);
                self.state.markCompleted(&async_handle.c);
            }
            c = next;
        }
    }

    pub fn processCompletions(self: *Loop) void {
        var work_completions = self.state.work_completions.popAll();
        while (work_completions.pop()) |completion| {
            self.state.markCompleted(completion);
        }

        while (self.state.completions.pop()) |completion| {
            self.state.finishCompletion(completion);
        }
    }

    fn submitFileOpToThreadPool(self: *Loop, completion: *Completion) void {
        const tp = self.thread_pool orelse {
            // No thread pool - complete with error
            log.err("No thread pool available for file operation", .{});
            completion.state = .running;
            self.state.active += 1;
            completion.setError(error.Unexpected);
            self.state.markCompleted(completion);
            return;
        };

        completion.state = .running;
        self.state.active += 1;

        switch (completion.op) {
            inline .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .dir_create_dir, .dir_rename, .dir_delete_file, .dir_delete_dir, .file_size, .file_stat, .dir_open, .dir_close, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps => |op| {
                if (@field(Backend.capabilities, @tagName(op))) {
                    unreachable;
                }

                const op_func = switch (op) {
                    .file_open => common.fileOpenWork,
                    .file_create => common.fileCreateWork,
                    .file_close => common.fileCloseWork,
                    .file_read => common.fileReadWork,
                    .file_write => common.fileWriteWork,
                    .file_sync => common.fileSyncWork,
                    .file_set_size => common.fileSetSizeWork,
                    .file_set_permissions => common.fileSetPermissionsWork,
                    .file_set_owner => common.fileSetOwnerWork,
                    .file_set_timestamps => common.fileSetTimestampsWork,
                    .dir_create_dir => common.dirCreateDirWork,
                    .dir_rename => common.dirRenameWork,
                    .dir_delete_file => common.dirDeleteFileWork,
                    .dir_delete_dir => common.dirDeleteDirWork,
                    .file_size => common.fileSizeWork,
                    .file_stat => common.fileStatWork,
                    .dir_open => common.dirOpenWork,
                    .dir_close => common.dirCloseWork,
                    .dir_set_permissions => common.dirSetPermissionsWork,
                    .dir_set_owner => common.dirSetOwnerWork,
                    .dir_set_file_permissions => common.dirSetFilePermissionsWork,
                    .dir_set_file_owner => common.dirSetFileOwnerWork,
                    .dir_set_file_timestamps => common.dirSetFileTimestampsWork,
                    else => unreachable,
                };

                const op_data = completion.cast(op.toType());
                if (@hasField(@TypeOf(op_data.internal), "allocator")) {
                    op_data.internal.allocator = self.allocator;
                }
                op_data.internal.linked_context = .{
                    .loop = self,
                    .linked = completion,
                };
                op_data.internal.work = Work.init(op_func, null);
                op_data.internal.work.completion_fn = loopLinkedWorkComplete;
                op_data.internal.work.completion_context = @ptrCast(&op_data.internal.linked_context);
                tp.submit(&op_data.internal.work);
            },
            else => unreachable,
        }
    }

    pub fn tick(self: *Loop, wait: bool) !void {
        if (self.done()) return;

        const timer_result = self.checkTimers();

        var timeout_ms: u64 = 0;
        if (wait) {
            // Don't block if we have completions waiting to be processed or timers fired
            if (!self.state.completions.empty() or !self.state.work_completions.empty() or timer_result.fired) {
                timeout_ms = 0;
            } else if (timer_result.next_timeout_ms) |t| {
                // Use timer timeout, capped at max_wait_ms
                timeout_ms = @min(t, self.max_wait_ms);
            } else {
                // No timers, wait for blocking I/O
                timeout_ms = self.max_wait_ms;
            }
        }

        const timed_out = try self.backend.poll(&self.state, timeout_ms);

        // Process any work completions from thread pool
        self.processCompletions();

        // Only check timers again if we timed out (avoids syscall when woken by I/O)
        if (timed_out) {
            _ = self.checkTimers();
        }
    }
};

test {
    _ = @import("tests.zig");
}
