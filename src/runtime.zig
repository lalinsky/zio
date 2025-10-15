const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const xev = @import("xev");

const meta = @import("meta.zig");

const coroutines = @import("coroutines.zig");
const Coroutine = coroutines.Coroutine;
const CoroutineState = coroutines.CoroutineState;

// const Error = coroutines.Error;
const RefCounter = @import("ref_counter.zig").RefCounter;
const FutureResult = @import("future_result.zig").FutureResult;
const stack_pool = @import("stack_pool.zig");
const StackPool = stack_pool.StackPool;
const StackPoolOptions = stack_pool.StackPoolOptions;

// Compile-time detection of whether the backend needs ThreadPool
fn backendNeedsThreadPool() bool {
    return @hasField(xev.Loop, "thread_pool");
}

/// Options for spawning a coroutine
pub const SpawnOptions = struct {
    stack_size: ?usize = null,
};

// Runtime configuration options
pub const RuntimeOptions = struct {
    thread_pool: ThreadPoolOptions = .{},
    stack_pool: StackPoolOptions = .{},

    pub const ThreadPoolOptions = struct {
        enabled: bool = backendNeedsThreadPool(),
        max_threads: ?u32 = null, // null = CPU count
        stack_size: ?u32 = null, // null = default stack size
    };
};

// Runtime-specific errors
pub const ZioError = error{
    XevError,
    NotInCoroutine,
};

// Cancelable error set
pub const Cancelable = error{
    Canceled,
};

// Timer callback for libxev
fn markReadyFromXevCallback(
    userdata: ?*Coroutine,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: anyerror!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result catch {};

    if (userdata) |coro| {
        Executor.fromCoroutine(coro).markReady(coro);
    }
    return .disarm;
}

// Noop callback for async timer cancellation
fn noopTimerCancelCallback(
    ud: ?*void,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = c;
    _ = r catch {};
    return .disarm;
}

// Thread pool callback for blocking tasks
fn threadPoolCallback(task: *xev.ThreadPool.Task) void {
    const any_blocking_task: *AnyBlockingTask = @fieldParentPtr("thread_pool_task", task);

    // Check if the task was canceled before it started executing
    if (!any_blocking_task.awaitable.canceled.load(.acquire)) {
        // Execute the user's blocking function only if not canceled
        any_blocking_task.execute_fn(any_blocking_task);
    }

    // Push to completion queue (thread-safe lock-free stack)
    // Even if canceled, we still mark as complete so waiters wake up
    const executor = &any_blocking_task.runtime.executor;
    executor.blocking_completions.push(&any_blocking_task.awaitable);

    // Wake up main loop
    executor.async_wakeup.notify() catch {};
}

// Async callback to drain completed blocking tasks
fn drainBlockingCompletions(
    executor: ?*Executor,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    _ = loop;
    _ = c;
    const self = executor.?;
    const runtime = self.runtime();

    // Atomically drain all completed blocking tasks (LIFO order)
    var drained = self.blocking_completions.popAll();
    while (drained.pop()) |awaitable| {
        // Mark awaitable as complete and wake all waiters (coroutines and threads)
        awaitable.markComplete();
        // Release the blocking task's reference (initial ref from init)
        runtime.releaseAwaitable(awaitable);
    }

    return .rearm;
}

// Awaitable kind - distinguishes different awaitable types
pub const AwaitableKind = enum {
    task,
    blocking_task,
    future,
    select_waiter,
};

// Awaitable - base type for anything that can be waited on
pub const Awaitable = struct {
    kind: AwaitableKind,
    next: ?*Awaitable = null,
    prev: ?*Awaitable = null,
    waiting_list: AwaitableList = .{},
    ref_count: RefCounter(u32) = RefCounter(u32).init(),
    destroy_fn: *const fn (*Runtime, *Awaitable) void,
    in_list: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

    // Universal state for both coroutines and threads
    // 0 = pending/not ready, 1 = complete/ready
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Cancellation flag - set to request cancellation, consumed by yield()
    canceled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Wait for this awaitable to complete. Works from both coroutines and threads.
    /// When called from a coroutine, suspends the coroutine.
    /// When called from a thread, parks the thread using futex.
    /// Returns error.Canceled if the coroutine was canceled during the wait.
    pub fn waitForComplete(self: *Awaitable) Cancelable!void {
        // Fast path: check if already complete
        const fast_state = self.state.load(.acquire);
        if (fast_state == 1) return;

        if (coroutines.getCurrent()) |current| {
            // Coroutine path: add to wait queue and suspend
            const task = AnyTask.fromCoroutine(current);

            // Check for self-join (would deadlock)
            if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
                if (&task.awaitable == self) {
                    std.debug.panic("cannot wait on self (would deadlock)", .{});
                }
            }
            self.waiting_list.push(&task.awaitable);

            // Double-check state before suspending (avoid lost wakeup)
            const double_check_state = self.state.load(.acquire);
            if (double_check_state == 1) {
                // Completed while we were adding to queue, remove ourselves
                _ = self.waiting_list.remove(&task.awaitable);
                return;
            }

            const executor = Executor.fromCoroutine(current);
            executor.yield(.waiting) catch |err| {
                // If yield itself was canceled, remove from wait list
                _ = self.waiting_list.remove(&task.awaitable);
                return err;
            };

            // Yield returned successfully, awaitable must be complete
        } else {
            // Thread path: park on the state using futex
            while (true) {
                const current_state = self.state.load(.acquire);
                if (current_state == 1) return;
                std.Thread.Futex.wait(&self.state, 0);
            }
        }
    }

    /// Wait for this awaitable to complete with a timeout. Works from both coroutines and threads.
    /// Returns error.Timeout if the timeout expires before completion.
    /// Returns error.Canceled if the coroutine was canceled during the wait.
    /// For coroutines, uses runtime timer infrastructure.
    /// For threads, uses futex timedWait directly.
    pub fn timedWaitForComplete(self: *Awaitable, timeout_ns: u64) error{ Timeout, Canceled }!void {
        // Fast path: check if already complete
        const fast_state = self.state.load(.acquire);
        if (fast_state == 1) return;

        if (coroutines.getCurrent()) |current| {
            // Coroutine path: get executor and use timer infrastructure
            const task = AnyTask.fromCoroutine(current);
            const executor = Executor.fromCoroutine(current);

            self.waiting_list.push(&task.awaitable);

            const double_check_state = self.state.load(.acquire);
            if (double_check_state == 1) {
                _ = self.waiting_list.remove(&task.awaitable);
                return;
            }

            const TimeoutContext = struct {
                wait_queue: *AwaitableList,
                awaitable: *Awaitable,
            };

            var timeout_ctx = TimeoutContext{
                .wait_queue = &self.waiting_list,
                .awaitable = &task.awaitable,
            };

            executor.timedWaitForReadyWithCallback(
                timeout_ns,
                TimeoutContext,
                &timeout_ctx,
                struct {
                    fn onTimeout(ctx: *TimeoutContext) bool {
                        return ctx.wait_queue.remove(ctx.awaitable);
                    }
                }.onTimeout,
            ) catch |err| {
                // Handle both timeout and cancellation from yield
                if (err == error.Canceled) {
                    _ = self.waiting_list.remove(&task.awaitable);
                }
                return err;
            };

            // Yield returned successfully, awaitable must be complete
        } else {
            // Thread path: use futex timedWait
            while (true) {
                const current_state = self.state.load(.acquire);
                if (current_state == 1) return;
                try std.Thread.Futex.timedWait(&self.state, 0, timeout_ns);
            }
        }
    }

    /// Mark this awaitable as complete and wake all waiters (both coroutines and threads).
    pub fn markComplete(self: *Awaitable) void {
        // Set state first (release semantics for memory ordering)
        self.state.store(1, .release);

        // Wake all waiting coroutines
        while (self.waiting_list.pop()) |waiting_awaitable| {
            switch (waiting_awaitable.kind) {
                .task => {
                    const waiting_task = AnyTask.fromAwaitable(waiting_awaitable);
                    const executor = Executor.fromCoroutine(&waiting_task.coro);
                    executor.markReady(&waiting_task.coro);
                },
                .select_waiter => {
                    // For select waiters, extract the SelectWaiter and wake the task directly
                    const waiter: *SelectWaiter = @fieldParentPtr("awaitable", waiting_awaitable);
                    waiter.ready = true;
                    const executor = Executor.fromCoroutine(&waiter.task.coro);
                    executor.markReady(&waiter.task.coro);
                },
                .blocking_task, .future => {
                    // These should not be in waiting lists of other awaitables
                    unreachable;
                },
            }
        }

        // Wake all waiting threads
        std.Thread.Futex.wake(&self.state, std.math.maxInt(u32));
    }

    /// Request cancellation of this awaitable.
    /// The cancellation flag will be consumed by the next yield() call.
    pub fn requestCancellation(self: *Awaitable) void {
        self.canceled.store(true, .release);
    }
};

