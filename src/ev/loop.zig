const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("backend.zig").Backend;
const BackendCapabilities = @import("completion.zig").BackendCapabilities;
const Completion = @import("completion.zig").Completion;
const Group = @import("completion.zig").Group;
const NetClose = @import("completion.zig").NetClose;
const Timer = @import("completion.zig").Timer;
const Async = @import("completion.zig").Async;
const Duration = @import("../time.zig").Duration;
const Timestamp = @import("../time.zig").Timestamp;
const Timeout = @import("../time.zig").Timeout;
const Queue = @import("queue.zig").Queue;
const Heap = @import("heap.zig").Heap;
const Work = @import("completion.zig").Work;
const os = @import("../os/root.zig");
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

const log = @import("../common.zig").log;

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
    return a.deadline.value < b.deadline.value;
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
    /// I/O operations submitted to backend awaiting completion
    inflight_io: usize = 0,

    wake_requested: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    now: Timestamp = .zero,
    timers: TimerHeap = .{ .context = {} },
    // TODO: Linked timers optimization
    // Instead of mutex-protected cross-thread timer cancellation, link timers to their
    // associated operations. When an operation completes, its linked timer is cleared
    // on the same thread (no mutex). When a timer fires, its linked operation is
    // cancelled on the same thread. This eliminates cross-thread synchronization for
    // the common timeout pattern:
    //   - Add `linked_timer: ?*Timer` to Completion
    //   - Add `linked_completion: ?*Completion` to Timer
    //   - On operation complete: clear linked timer (same thread, direct)
    //   - On timer fire: cancel linked operation (same thread, direct)
    // The cross-thread cancel mechanism remains for general cancellation (task migration,
    // external cancellation), but timeouts become zero-overhead pointer unlinking.
    timer_mutex: os.Mutex = .init(),

    async_handles: Queue(Completion) = .{},

    completions: Queue(Completion) = .{},
    work_completions: AtomicStack(Completion) = .{},

    pub const wake_loop: u32 = 1;
    pub const wake_async: u32 = 2;
    pub const wake_cancel: u32 = 4;

    /// Called by backends when an I/O operation completes.
    /// Decrements inflight_io counter and marks the completion done.
    pub fn markCompletedFromBackend(self: *LoopState, completion: *Completion) void {
        self.inflight_io -= 1;
        self.markCompleted(completion);
    }

    pub fn markCompleted(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .running);
        std.debug.assert(completion.has_result);

        // Atomically set completed flag
        var old = completion.cancel_state.load(.acquire);
        while (true) {
            var new = old;
            new.completed = true;
            old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
        }

        // Always set state
        completion.state = .completed;

        // Only call finish if not in cancel queue
        // If in_queue, cancel queue processing will call finishCompletion
        if (!old.in_queue) {
            if (self.loop.defer_callbacks) {
                self.completions.push(completion);
            } else {
                self.finishCompletion(completion);
            }
        }
    }

    pub fn finishCompletion(self: *LoopState, completion: *Completion) void {
        std.debug.assert(completion.state == .completed);

        completion.state = .dead;
        self.active -= 1;

        // Notify group owner if this completion belongs to one
        if (completion.group.owner) |owner| {
            const group: *Group = @ptrCast(@alignCast(owner));
            const prev = group.remaining.fetchSub(1, .acq_rel);

            // Race mode: first to clear the flag wins, cancels siblings
            if (group.race.swap(false, .acq_rel)) {
                var node = group.head;
                while (node) |n| {
                    const next = n.next;
                    const c: *Completion = @fieldParentPtr("group", n);
                    if (c != completion) {
                        self.loop.cancel(c);
                    }
                    node = next;
                }
            }

            if (prev == 1) {
                if (group.c.cancel_state.load(.acquire).requested) {
                    group.c.setError(error.Canceled);
                } else {
                    group.c.setResult(.group, {});
                }
                self.markCompleted(&group.c);
            }
        }

        completion.call(self.loop);
    }

    pub fn markRunning(self: *LoopState, completion: *Completion) void {
        _ = self;
        completion.state = .running;
    }

    pub fn updateNow(self: *LoopState) void {
        self.now = time.now(.monotonic);
    }

    pub fn lockTimers(self: *LoopState) void {
        self.timer_mutex.lock();
    }

    pub fn unlockTimers(self: *LoopState) void {
        self.timer_mutex.unlock();
    }

    pub fn setTimer(self: *LoopState, timer: *Timer) void {
        if (timer.deadline.value > 0) {
            self.timers.remove(timer);
        } else {
            self.active += 1;
        }
        switch (timer.timeout) {
            .none => timer.deadline = .{ .value = std.math.maxInt(time.TimeInt) },
            .duration => |d| timer.deadline = self.now.addDuration(d),
            .deadline => |ts| timer.deadline = ts,
        }
        timer.c.state = .running;
        self.timers.insert(timer);
    }

    pub fn clearTimer(self: *LoopState, timer: *Timer) void {
        const was_active = timer.deadline.value > 0;
        if (was_active) {
            self.timers.remove(timer);
        }
        timer.deadline = .zero;
    }
};

