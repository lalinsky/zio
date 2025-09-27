const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const coroutines = @import("coroutines.zig");
const AnyTaskList = @import("runtime.zig").AnyTaskList;
const xev = @import("xev");

pub const Mutex = struct {
    owner: std.atomic.Value(?*coroutines.Coroutine) = std.atomic.Value(?*coroutines.Coroutine).init(null),
    wait_queue: AnyTaskList = .{},
    runtime: *Runtime,

    pub fn init(runtime: *Runtime) Mutex {
        return .{ .runtime = runtime };
    }

    pub fn tryLock(self: *Mutex) bool {
        const current = coroutines.getCurrent() orelse return false;

        // Try to atomically set owner from null to current
        return self.owner.cmpxchgStrong(null, current, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;

        // Fast path: try to acquire unlocked mutex
        if (self.tryLock()) return;

        // Slow path: add current task to wait queue and suspend
        const task_node = Runtime.taskPtrFromCoroPtr(current);
        self.wait_queue.append(task_node);

        // Suspend until woken by unlock()
        current.waitForReady();

        // When we wake up, unlock() has already transferred ownership to us
        std.debug.assert(self.owner.load(.monotonic) == current);
    }

    pub fn unlock(self: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        std.debug.assert(self.owner.load(.monotonic) == current);

        // Check if there are waiters
        if (self.wait_queue.pop()) |task_node| {
            // Transfer ownership directly to next waiter
            self.owner.store(&task_node.coro, .release);
            // Wake them up (they already own the lock)
            self.runtime.markReady(&task_node.coro);
        } else {
            // No waiters, release the lock completely
            self.owner.store(null, .release);
        }
    }
};

pub const Condition = struct {
    wait_queue: AnyTaskList = .{},
    runtime: *Runtime,

    pub fn init(runtime: *Runtime) Condition {
        return .{ .runtime = runtime };
    }

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task_node = Runtime.taskPtrFromCoroPtr(current);

        // Add to wait queue before releasing mutex
        self.wait_queue.append(task_node);

        // Atomically release mutex and wait
        mutex.unlock();
        current.waitForReady();

        // Re-acquire mutex after waking
        mutex.lock();
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        const current = coroutines.getCurrent() orelse unreachable;
        const task_node = Runtime.taskPtrFromCoroPtr(current);

        self.wait_queue.append(task_node);

        // Setup timer for timeout
        var timed_out = false;
        var timer = xev.Timer.init() catch unreachable;
        defer timer.deinit();

        const TimeoutContext = struct {
            runtime: *Runtime,
            condition: *Condition,
            task_node: *AnyTaskList.Node,
            coroutine: *coroutines.Coroutine,
            timed_out: *bool,
        };

        var timeout_ctx = TimeoutContext{
            .runtime = self.runtime,
            .condition = self,
            .task_node = task_node,
            .coroutine = current,
            .timed_out = &timed_out,
        };

        var completion: xev.Completion = undefined;
        timer.run(
            &self.runtime.loop,
            &completion,
            timeout_ns / 1_000_000, // Convert to ms
            TimeoutContext,
            &timeout_ctx,
            struct {
                fn callback(
                    ctx: ?*TimeoutContext,
                    loop: *xev.Loop,
                    c: *xev.Completion,
                    result: anyerror!void,
                ) xev.CallbackAction {
                    _ = loop;
                    _ = c;
                    _ = result catch {};
                    if (ctx) |context| {
                        if (context.condition.wait_queue.remove(context.task_node)) {
                            context.timed_out.* = true;
                            context.runtime.markReady(context.coroutine);
                        }
                    }
                    return .disarm;
                }
            }.callback,
        );

        // Release mutex and wait
        mutex.unlock();
        current.waitForReady();

        // Re-acquire mutex first
        mutex.lock();

        // Then check if we timed out and cleanup if needed
        if (timed_out) {
            return error.Timeout;
        }
    }

    pub fn signal(self: *Condition) void {
        if (self.wait_queue.pop()) |task_node| {
            self.runtime.markReady(&task_node.coro);
        }
    }

    pub fn broadcast(self: *Condition) void {
        while (self.wait_queue.pop()) |task_node| {
            self.runtime.markReady(&task_node.coro);
        }
    }
};