// Task for runtime scheduling - coroutine-based tasks
pub const AnyTask = struct {
    awaitable: Awaitable,
    id: u64,
    coro: Coroutine,
    timer_c: xev.Completion = .{},
    timer_cancel_c: xev.Completion = .{},
    timer_generation: u2 = 0,
    shield_count: u32 = 0,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyTask {
        assert(awaitable.kind == .task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    pub inline fn fromCoroutine(coro: *Coroutine) *AnyTask {
        return @fieldParentPtr("coro", coro);
    }

    /// Request cancellation of this task.
    /// The cancellation flag will be checked at the next yield point.
    pub fn cancel(self: *AnyTask) void {
        self.awaitable.requestCancellation();
    }
};

// Blocking task for runtime scheduling - thread pool based tasks
pub const AnyBlockingTask = struct {
    awaitable: Awaitable,
    thread_pool_task: xev.ThreadPool.Task,
    runtime: *Runtime,
    execute_fn: *const fn (*AnyBlockingTask) void,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyBlockingTask {
        assert(awaitable.kind == .blocking_task);
        return @fieldParentPtr("awaitable", awaitable);
    }

    /// Request cancellation of this blocking task.
    /// If the task hasn't started executing yet, it will skip execution.
    /// If already executing, this has no effect (cannot stop blocking work).
    pub fn cancel(self: *AnyBlockingTask) void {
        self.awaitable.requestCancellation();
    }
};

// Future for runtime - not backed by computation, can be set from callbacks
pub const AnyFuture = struct {
    awaitable: Awaitable,
    runtime: *Runtime,

    pub inline fn fromAwaitable(awaitable: *Awaitable) *AnyFuture {
        assert(awaitable.kind == .future);
        return @fieldParentPtr("awaitable", awaitable);
    }
};

// Shared implementation for all Future types (Task, BlockingTask, Future)
fn FutureImpl(comptime T: type, comptime Base: type, comptime Parent: type) type {
    return struct {
        base: Base,
        future_result: FutureResult(T),

        pub fn wait(parent: *Parent) !meta.Payload(T) {
            // Check if already completed
            if (parent.impl.future_result.get()) |res| {
                return res;
            }

            // Wait for completion
            try parent.impl.base.awaitable.waitForComplete();

            return parent.impl.future_result.get().?;
        }

        pub fn cancel(parent: *Parent) void {
            parent.impl.base.awaitable.requestCancellation();
        }

        pub fn fromAny(base: *Base) *Parent {
            const impl_ptr: *@This() = @fieldParentPtr("base", base);
            return @fieldParentPtr("impl", impl_ptr);
        }

        pub fn fromAwaitable(awaitable: *Awaitable) *Parent {
            const base_ptr = Base.fromAwaitable(awaitable);
            return fromAny(base_ptr);
        }

        pub fn deinit(parent: *Parent) void {
            const runtime = Parent.getRuntime(parent);
            runtime.releaseAwaitable(&parent.impl.base.awaitable);
        }
    };
}

// Typed task that contains the AnyTask and FutureResult
pub fn Task(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyTask, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            const executor = Executor.fromCoroutine(&self.impl.base.coro);
            return executor.runtime();
        }

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_task = AnyTask.fromAwaitable(awaitable);
            const self = fromAny(any_task);
            // Stack should already be released when coroutine became dead, but check defensively
            if (any_task.coro.stack) |stack| {
                runtime.executor.stack_pool.release(stack);
            }
            runtime.allocator.destroy(self);
        }
    };
}

// Typed future that can be set from callbacks
pub fn Future(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyFuture, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        fn destroyFn(runtime: *Runtime, awaitable: *Awaitable) void {
            const any_future = AnyFuture.fromAwaitable(awaitable);
            const self = fromAny(any_future);
            runtime.allocator.destroy(self);
        }

        pub fn init(runtime: *Runtime, allocator: Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .impl = .{
                    .base = .{
                        .awaitable = .{
                            .kind = .future,
                            .destroy_fn = destroyFn,
                        },
                        .runtime = runtime,
                    },
                    .future_result = FutureResult(T){},
                },
            };

            // ref_count starts at 1 by default via RefCounter.init()

            return self;
        }

        pub fn set(self: *Self, value: T) void {
            const was_set = self.impl.future_result.set(value);
            if (!was_set) {
                // Value was already set, ignore
                return;
            }

            // Mark awaitable as complete and wake all waiters (coroutines and threads)
            self.impl.base.awaitable.markComplete();
        }
    };
}

// Typed blocking task that contains the AnyBlockingTask and FutureResult
pub fn BlockingTask(comptime T: type) type {
    return struct {
        const Self = @This();
        const Impl = FutureImpl(T, AnyBlockingTask, Self);

        impl: Impl,

        pub const deinit = Impl.deinit;
        pub const wait = Impl.wait;
        pub const cancel = Impl.cancel;
        pub const fromAny = Impl.fromAny;
        pub const fromAwaitable = Impl.fromAwaitable;

        pub fn getRuntime(self: *Self) *Runtime {
            return self.impl.base.runtime;
        }

        pub fn init(
            runtime: *Runtime,
            allocator: Allocator,
            func: anytype,
            args: meta.ArgsType(func),
        ) !*Self {
            const Args = @TypeOf(args);

            const TaskData = struct {
                blocking_task: Self,
                args: Args,

                fn execute(any_blocking_task: *AnyBlockingTask) void {
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);

                    const res = @call(.always_inline, func, self.args);
                    _ = self.blocking_task.impl.future_result.set(res);
                }

                fn destroy(rt: *Runtime, awaitable: *Awaitable) void {
                    const any_blocking_task = AnyBlockingTask.fromAwaitable(awaitable);
                    const blocking_task = Self.fromAny(any_blocking_task);
                    const self: *@This() = @fieldParentPtr("blocking_task", blocking_task);
                    rt.allocator.destroy(self);
                }
            };

            const task_data = try allocator.create(TaskData);
            errdefer allocator.destroy(task_data);

            task_data.* = .{
                .blocking_task = .{
                    .impl = .{
                        .base = .{
                            .awaitable = .{
                                .kind = .blocking_task,
                                .destroy_fn = &TaskData.destroy,
                            },
                            .thread_pool_task = .{ .callback = threadPoolCallback },
                            .runtime = runtime,
                            .execute_fn = &TaskData.execute,
                        },
                        .future_result = FutureResult(T){},
                    },
                },
                .args = args,
            };

            // Increment ref count for the JoinHandle
            task_data.blocking_task.impl.base.awaitable.ref_count.incr();

            runtime.executor.thread_pool.?.schedule(
                xev.ThreadPool.Batch.from(&task_data.blocking_task.impl.base.thread_pool_task),
            );

            return &task_data.blocking_task;
        }
    };
}