pub const Loop = struct {
    state: LoopState,
    backend: Backend,

    allocator: std.mem.Allocator,
    thread_pool: ?*ThreadPool = null,

    loop_group: *LoopGroup,
    internal_loop_group: LoopGroup = .{},

    max_wait: Duration = .fromSeconds(60),
    defer_callbacks: bool = true,

    /// Cross-thread cancel queue (lock-free MPSC)
    cancel_queue: std.atomic.Value(?*Completion) = std.atomic.Value(?*Completion).init(null),

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

    /// Get the current monotonic timestamp
    pub fn now(self: *const Loop) Timestamp {
        return self.state.now;
    }

    /// Wake up the loop from another thread (thread-safe)
    pub fn wake(self: *Loop) void {
        // If we're the first to request a wake since the last poll, do the syscall.
        // Subsequent wakers see true and skip - the syscall is already pending.
        if (self.state.wake_requested.fetchOr(LoopState.wake_loop, .acq_rel) == 0) {
            self.backend.wake(&self.state);
        }
    }

    /// Wake up the loop to process async handles (thread-safe)
    pub fn wakeAsync(self: *Loop) void {
        if (self.state.wake_requested.fetchOr(LoopState.wake_async, .acq_rel) == 0) {
            self.backend.wake(&self.state);
        }
    }

    /// Set or reset a timer with a new timeout (works immediately, no completion required)
    pub fn setTimer(self: *Loop, timer: *Timer, timeout: Timeout) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        self.state.updateNow();
        timer.c.loop = self;
        timer.timeout = timeout;
        self.state.setTimer(timer);
    }

    /// Clear a timer without completing it (works immediately, no cancellation completion required)
    pub fn clearTimer(self: *Loop, timer: *Timer) void {
        self.state.lockTimers();
        defer self.state.unlockTimers();
        const was_active = timer.deadline.value > 0;
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
    /// This is a fire-and-forget, idempotent operation - the completion's callback will still be
    /// invoked when the operation completes (either with error.Canceled or its natural result).
    /// Thread-safe: can be called from any thread.
    pub fn cancel(self: *Loop, completion: *Completion) void {
        // Check if completion has been added to a loop
        // (loop is set once by addInternal and never changes)
        const target = completion.loop orelse {
            // Not yet submitted - just set requested, addInternal will handle it
            var old = completion.cancel_state.load(.acquire);
            while (true) {
                if (old.requested) return;
                var new = old;
                new.requested = true;
                old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse return;
            }
            return;
        };

        // Atomically set requested and in_queue flags
        var old = completion.cancel_state.load(.acquire);
        while (true) {
            if (old.requested) return; // Already requested
            if (old.completed) return; // Already completed
            var new = old;
            new.requested = true;
            new.in_queue = true;
            old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
        }

        if (self == target) {
            // Same loop - cancel directly
            self.cancelLocal(completion);
        } else {
            // Push to target's cancel queue (lock-free Treiber stack)
            var head = target.cancel_queue.load(.acquire);
            while (true) {
                completion.cancel_next = head;
                head = target.cancel_queue.cmpxchgWeak(head, completion, .release, .acquire) orelse break;
            }

            if (target.state.wake_requested.fetchOr(LoopState.wake_cancel, .acq_rel) == 0) {
                target.backend.wake(&target.state);
            }
        }
    }

    /// Cancel a completion on the local loop (must be called from the loop's thread)
    fn cancelLocal(self: *Loop, completion: *Completion) void {
        defer {
            // Clear in_queue and call finishCompletion if completed
            var old = completion.cancel_state.load(.acquire);
            while (true) {
                var new = old;
                new.in_queue = false;
                old = completion.cancel_state.cmpxchgWeak(old, new, .acq_rel, .acquire) orelse break;
            }
            if (old.completed) {
                self.state.finishCompletion(completion);
            }
        }

        // If already completed, skip cancel work (defer will still run)
        if (completion.cancel_state.load(.acquire).completed) {
            return;
        }

        switch (completion.op) {
            .group => {
                const group = completion.cast(Group);
                var node = group.head;
                while (node) |n| {
                    const next = n.next;
                    const c: *Completion = @fieldParentPtr("group", n);
                    self.cancel(c);
                    node = next;
                }
            },
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

            inline else => |op| {
                // File/dir ops that can fallback to thread pool
                if (@hasField(BackendCapabilities, @tagName(op))) {
                    if (!@field(Backend.capabilities, @tagName(op))) {
                        const thread_pool = self.thread_pool orelse unreachable;
                        const op_data = completion.cast(op.toType());
                        thread_pool.cancel(&op_data.internal.work);
                    } else {
                        self.backend.cancel(&self.state, completion);
                    }
                } else {
                    // Backend operations (net_*, etc)
                    self.backend.cancel(&self.state, completion);
                }
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
        self.addInternal(completion);
    }

    fn addInternal(self: *Loop, completion: *Completion) void {
        // If completion is dead (callback was called), reset it to new state for rearming
        if (completion.state == .dead) {
            completion.reset();
        }

        std.debug.assert(completion.state == .new);

        // Set the loop reference for cross-thread cancellation
        completion.loop = self;

        if (completion.cancel_state.load(.acquire).requested) {
            // Directly mark it as canceled
            completion.setError(error.Canceled);
            self.state.active += 1;
            completion.state = .running;
            self.state.markCompleted(completion);
            return;
        }

        switch (completion.op) {
            .group => {
                const group = completion.cast(Group);

                // Groups cannot be canceled before submission
                if (group.c.cancel_state.load(.acquire).requested) {
                    @panic("cannot cancel a group before adding it to the loop");
                }

                group.c.state = .running;
                self.state.active += 1;

                if (group.remaining.load(.acquire) == 0) {
                    // Empty group - complete immediately
                    group.c.setResult(.group, {});
                    self.state.markCompleted(&group.c);
                } else {
                    // Add all children to the loop
                    var node = group.head;
                    while (node) |n| {
                        const next = n.next;
                        const c: *Completion = @fieldParentPtr("group", n);
                        self.addInternal(c);
                        node = next;
                    }
                }
                return;
            },
            .timer => {
                const timer = completion.cast(Timer);
                self.state.lockTimers();
                self.state.setTimer(timer);
                self.state.unlockTimers();
                return;
            },
            .async => {
                const async = completion.cast(Async);
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
                // Regular backend operation
                // Route file/dir ops to thread pool for backends without native support
                switch (completion.op) {
                    inline else => |op| {
                        if (@hasField(BackendCapabilities, @tagName(op))) {
                            if (!@field(Backend.capabilities, @tagName(op))) {
                                self.submitFileOpToThreadPool(completion);
                                return;
                            }
                        }
                    },
                }

                self.state.inflight_io += 1;
                self.backend.submit(&self.state, completion);
                return;
            },
        }
    }

    const TimerCheckResult = struct {
        next_timeout: ?Duration,
        fired: bool,
    };

    fn checkTimers(self: *Loop) TimerCheckResult {
        var fired = false;
        var next_timeout: ?Duration = null;

        // Process fired timers in batches to avoid holding the lock during callbacks.
        // This prevents deadlock when callbacks try to set/clear timers.
        while (true) {
            var batch: [4]*Timer = undefined;
            var batch_count: usize = 0;

            self.state.lockTimers();
            self.state.updateNow();
            while (self.state.timers.peek()) |timer| {
                if (timer.deadline.value > self.state.now.value) {
                    next_timeout = self.state.now.durationTo(timer.deadline);
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

        return .{ .next_timeout = next_timeout, .fired = fired };
    }

    /// Check if an async handle is pending and set its result if so.
    /// Returns true if the async was pending and had its result set.
    /// Caller is responsible for managing queues and calling markCompleted.
    fn checkAndSetAsyncResult(async_handle: *Async) bool {
        const was_pending = async_handle.pending.swap(0, .acquire);
        if (was_pending != 0) {
            async_handle.c.setResult(.async, {});
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

    /// Process cross-thread cancel requests
    fn processCancelQueue(self: *Loop) void {
        // Atomically swap the entire queue
        var c = self.cancel_queue.swap(null, .acquire);
        while (c) |completion| {
            const next = completion.cancel_next;
            completion.cancel_next = null;

            // cancelLocal handles completed check and clears in_queue
            self.cancelLocal(completion);

            c = next;
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
            inline .file_open, .file_create, .file_close, .file_read, .file_write, .file_sync, .file_set_size, .file_set_permissions, .file_set_owner, .file_set_timestamps, .dir_create_dir, .dir_rename, .dir_delete_file, .dir_delete_dir, .file_size, .file_stat, .dir_open, .dir_close, .dir_read, .dir_set_permissions, .dir_set_owner, .dir_set_file_permissions, .dir_set_file_owner, .dir_set_file_timestamps, .dir_sym_link, .dir_read_link, .dir_hard_link, .dir_access, .dir_real_path, .dir_real_path_file, .file_real_path, .file_hard_link => |op| {
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
                    .dir_sym_link => common.dirSymLinkWork,
                    .dir_read_link => common.dirReadLinkWork,
                    .dir_hard_link => common.dirHardLinkWork,
                    .dir_access => common.dirAccessWork,
                    .dir_read => common.dirReadWork,
                    .dir_real_path => common.dirRealPathWork,
                    .dir_real_path_file => common.dirRealPathFileWork,
                    .file_real_path => common.fileRealPathWork,
                    .file_hard_link => common.fileHardLinkWork,
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

        var timeout: Duration = .zero;
        if (wait) {
            // Don't block if we have completions waiting to be processed or timers fired
            if (!self.state.completions.empty() or !self.state.work_completions.empty() or timer_result.fired) {
                timeout = .zero;
            } else if (timer_result.next_timeout) |t| {
                // Use timer timeout, capped at max_wait
                timeout = if (t.value < self.max_wait.value) t else self.max_wait;
            } else {
                // No timers, wait for blocking I/O
                timeout = self.max_wait;
            }
        }

        // Skip backend poll in no_wait mode if there's nothing to retrieve.
        // This avoids syscall overhead for pure CPU-bound workloads.
        const should_poll = wait or self.state.inflight_io > 0;
        const wake_flags = self.state.wake_requested.swap(0, .acq_rel);
        const timed_out = if (should_poll) try self.backend.poll(&self.state, if (wake_flags != 0) .zero else timeout) else false;

        // Process async handles if the async bit was set
        if (wake_flags & LoopState.wake_async != 0) {
            self.processAsyncHandles();
        }

        // Process cross-thread cancel requests
        if (wake_flags & LoopState.wake_cancel != 0) {
            self.processCancelQueue();
        }

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