// Public handle for spawned tasks and futures
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        awaitable: *Awaitable,

        pub fn deinit(self: *Self) void {
            const runtime = switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).getRuntime(),
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).getRuntime(),
                .future => Future(T).fromAwaitable(self.awaitable).getRuntime(),
                .select_waiter => unreachable, // JoinHandles never point to select waiters
            };
            runtime.releaseAwaitable(self.awaitable);
        }

        pub fn join(self: *Self) !meta.Payload(T) {
            return switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).wait(),
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).wait(),
                .future => Future(T).fromAwaitable(self.awaitable).wait(),
                .select_waiter => unreachable, // JoinHandles never point to select waiters
            };
        }

        /// Check if the task has completed and a result is available.
        pub fn hasResult(self: *const Self) bool {
            return self.awaitable.state.load(.acquire) == 1;
        }

        /// Get the result value of type T (preserving any error union).
        /// Asserts that the task has already completed.
        /// This is used internally by select() to preserve error union types.
        fn getResult(self: *Self) T {
            assert(self.hasResult());

            // Get the stored result of type T
            return switch (self.awaitable.kind) {
                .task => Task(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .blocking_task => BlockingTask(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .future => Future(T).fromAwaitable(self.awaitable).impl.future_result.get().?,
                .select_waiter => unreachable,
            };
        }

        /// Request cancellation of this task.
        /// For coroutine tasks: Sets the cancellation flag, which will be checked at the next yield point.
        /// For blocking tasks: Sets the cancellation flag, which will skip execution if not yet started.
        /// For futures: Has no effect (futures are not cancelable).
        pub fn cancel(self: *Self) void {
            self.awaitable.requestCancellation();
        }

        /// Cast this JoinHandle to a different error set while keeping the same payload type.
        /// This is safe because all error sets have the same runtime representation (u16).
        /// The payload type must remain unchanged.
        /// This is a move operation - the original handle is consumed.
        ///
        /// Example: JoinHandle(MyError!i32) can be cast to JoinHandle(anyerror!i32)
        pub fn cast(self: Self, comptime T2: type) JoinHandle(T2) {
            const P1 = meta.Payload(T);
            const P2 = meta.Payload(T2);
            if (P1 != P2) {
                @compileError("cast() can only change error set, not payload type. " ++
                    "Source payload: " ++ @typeName(P1) ++ ", target payload: " ++ @typeName(P2));
            }

            return JoinHandle(T2){ .awaitable = self.awaitable };
        }
    };
}

/// Given a struct with each field a `JoinHandle(T)`, returns a union with the same
/// fields, each field type `T` (which may include error unions).
pub fn SelectUnion(comptime S: type) type {
    const struct_fields = @typeInfo(S).@"struct".fields;
    var fields: [struct_fields.len]std.builtin.Type.UnionField = undefined;
    for (&fields, struct_fields) |*union_field, struct_field| {
        // Extract T from JoinHandle(T)
        // struct_field.type is JoinHandle(T)
        const Handle = struct_field.type;
        // Handle.Result is T directly (may be an error union like ParseError!i32)
        const Result = Handle.Result;
        union_field.* = .{
            .name = struct_field.name,
            .type = Result,
            .alignment = struct_field.alignment,
        };
    }
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = std.meta.FieldEnum(S),
        .fields = &fields,
        .decls = &.{},
    } });
}

// Simple singly-linked stack (LIFO) for single-threaded use
pub const SimpleAwaitableStack = struct {
    head: ?*Awaitable = null,

    pub fn push(self: *SimpleAwaitableStack, item: *Awaitable) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!item.in_list);
            item.in_list = true;
        }
        item.next = self.head;
        self.head = item;
    }

    pub fn pop(self: *SimpleAwaitableStack) ?*Awaitable {
        const head = self.head orelse return null;
        if (builtin.mode == .Debug) {
            head.in_list = false;
        }
        self.head = head.next;
        head.next = null;
        return head;
    }

    /// Move all items from other stack to this stack (prepends).
    pub fn prependByMoving(self: *SimpleAwaitableStack, other: *SimpleAwaitableStack) void {
        const other_head = other.head orelse return;

        // Find tail of other stack
        var tail = other_head;
        while (tail.next) |next| {
            tail = next;
        }

        // Link tail to our current head
        tail.next = self.head;
        self.head = other_head;

        other.head = null;
    }
};

// Lock-free intrusive stack for cross-thread communication
pub const AwaitableStack = struct {
    head: std.atomic.Value(?*Awaitable) = std.atomic.Value(?*Awaitable).init(null),

    /// Push an item onto the stack. Thread-safe, can be called from any thread.
    pub fn push(self: *AwaitableStack, item: *Awaitable) void {
        while (true) {
            const current_head = self.head.load(.acquire);
            item.next = current_head;

            // Try to swing head to new item
            if (self.head.cmpxchgWeak(
                current_head,
                item,
                .release,
                .acquire,
            ) == null) {
                return; // Success!
            }
            // CAS failed, retry
        }
    }

    /// Atomically drain all items from the stack.
    /// Returns a SimpleAwaitableStack containing all drained items (LIFO order).
    pub fn popAll(self: *AwaitableStack) SimpleAwaitableStack {
        const head = self.head.swap(null, .acq_rel);
        return SimpleAwaitableStack{ .head = head };
    }
};

// Simple singly-linked list of awaitables
pub const AwaitableList = struct {
    head: ?*Awaitable = null,
    tail: ?*Awaitable = null,

    pub fn push(self: *AwaitableList, awaitable: *Awaitable) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(!awaitable.in_list);
            awaitable.in_list = true;
        }
        awaitable.next = null;
        if (self.tail) |tail| {
            tail.next = awaitable;
            awaitable.prev = tail;
            self.tail = awaitable;
        } else {
            awaitable.prev = null;
            self.head = awaitable;
            self.tail = awaitable;
        }
    }

    pub fn pop(self: *AwaitableList) ?*Awaitable {
        const head = self.head orelse return null;
        if (builtin.mode == .Debug) {
            head.in_list = false;
        }
        self.head = head.next;
        if (self.head) |new_head| {
            new_head.prev = null;
        } else {
            self.tail = null;
        }
        head.next = null;
        head.prev = null;
        return head;
    }

    pub fn concatByMoving(self: *AwaitableList, other: *AwaitableList) void {
        if (other.head == null) return;

        if (self.tail) |tail| {
            tail.next = other.head;
            if (other.head) |other_head| {
                other_head.prev = tail;
            }
            self.tail = other.tail;
        } else {
            self.head = other.head;
            self.tail = other.tail;
        }

        other.head = null;
        other.tail = null;
    }

    pub fn remove(self: *AwaitableList, awaitable: *Awaitable) bool {
        // Handle empty list
        if (self.head == null) return false;

        if (builtin.mode == .Debug) {
            std.debug.assert(awaitable.in_list);
            awaitable.in_list = false;
        }

        // Update prev node's next pointer (or head if removing first node)
        if (awaitable.prev) |prev_node| {
            prev_node.next = awaitable.next;
        } else {
            // No prev means this is the head
            self.head = awaitable.next;
        }

        // Update next node's prev pointer (or tail if removing last node)
        if (awaitable.next) |next_node| {
            next_node.prev = awaitable.prev;
        } else {
            // No next means this is the tail
            self.tail = awaitable.prev;
        }

        // Clear pointers
        awaitable.next = null;
        awaitable.prev = null;

        return true;
    }
};

// Executor metrics
pub const ExecutorMetrics = struct {
    yields: u64 = 0,
    tasks_spawned: u64 = 0,
    tasks_completed: u64 = 0,
};

// Executor - per-thread execution unit for running coroutines
pub const Executor = struct {
    loop: xev.Loop,
    thread_pool: ?*xev.ThreadPool, // Reference to Runtime's thread pool
    stack_pool: StackPool,
    count: u32 = 0,
    main_context: coroutines.Context,
    allocator: Allocator,

    tasks: std.AutoHashMapUnmanaged(u64, *AnyTask) = .{},

    ready_queue: SimpleAwaitableStack = .{},
    next_ready_queue: SimpleAwaitableStack = .{},

    // Blocking task support - lock-free LIFO stack
    blocking_completions: AwaitableStack = .{},
    async_wakeup: xev.Async = undefined,
    async_completion: xev.Completion = undefined,
    blocking_initialized: bool = false,

    // Stack pool cleanup tracking
    cleanup_interval_ms: i64,
    last_cleanup_ms: i64 = 0,

    // Runtime metrics
    metrics: ExecutorMetrics = .{},

    /// Get the Executor instance from any coroutine that belongs to it
    pub fn fromCoroutine(coro: *Coroutine) *Executor {
        return @fieldParentPtr("main_context", coro.parent_context_ptr);
    }

    /// Get the current Executor from within a coroutine
    pub fn getCurrent() ?*Executor {
        if (coroutines.getCurrent()) |coro| {
            return fromCoroutine(coro);
        }
        return null;
    }

    /// Get the Runtime instance from this Executor
    pub inline fn runtime(self: *Executor) *Runtime {
        return @fieldParentPtr("executor", self);
    }

    pub fn init(allocator: Allocator, thread_pool: ?*xev.ThreadPool, options: RuntimeOptions) !Executor {
        // Initialize libxev loop with optional ThreadPool
        const loop = try xev.Loop.init(.{
            .thread_pool = thread_pool,
        });

        return Executor{
            .allocator = allocator,
            .loop = loop,
            .thread_pool = thread_pool,
            .stack_pool = StackPool.init(allocator, options.stack_pool),
            .cleanup_interval_ms = options.stack_pool.cleanup_interval_ms,
            .main_context = undefined,
        };
    }

    pub fn deinit(self: *Executor) void {
        // Note: ThreadPool is owned by Runtime, not Executor

        const rt = self.runtime();
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const task = entry.value_ptr.*;
            rt.releaseAwaitable(&task.awaitable);
        }
        self.tasks.deinit(self.allocator);

        // Clean up blocking task support
        if (self.blocking_initialized) {
            self.async_wakeup.deinit();
        }

        self.loop.deinit();

        // Clean up stack pool
        self.stack_pool.deinit();
    }

    pub fn spawn(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        const debug_crash = false;
        if (debug_crash) {
            const v = @call(.always_inline, func, args);
            std.debug.print("Spawned task with ID {any}\n", .{v});
        }

        const id = self.count;
        self.count += 1;

        const entry = try self.tasks.getOrPut(self.allocator, id);
        if (entry.found_existing) {
            std.debug.panic("Task ID {} already exists", .{id});
        }
        errdefer self.tasks.removeByPtr(entry.key_ptr);

        const Result = meta.ReturnType(func);
        const TypedTask = Task(Result);

        const task = try self.allocator.create(TypedTask);
        errdefer self.allocator.destroy(task);

        // Acquire stack from pool
        const stack = try self.stack_pool.acquire(options.stack_size orelse coroutines.DEFAULT_STACK_SIZE);
        errdefer self.stack_pool.release(stack);

        task.* = .{
            .impl = .{
                .base = .{
                    .id = id,
                    .awaitable = .{
                        .kind = .task,
                        .destroy_fn = &TypedTask.destroyFn,
                    },
                    .coro = .{
                        .stack = stack,
                        .parent_context_ptr = &self.main_context,
                        .state = .ready,
                    },
                },
                .future_result = .{},
            },
        };

        task.impl.base.coro.setup(func, args, &task.impl.future_result);

        entry.value_ptr.* = &task.impl.base;

        self.ready_queue.push(&task.impl.base.awaitable);

        // Track task spawn
        self.metrics.tasks_spawned += 1;

        task.impl.base.awaitable.ref_count.incr();
        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    pub fn yield(self: *Executor, desired_state: CoroutineState) Cancelable!void {
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);

        // Track yield
        self.metrics.yields += 1;

        // Check and consume cancellation flag before yielding (unless shielded)
        if (current_task.shield_count == 0) {
            // cmpxchgStrong returns null on success, current value on failure
            if (current_task.awaitable.canceled.cmpxchgStrong(true, false, .acquire, .acquire) == null) {
                // CAS succeeded: we consumed true, return canceled
                return error.Canceled;
            }
        }

        current_coro.state = desired_state;
        if (desired_state == .ready) {
            self.next_ready_queue.push(&current_task.awaitable);
        }

        // If dead, always switch to scheduler for cleanup
        if (desired_state == .dead) {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
            unreachable;
        }

        if (self.ready_queue.pop()) |next_awaitable| {
            const next_task = AnyTask.fromAwaitable(next_awaitable);

            coroutines.setCurrent(&next_task.coro);
            coroutines.switchContext(&current_coro.context, &next_task.coro.context);
        } else {
            coroutines.switchContext(&current_coro.context, current_coro.parent_context_ptr);
        }

        std.debug.assert(coroutines.getCurrent() == current_coro);

        // Check again after resuming in case we were canceled while suspended (unless shielded)
        if (current_task.shield_count == 0) {
            if (current_task.awaitable.canceled.cmpxchgStrong(true, false, .acquire, .acquire) == null) {
                return error.Canceled;
            }
        }
    }

    /// Begin a cancellation shield.
    /// While shielded, yield() will not check or consume the cancellation flag.
    /// The flag remains set for when the shield ends.
    /// This is useful for cleanup operations (like close()) that must complete even if canceled.
    /// Must be paired with endShield().
    pub fn beginShield(self: *Executor) void {
        _ = self;
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        current_task.shield_count += 1;
    }

    /// End a cancellation shield.
    /// Must be paired with beginShield().
    pub fn endShield(self: *Executor) void {
        _ = self;
        const current_coro = coroutines.getCurrent() orelse unreachable;
        const current_task = AnyTask.fromCoroutine(current_coro);
        std.debug.assert(current_task.shield_count > 0);
        current_task.shield_count -= 1;
    }

    pub inline fn awaitablePtrFromTaskPtr(task: *AnyTask) *Awaitable {
        return &task.awaitable;
    }

    pub fn sleep(self: *Executor, milliseconds: u64) void {
        self.timedWaitForReady(milliseconds * 1_000_000) catch return;
        unreachable; // Should always timeout - waking without timeout is a bug
    }

    fn ensureBlockingInitialized(self: *Executor) !void {
        if (self.blocking_initialized) return;
        if (self.thread_pool == null) return error.ThreadPoolRequired;

        self.async_wakeup = try xev.Async.init();

        // Register async completion to drain blocking tasks
        self.async_wakeup.wait(
            &self.loop,
            &self.async_completion,
            Executor,
            self,
            drainBlockingCompletions,
        );

        self.blocking_initialized = true;
    }

    pub fn spawnBlocking(
        self: *Executor,
        func: anytype,
        args: meta.ArgsType(func),
    ) !JoinHandle(meta.ReturnType(func)) {
        try self.ensureBlockingInitialized();

        const Result = meta.ReturnType(func);
        const task = try BlockingTask(Result).init(
            self.runtime(),
            self.allocator,
            func,
            args,
        );

        return JoinHandle(Result){ .awaitable = &task.impl.base.awaitable };
    }

    /// Convenience function that spawns a task, runs the event loop until completion, and returns the result.
    /// This is equivalent to: `spawn()` + `run()` + `result()`, but in a single call.
    /// Returns an error union that includes errors from `spawn()`, `run()`, and the task itself.
    pub fn runUntilComplete(self: *Executor, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        var handle = try self.spawn(func, args, options);
        defer handle.deinit();
        try self.run();
        return handle.join();
    }

    pub fn run(self: *Executor) !void {
        while (true) {
            // Time-based stack pool cleanup
            const now = std.time.milliTimestamp();
            if (now - self.last_cleanup_ms >= self.cleanup_interval_ms) {
                self.stack_pool.cleanup();
                self.last_cleanup_ms = now;
            }

            // Process all ready coroutines (once)
            while (self.ready_queue.pop()) |awaitable| {
                const task = AnyTask.fromAwaitable(awaitable);

                coroutines.setCurrent(&task.coro);
                defer coroutines.clearCurrent();
                coroutines.switchContext(&self.main_context, &task.coro.context);

                // Handle dead coroutines (checks getCurrent() to catch tasks that died via direct switch in yield())
                if (coroutines.getCurrent()) |current_coro| {
                    if (current_coro.state == .dead) {
                        const current_task = AnyTask.fromCoroutine(current_coro);
                        const current_awaitable = &current_task.awaitable;

                        // Release stack immediately since coroutine execution is complete
                        if (current_coro.stack) |stack| {
                            self.stack_pool.release(stack);
                            current_coro.stack = null;
                        }

                        // Mark awaitable as complete and wake all waiters (coroutines and threads)
                        current_awaitable.markComplete();

                        // Track task completion
                        self.metrics.tasks_completed += 1;

                        // Remove from tasks hashmap and release runtime's reference
                        _ = self.tasks.remove(current_task.id);
                        self.runtime().releaseAwaitable(current_awaitable);
                        // If ref_count > 0, Task(T) handles still exist, keep the task alive
                    }
                }

                // Other states (.ready, .waiting) are handled by yield() or markReady()
            }

            // Move yielded coroutines back to ready queue
            self.ready_queue.prependByMoving(&self.next_ready_queue);

            // If we have no active coroutines, exit
            if (self.tasks.size == 0) {
                self.loop.stop();
                break;
            }

            // Check for I/O events without blocking if we have pending work
            const mode: xev.RunMode = if (self.ready_queue.head != null or self.next_ready_queue.head != null)
                .no_wait
            else
                .once;

            try self.loop.run(mode);
        }
    }

    pub fn markReady(self: *Executor, coro: *Coroutine) void {
        if (coro.state != .waiting) std.debug.panic("coroutine is not waiting", .{});
        coro.state = .ready;
        const task = AnyTask.fromCoroutine(coro);
        self.ready_queue.push(&task.awaitable);
    }

    /// Get a copy of the current metrics
    pub fn getMetrics(self: *Executor) ExecutorMetrics {
        return self.metrics;
    }

    /// Reset all metrics to zero
    pub fn resetMetrics(self: *Executor) void {
        self.metrics = .{};
    }

    pub fn wait(self: *Executor, task_id: u64) Cancelable!void {
        const task = self.tasks.get(task_id) orelse return;
        if (task.coro.state == .dead) {
            return;
        }
        const current_coro = coroutines.getCurrent() orelse std.debug.panic("not in coroutine", .{});
        const current_task = AnyTask.fromCoroutine(current_coro);
        if (current_task == task) {
            std.debug.panic("a task cannot wait on itself", .{});
        }
        task.awaitable.waiting_list.push(&current_task.awaitable);
        self.yield(.waiting) catch |err| {
            // On cancellation, remove from wait queue
            _ = task.awaitable.waiting_list.remove(&current_task.awaitable);
            return err;
        };
    }

    /// Pack a pointer and 2-bit generation into a tagged pointer for userdata.
    /// Uses lower 2 bits for generation (pointers are aligned).
    inline fn packTimerUserdata(comptime T: type, ptr: *T, generation: u2) ?*anyopaque {
        const addr = @intFromPtr(ptr);
        const tagged = addr | @as(usize, generation);
        return @ptrFromInt(tagged);
    }

    /// Unpack a tagged pointer into the original pointer and generation.
    inline fn unpackTimerUserdata(comptime T: type, userdata: ?*anyopaque) struct { ptr: *T, generation: u2 } {
        const addr = @intFromPtr(userdata);
        const generation: u2 = @truncate(addr & 0x3);
        const ptr_addr = addr & ~@as(usize, 0x3);
        return .{
            .ptr = @ptrFromInt(ptr_addr),
            .generation = generation,
        };
    }

    /// Wait for the current coroutine to be marked ready, with a timeout and custom timeout handler.
    /// The onTimeout callback is called when the timer fires, and should return true if the
    /// coroutine should be woken with error.Timeout, or false if it was already signaled by
    /// another source (in which case the timeout is ignored).
    pub fn timedWaitForReadyWithCallback(
        self: *Executor,
        timeout_ns: u64,
        comptime TimeoutContext: type,
        timeout_ctx: *TimeoutContext,
        comptime onTimeout: fn (ctx: *TimeoutContext) bool,
    ) error{ Timeout, Canceled }!void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task = AnyTask.fromCoroutine(current);

        const CallbackContext = struct {
            user_ctx: *TimeoutContext,
            timed_out: bool,
        };

        var ctx = CallbackContext{
            .user_ctx = timeout_ctx,
            .timed_out = false,
        };

        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        // Use timer reset which handles both initial start and restart after cancel
        // Pack context pointer with generation in lower 2 bits
        const tagged_userdata = packTimerUserdata(CallbackContext, &ctx, task.timer_generation);
        timer.reset(
            &self.loop,
            &task.timer_c,
            &task.timer_cancel_c,
            timeout_ns / 1_000_000,
            anyopaque,
            tagged_userdata,
            struct {
                fn callback(
                    userdata: ?*anyopaque,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    _ = l;
                    _ = r catch {};

                    // Get task safely from completion (always valid)
                    const t: *AnyTask = @fieldParentPtr("timer_c", c);

                    // Unpack generation from tagged pointer (no deref yet!)
                    const unpacked = unpackTimerUserdata(CallbackContext, userdata);

                    // Check if this callback is from a stale timer
                    if (t.timer_generation != unpacked.generation) {
                        // Stale callback - context is freed, don't touch it!
                        return .disarm;
                    }

                    // Generation matches - safe to dereference context
                    const ctx_ptr = unpacked.ptr;
                    if (onTimeout(ctx_ptr.user_ctx)) {
                        ctx_ptr.timed_out = true;
                        Executor.fromCoroutine(&t.coro).markReady(&t.coro);
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Wait for either timeout or external markReady
        self.yield(.waiting) catch |err| {
            // Invalidate pending callbacks before unwinding so they ignore this stack frame.
            task.timer_generation +%= 1;
            timer.cancel(
                &self.loop,
                &task.timer_c,
                &task.timer_cancel_c,
                void,
                null,
                noopTimerCancelCallback,
            );
            return err;
        };

        if (ctx.timed_out) {
            return error.Timeout;
        }

        // Timer already completed, no need to cancel
        if (task.timer_c.state() == .dead) {
            return;
        }

        // Was awakened by external markReady → increment generation to invalidate
        // any pending timer callback, then cancel async
        task.timer_generation +%= 1;
        timer.cancel(
            &self.loop,
            &task.timer_c,
            &task.timer_cancel_c,
            void,
            null,
            noopTimerCancelCallback,
        );
    }

    pub fn timedWaitForReady(self: *Executor, timeout_ns: u64) error{ Timeout, Canceled }!void {
        const DummyContext = struct {};
        var dummy: DummyContext = .{};
        return self.timedWaitForReadyWithCallback(
            timeout_ns,
            DummyContext,
            &dummy,
            struct {
                fn onTimeout(_: *DummyContext) bool {
                    return true;
                }
            }.onTimeout,
        );
    }

    /// Wait for an xev completion to finish, handling cancellation properly.
    /// When a coroutine is canceled while waiting for an I/O operation,
    /// we need to cancel the operation (if the backend supports it) and
    /// wait for it to complete before returning error.Canceled.
    /// This prevents use-after-free bugs where the xev callback accesses
    /// freed stack memory.
    ///
    /// Returns error.Canceled if the operation was canceled.
    pub fn waitForXevCompletion(
        self: *Executor,
        completion: *xev.Completion,
    ) Cancelable!void {
        var was_canceled = false;
        var cancel_completion: xev.Completion = .{};

        while (completion.state() != .dead) {
            self.yield(.waiting) catch |err| switch (err) {
                error.Canceled => {
                    // First cancellation - try to cancel the xev operation
                    if (!was_canceled) {
                        was_canceled = true;

                        if (xev.backend == .io_uring) {
                            // io_uring supports cancellation - request cancellation
                            self.loop.cancel(
                                completion,
                                &cancel_completion,
                                void,
                                null,
                                struct {
                                    fn callback(
                                        _: ?*void,
                                        _: *xev.Loop,
                                        _: *xev.Completion,
                                        _: xev.CancelError!void,
                                    ) xev.CallbackAction {
                                        // We don't need to do anything here - the original
                                        // completion callback will fire and wake us up
                                        return .disarm;
                                    }
                                }.callback,
                            );
                        }
                        // For non-io_uring backends, just continue waiting for completion
                    }
                    // Continue waiting for the operation to complete
                },
            };
        }

        // Operation completed - return cancellation error if we were canceled
        if (was_canceled) {
            return error.Canceled;
        }
    }
};

// SelectWaiter - used by Runtime.select to wait on multiple handles
pub const SelectWaiter = struct {
    awaitable: Awaitable,
    task: *AnyTask,
    ready: bool = false,
};

// Runtime - orchestrator that wraps a single Executor (for now)
pub const Runtime = struct {
    executor: Executor,
    thread_pool: ?*xev.ThreadPool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, options: RuntimeOptions) !Runtime {
        // Initialize ThreadPool if enabled (shared resource)
        var thread_pool: ?*xev.ThreadPool = null;
        if (options.thread_pool.enabled) {
            thread_pool = try allocator.create(xev.ThreadPool);

            var config = xev.ThreadPool.Config{};
            if (options.thread_pool.max_threads) |max| config.max_threads = max;
            if (options.thread_pool.stack_size) |size| config.stack_size = size;
            thread_pool.?.* = xev.ThreadPool.init(config);
        }
        errdefer if (thread_pool) |tp| {
            tp.shutdown();
            tp.deinit();
            allocator.destroy(tp);
        };

        const executor = try Executor.init(allocator, thread_pool, options);
        errdefer executor.deinit();

        return Runtime{
            .executor = executor,
            .thread_pool = thread_pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Runtime) void {
        // Shutdown ThreadPool before cleaning up executor
        if (self.thread_pool) |tp| {
            tp.shutdown();
        }

        self.executor.deinit();

        // Clean up ThreadPool after executor
        if (self.thread_pool) |tp| {
            tp.deinit();
            self.allocator.destroy(tp);
        }
    }

    // High-level public API - delegates to Executor
    pub fn spawn(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !JoinHandle(meta.ReturnType(func)) {
        return self.executor.spawn(func, args, options);
    }

    pub fn spawnBlocking(self: *Runtime, func: anytype, args: meta.ArgsType(func)) !JoinHandle(meta.ReturnType(func)) {
        return self.executor.spawnBlocking(func, args);
    }

    pub fn run(self: *Runtime) !void {
        return self.executor.run();
    }

    pub fn runUntilComplete(self: *Runtime, func: anytype, args: meta.ArgsType(func), options: SpawnOptions) !meta.Payload(meta.ReturnType(func)) {
        return self.executor.runUntilComplete(func, args, options);
    }

    // Convenience methods that operate on the current coroutine context
    // These delegate to the current executor automatically
    // Most are no-op if not called from within a coroutine

    /// Cooperatively yield control to allow other tasks to run.
    /// The current task will be rescheduled and continue execution later.
    /// No-op if not called from within a coroutine.
    pub fn yield(self: *Runtime) Cancelable!void {
        _ = self;
        const executor = Executor.getCurrent() orelse return;
        return executor.yield(.ready);
    }

    /// Sleep for the specified number of milliseconds.
    /// Uses async sleep if in a coroutine, blocking sleep otherwise.
    pub fn sleep(self: *Runtime, milliseconds: u64) void {
        _ = self;
        if (Executor.getCurrent()) |executor| {
            executor.sleep(milliseconds);
        } else {
            // Not in coroutine - use blocking sleep
            std.Thread.sleep(milliseconds * std.time.ns_per_ms);
        }
    }

    /// Begin a cancellation shield to prevent cancellation during critical sections.
    /// No-op if not called from within a coroutine.
    pub fn beginShield(self: *Runtime) void {
        _ = self;
        const executor = Executor.getCurrent() orelse return;
        return executor.beginShield();
    }

    /// End a cancellation shield.
    /// No-op if not called from within a coroutine.
    pub fn endShield(self: *Runtime) void {
        _ = self;
        const executor = Executor.getCurrent() orelse return;
        return executor.endShield();
    }

    pub fn getCurrent() ?*Runtime {
        if (Executor.getCurrent()) |executor| {
            return @fieldParentPtr("executor", executor);
        }
        return null;
    }

    /// Get a copy of the current executor metrics
    pub fn getMetrics(self: *Runtime) ExecutorMetrics {
        return self.executor.getMetrics();
    }

    /// Reset all executor metrics to zero
    pub fn resetMetrics(self: *Runtime) void {
        self.executor.resetMetrics();
    }

    fn releaseAwaitable(self: *Runtime, awaitable: *Awaitable) void {
        if (awaitable.ref_count.decr()) {
            awaitable.destroy_fn(self, awaitable);
        }
    }

    /// Wait for multiple JoinHandles simultaneously and return whichever completes first.
    /// `handles` is a struct with each field a `JoinHandle(T)`, where `T` can be different for each field.
    /// Returns a tagged union with the same field names, containing the result of whichever completed first.
    ///
    /// Example:
    /// ```
    /// var h1 = try rt.spawn(task1, .{}, .{});
    /// var h2 = try rt.spawn(task2, .{}, .{});
    /// const result = rt.select(.{ .first = h1, .second = h2 });
    /// switch (result) {
    ///     .first => |val| ...,
    ///     .second => |val| ...,
    /// }
    /// ```
    pub fn select(self: *Runtime, handles: anytype) !SelectUnion(@TypeOf(handles)) {
        _ = self;
        const U = SelectUnion(@TypeOf(handles));
        const S = @TypeOf(handles);
        const fields = @typeInfo(S).@"struct".fields;

        // Fast path: check if any handle is already complete
        inline for (fields) |field| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // Already complete, return immediately
                return @unionInit(U, field.name, handle.getResult());
            }
        }

        // Multi-wait path: Create separate waiter awaitables for each handle
        // We can't add the same awaitable to multiple lists (next/prev pointers conflict)
        const current_coro = coroutines.getCurrent() orelse return error.NotInCoroutine;
        const current_task = AnyTask.fromCoroutine(current_coro);
        const executor = Executor.fromCoroutine(current_coro);

        // Create waiter structures on the stack
        var waiters: [fields.len]SelectWaiter = undefined;
        inline for (&waiters, 0..) |*waiter, i| {
            waiter.* = .{
                .awaitable = .{
                    .kind = .select_waiter,
                    .destroy_fn = struct {
                        fn dummy(_: *Runtime, _: *Awaitable) void {}
                    }.dummy,
                },
                .task = current_task,
            };
            _ = i; // Will use below
        }

        // Add waiters to all waiting lists
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            handle.awaitable.waiting_list.push(&waiters[i].awaitable);
        }

        // Clean up waiters on all exit paths (skip waiters marked ready by markComplete)
        defer {
            inline for (0..fields.len) |i| {
                if (!waiters[i].ready) {
                    var h = @field(handles, fields[i].name);
                    _ = h.awaitable.waiting_list.remove(&waiters[i].awaitable);
                }
            }
        }

        // Double-check for completion (race condition prevention)
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // Completed while we were adding to lists, defer will clean up
                return @unionInit(U, field.name, handle.getResult());
            }
            _ = i;
        }

        // Yield and wait for one to complete
        try executor.yield(.waiting);

        // We were woken up - find which one completed
        inline for (fields, 0..) |field, i| {
            var handle = @field(handles, field.name);
            if (handle.hasResult()) {
                // This one completed, defer will clean up all non-ready waiters
                return @unionInit(U, field.name, handle.getResult());
            }
            _ = i;
        }

        // Should never reach here - we were woken up, so something must be complete
        unreachable;
    }
};

test "runtime with thread pool smoke test" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    // Verify ThreadPool was created
    testing.expect(runtime.thread_pool != null) catch |err| {
        std.debug.print("ThreadPool was not created when enabled\n", .{});
        return err;
    };

    // Run empty runtime (should exit immediately)
    try runtime.run();
}

test "runtime: spawnBlocking smoke test" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{
        .thread_pool = .{ .enabled = true },
    });
    defer runtime.deinit();

    const TestContext = struct {
        fn blockingWork(x: i32) i32 {
            return x * 2;
        }

        fn asyncTask(rt: *Runtime) !void {
            var handle = try rt.spawnBlocking(blockingWork, .{21});
            defer handle.deinit();

            const result = try handle.join();
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future basic set and get" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Set value
            future.set(42);

            // Get value (should return immediately since already set)
            const result = try future.wait();
            try testing.expectEqual(@as(i32, 42), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future await from coroutine" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn setterTask(future: *Future(i32)) !void {
            // Simulate async work
            const rt = Runtime.getCurrent().?;
            try rt.yield();
            try rt.yield();
            future.set(123);
        }

        fn getterTask(future: *Future(i32)) !i32 {
            // This will block until setter sets the value
            return future.wait();
        }

        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Spawn setter coroutine
            var setter_handle = try rt.spawn(setterTask, .{future}, .{});
            defer setter_handle.deinit();

            // Spawn getter coroutine
            var getter_handle = try rt.spawn(getterTask, .{future}, .{});
            defer getter_handle.deinit();

            const result = try getter_handle.join();
            try testing.expectEqual(@as(i32, 123), result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: Future multiple waiters" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();
    const TestContext = struct {
        fn waiterTask(future: *Future(i32), expected: i32) !void {
            const result = try future.wait();
            try testing.expectEqual(expected, result);
        }

        fn setterTask(future: *Future(i32)) !void {
            // Let waiters block first
            const rt = Runtime.getCurrent().?;
            try rt.yield();
            try rt.yield();
            future.set(999);
        }

        fn asyncTask(rt: *Runtime) !void {
            const future = try Future(i32).init(rt, testing.allocator);
            defer future.deinit();

            // Spawn multiple waiters
            var waiter1 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter1.deinit();
            var waiter2 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter2.deinit();
            var waiter3 = try rt.spawn(waiterTask, .{ future, @as(i32, 999) }, .{});
            defer waiter3.deinit();

            // Spawn setter
            var setter = try rt.spawn(setterTask, .{future}, .{});
            defer setter.deinit();

            try rt.yield();
            try rt.yield();
            try rt.yield();
            try rt.yield();

            try waiter1.join();
            try waiter2.join();
            try waiter3.join();
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select basic - first completes" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(50);
            return 42;
        }

        fn fastTask() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(10);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var slow = try rt.spawn(slowTask, .{}, .{});
            defer slow.deinit();
            var fast = try rt.spawn(fastTask, .{}, .{});
            defer fast.deinit();

            const result = try rt.select(.{ .slow = slow, .fast = fast });
            switch (result) {
                .slow => |val| try testing.expectEqual(@as(i32, 42), val),
                .fast => |val| try testing.expectEqual(@as(i32, 99), val),
            }
            // Fast should win
            try testing.expectEqual(std.meta.Tag(@TypeOf(result)).fast, std.meta.activeTag(result));
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select already complete - fast path" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn immediateTask() i32 {
            return 123;
        }

        fn slowTask() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(100);
            return 456;
        }

        fn asyncTask(rt: *Runtime) !void {
            var immediate = try rt.spawn(immediateTask, .{}, .{});
            defer immediate.deinit();

            // Give immediate task a chance to complete
            try rt.yield();
            try rt.yield();

            var slow = try rt.spawn(slowTask, .{}, .{});
            defer slow.deinit();

            // immediate should already be complete, select should return immediately
            const result = try rt.select(.{ .immediate = immediate, .slow = slow });
            switch (result) {
                .immediate => |val| try testing.expectEqual(@as(i32, 123), val),
                .slow => return error.TestUnexpectedResult,
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select heterogeneous types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn intTask() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(20);
            return 42;
        }

        fn stringTask() []const u8 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(10);
            return "hello";
        }

        fn boolTask() bool {
            const rt = Runtime.getCurrent().?;
            rt.sleep(30);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var int_handle = try rt.spawn(intTask, .{}, .{});
            defer int_handle.deinit();
            var string_handle = try rt.spawn(stringTask, .{}, .{});
            defer string_handle.deinit();
            var bool_handle = try rt.spawn(boolTask, .{}, .{});
            defer bool_handle.deinit();

            const result = try rt.select(.{
                .int = int_handle,
                .string = string_handle,
                .bool = bool_handle,
            });

            switch (result) {
                .int => |val| {
                    try testing.expectEqual(@as(i32, 42), val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
                .string => |val| {
                    try testing.expectEqualStrings("hello", val);
                    // This should win
                },
                .bool => |val| {
                    try testing.expectEqual(true, val);
                    return error.TestUnexpectedResult; // Should not complete first
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with cancellation" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        fn slowTask1() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(1000);
            return 1;
        }

        fn slowTask2() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(1000);
            return 2;
        }

        fn selectTask() !i32 {
            const rt = Runtime.getCurrent().?;
            var h1 = try rt.spawn(slowTask1, .{}, .{});
            defer h1.deinit();
            var h2 = try rt.spawn(slowTask2, .{}, .{});
            defer h2.deinit();

            const result = try rt.select(.{ .first = h1, .second = h2 });
            return switch (result) {
                .first => |v| v,
                .second => |v| v,
            };
        }

        fn asyncTask(rt: *Runtime) !void {
            var select_handle = try rt.spawn(selectTask, .{}, .{});
            defer select_handle.deinit();

            // Give it a chance to start waiting
            try rt.yield();
            try rt.yield();

            // Cancel the select operation
            select_handle.cancel();

            // Should return error.Canceled
            const result = select_handle.join();
            try testing.expectError(error.Canceled, result);
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with error unions - success case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const ValidationError = error{ TooShort, TooLong };

        fn parseTask() ParseError!i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(20);
            return 42;
        }

        fn validateTask() ValidationError![]const u8 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(10);
            return "valid";
        }

        fn asyncTask(rt: *Runtime) !void {
            var parse_handle = try rt.spawn(parseTask, .{}, .{});
            defer parse_handle.deinit();
            var validate_handle = try rt.spawn(validateTask, .{}, .{});
            defer validate_handle.deinit();

            const result = try rt.select(.{
                .validate = validate_handle,
                .parse = parse_handle,
            });

            // Result is a union where each field has the original error type
            switch (result) {
                .parse => |val_or_err| {
                    // val_or_err is ParseError!i32
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqual(@as(i32, 42), val);
                    return error.TestUnexpectedResult; // validate should win
                },
                .validate => |val_or_err| {
                    // val_or_err is ValidationError![]const u8
                    const val = val_or_err catch |err| {
                        try testing.expect(false); // Should not error
                        return err;
                    };
                    try testing.expectEqualStrings("valid", val);
                    // This should win
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with error unions - error case" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };

        fn failingTask() ParseError!i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(10);
            return error.OutOfRange;
        }

        fn slowTask() i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(100);
            return 99;
        }

        fn asyncTask(rt: *Runtime) !void {
            var failing = try rt.spawn(failingTask, .{}, .{});
            defer failing.deinit();
            var slow = try rt.spawn(slowTask, .{}, .{});
            defer slow.deinit();

            const result = try rt.select(.{ .failing = failing, .slow = slow });

            switch (result) {
                .failing => |val_or_err| {
                    // val_or_err is ParseError!i32
                    _ = val_or_err catch |err| {
                        // Should receive the original error
                        try testing.expectEqual(ParseError.OutOfRange, err);
                        return;
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .slow => |val| {
                    try testing.expectEqual(@as(i32, 99), val);
                    return error.TestUnexpectedResult; // failing should win
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: select with mixed error types" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const ParseError = error{ InvalidFormat, OutOfRange };
        const IOError = error{ FileNotFound, PermissionDenied };

        fn task1() ParseError!i32 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(30);
            return 100;
        }

        fn task2() IOError![]const u8 {
            const rt = Runtime.getCurrent().?;
            rt.sleep(10);
            return error.FileNotFound;
        }

        fn task3() bool {
            const rt = Runtime.getCurrent().?;
            rt.sleep(50);
            return true;
        }

        fn asyncTask(rt: *Runtime) !void {
            var h1 = try rt.spawn(task1, .{}, .{});
            defer h1.deinit();
            var h2 = try rt.spawn(task2, .{}, .{});
            defer h2.deinit();
            var h3 = try rt.spawn(task3, .{}, .{});
            defer h3.deinit();

            // rt.select returns Cancelable!SelectUnion(...)
            // SelectUnion has: { .h1: ParseError!i32, .h2: IOError![]const u8, .h3: bool }
            const result = try rt.select(.{ .h1 = h1, .h2 = h2, .h3 = h3 });

            switch (result) {
                .h1 => |val_or_err| {
                    _ = val_or_err catch return error.TestUnexpectedResult;
                    return error.TestUnexpectedResult;
                },
                .h2 => |val_or_err| {
                    // val_or_err is IOError![]const u8
                    _ = val_or_err catch |err| {
                        // Verify we got the original error type
                        try testing.expectEqual(IOError.FileNotFound, err);
                        return; // This is expected
                    };
                    return error.TestUnexpectedResult; // Should have errored
                },
                .h3 => |val| {
                    try testing.expectEqual(true, val);
                    return error.TestUnexpectedResult;
                },
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}

test "runtime: JoinHandle.cast() error set conversion" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const TestContext = struct {
        const MyError = error{ Foo, Bar };

        fn taskSuccess() MyError!i32 {
            return 42;
        }

        fn taskError() MyError!i32 {
            return error.Foo;
        }

        fn asyncTask(rt: *Runtime) !void {
            // Test casting success case
            {
                var handle = try rt.spawn(taskSuccess, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.deinit();

                const result = try casted.join();
                try testing.expectEqual(@as(i32, 42), result);
            }

            // Test casting error case
            {
                var handle = try rt.spawn(taskError, .{}, .{});
                var casted = handle.cast(anyerror!i32);
                defer casted.deinit();

                const result = casted.join();
                try testing.expectError(error.Foo, result);
            }
        }
    };

    try runtime.runUntilComplete(TestContext.asyncTask, .{&runtime}, .{});
}
