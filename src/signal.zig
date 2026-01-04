// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const aio = @import("aio");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;
const WaitQueue = @import("utils/wait_queue.zig").WaitQueue;
const WaitNode = @import("runtime/WaitNode.zig");
const Timeout = @import("runtime/timeout.zig").Timeout;

pub const SignalKind = switch (builtin.os.tag) {
    .windows => enum(u8) {
        interrupt = std.os.windows.CTRL_C_EVENT,
        terminate = std.os.windows.CTRL_CLOSE_EVENT,
    },
    else => enum(u8) {
        interrupt = std.posix.SIG.INT,
        terminate = std.posix.SIG.TERM,
        hangup = std.posix.SIG.HUP,
        alarm = std.posix.SIG.ALRM,
        child = std.posix.SIG.CHLD,
        pipe = std.posix.SIG.PIPE,
        quit = std.posix.SIG.QUIT,
        user1 = std.posix.SIG.USR1,
        user2 = std.posix.SIG.USR2,
        _,
    },
};

const NO_SIGNAL = 255;
const INSTALLING = 254;
const MAX_HANDLERS = 32;

const HandlerEntry = struct {
    kind: std.atomic.Value(u8) = .init(NO_SIGNAL),
    counter: std.atomic.Value(usize) = .init(0),
    waiters: WaitQueue(WaitNode) = .empty,
};

const HandlerRegistryUnix = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = [_]HandlerEntry{.{}} ** MAX_HANDLERS,
    // Reference count for each signal value (0-255)
    // Each signal type has its own OS-level handler that needs tracking
    installed_handlers: [256]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.init(0)} ** 256,
    // Store previous signal handlers to restore when refcount reaches 0
    prev_handlers: [256]std.posix.Sigaction = undefined,

    fn install(self: *HandlerRegistryUnix, kind: SignalKind) !*HandlerEntry {
        const signum: u8 = @intFromEnum(kind);

        // Atomically increment refcount for this signal type
        const prev_count = self.installed_handlers[signum].fetchAdd(1, .acq_rel);
        errdefer _ = self.installed_handlers[signum].fetchSub(1, .acq_rel);

        if (prev_count == 0) {
            // First handler for this signal type - install OS signal handler
            var sa = std.posix.Sigaction{
                .handler = .{ .handler = signalHandlerUnix },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.RESTART,
            };

            // Save the previous handler so we can restore it later
            std.posix.sigaction(@intFromEnum(kind), &sa, &self.prev_handlers[signum]);
        }

        errdefer {
            // Restore previous handler if this was the last handler
            if (prev_count == 0) {
                std.posix.sigaction(@intFromEnum(kind), &self.prev_handlers[signum], null);
            }
        }

        // Now find a slot for this signal handler
        for (&self.handlers) |*entry| {
            const prev = entry.kind.cmpxchgStrong(NO_SIGNAL, INSTALLING, .acq_rel, .monotonic);
            if (prev == null) {
                errdefer entry.kind.store(NO_SIGNAL, .release);

                // Initialize the wait queue and counter
                entry.waiters = .empty;
                entry.counter.store(0, .release);
                entry.kind.store(signum, .release);

                return entry;
            }
        }

        return error.TooManySignalHandlers;
    }

    fn uninstall(self: *HandlerRegistryUnix, kind: SignalKind, entry: *HandlerEntry) void {
        const signum: u8 = @intFromEnum(kind);

        // First swap to INSTALLING to prevent signal handler from accessing this entry
        const prev_value = entry.kind.swap(INSTALLING, .acq_rel);
        std.debug.assert(prev_value == signum);

        // Restore previous handler if this was the last handler for this signal type
        const new_count = self.installed_handlers[signum].fetchSub(1, .acq_rel) - 1;
        if (new_count == 0) {
            std.posix.sigaction(@intFromEnum(kind), &self.prev_handlers[signum], null);
        }

        // Mark as available
        entry.kind.store(NO_SIGNAL, .release);
    }
};

const HandlerRegistryWindows = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = [_]HandlerEntry{.{}} ** MAX_HANDLERS,
    // Total number of handlers across all signal types
    // Only one global console control handler for all signals
    total_handlers: std.atomic.Value(usize) = .init(0),

    fn install(self: *HandlerRegistryWindows, kind: SignalKind) !*HandlerEntry {
        const signum: u8 = @intFromEnum(kind);

        const prev_total = self.total_handlers.fetchAdd(1, .acq_rel);
        errdefer _ = self.total_handlers.fetchSub(1, .acq_rel);

        if (prev_total == 0) {
            // First handler of any type - install the global console control handler
            const result = std.os.windows.kernel32.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, 1);
            if (result == 0) {
                return error.SetConsoleCtrlHandlerFailed;
            }
        }

        errdefer {
            // Restore previous handler if this was the last handler
            if (prev_total == 0) {
                _ = std.os.windows.kernel32.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, 0);
            }
        }

        // Now find a slot for this signal handler
        for (&self.handlers) |*entry| {
            const prev = entry.kind.cmpxchgStrong(NO_SIGNAL, INSTALLING, .acq_rel, .monotonic);
            if (prev == null) {
                errdefer entry.kind.store(NO_SIGNAL, .release);

                // Initialize the wait queue and counter
                entry.waiters = .empty;
                entry.counter.store(0, .release);
                entry.kind.store(signum, .release);

                return entry;
            }
        }

        return error.TooManySignalHandlers;
    }

    fn uninstall(self: *HandlerRegistryWindows, kind: SignalKind, entry: *HandlerEntry) void {
        const signum: u8 = @intFromEnum(kind);

        // First swap to INSTALLING to prevent signal handler from accessing this entry
        const prev_value = entry.kind.swap(INSTALLING, .acq_rel);
        std.debug.assert(prev_value == signum);

        // Restore previous handler if this was the last handler
        const new_total = self.total_handlers.fetchSub(1, .acq_rel) - 1;
        if (new_total == 0) {
            _ = std.os.windows.kernel32.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, 0);
        }

        // Mark as available
        entry.kind.store(NO_SIGNAL, .release);
    }
};

const HandlerRegistry = if (builtin.os.tag == .windows) HandlerRegistryWindows else HandlerRegistryUnix;

var registry: HandlerRegistry = .{};

fn signalHandlerUnix(signum: c_int) callconv(.c) void {
    for (&registry.handlers) |*entry| {
        const kind = entry.kind.load(.acquire);
        if (kind == signum) {
            _ = entry.counter.fetchAdd(1, .release);

            // Wake all waiting tasks
            while (entry.waiters.pop()) |wait_node| {
                wait_node.wake();
            }
        }
    }
}

fn consoleCtrlHandlerWindows(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    // Map Windows control events to SignalKind values
    const signal_value: u8 = switch (ctrl_type) {
        std.os.windows.CTRL_C_EVENT => @intFromEnum(SignalKind.interrupt),
        std.os.windows.CTRL_CLOSE_EVENT => @intFromEnum(SignalKind.terminate),
        else => return 0, // Not handled
    };

    // Notify all matching handlers
    var found_handler = false;
    for (&registry.handlers) |*entry| {
        const kind = entry.kind.load(.acquire);
        if (kind == signal_value) {
            _ = entry.counter.fetchAdd(1, .release);

            // Wake all waiting tasks
            while (entry.waiters.pop()) |wait_node| {
                wait_node.wake();
            }

            found_handler = true;
        }
    }

    // Return 1 if we handled it, 0 to pass to default handler
    return if (found_handler) 1 else 0;
}

/// OS signal watcher.
///
/// Signal allows tasks to wait for OS signals (Unix) or console control events (Windows).
/// Multiple watchers can be registered for the same signal type, and all watchers will
/// be notified when the signal is received.
///
/// Signal watchers use an internal counter to track received signals, preventing signal
/// loss between wait operations. If a signal is received while no task is waiting, the
/// next wait operation will return immediately.
///
/// Example:
/// ```zig
/// var sig = try Signal.init(.interrupt);
/// defer sig.deinit();
/// try sig.wait(rt);  // Blocks until SIGINT is received
/// ```
pub const Signal = struct {
    kind: SignalKind,
    entry: *HandlerEntry,

    // Future protocol - allows Signal to be used with select()
    pub const Result = void;

    /// Initializes a new signal watcher for the specified signal kind.
    /// Multiple watchers can be registered for the same signal type.
    ///
    /// When the first watcher for a signal type is initialized, the OS signal handler
    /// is installed and the previous handler is saved.
    ///
    /// Returns error.TooManySignalHandlers if MAX_HANDLERS (32) concurrent watchers are already registered.
    pub fn init(kind: SignalKind) !Signal {
        const entry = try registry.install(kind);
        return .{ .kind = kind, .entry = entry };
    }

    /// Deinitializes the signal watcher and releases its resources.
    ///
    /// When the last watcher for a signal type is deinitialized, the previous OS signal
    /// handler is restored.
    pub fn deinit(self: *Signal) void {
        registry.uninstall(self.kind, self.entry);
        self.entry = undefined;
    }

    /// Waits for the signal to be received.
    /// If the signal was already received (counter > 0), returns immediately.
    /// Otherwise, suspends the current task until the signal is received.
    ///
    /// This function can be called multiple times - each call will wait for a new signal.
    /// The internal counter is reset after each wait, ensuring signals are not lost.
    ///
    /// Returns error.Canceled if the task is cancelled while waiting (including due to timeout expiry).
    pub fn wait(self: *Signal, rt: *Runtime) Cancelable!void {
        // Check if we already have pending signals
        if (self.entry.counter.swap(0, .acquire) > 0) {
            return;
        }

        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        // Transition to preparing_to_wait state before adding to queue
        task.state.store(.preparing_to_wait, .release);

        // Add to wait queue
        self.entry.waiters.push(&task.awaitable.wait_node);

        // Yield with atomic state transition (.preparing_to_wait -> .waiting)
        // If signal arrives before the yield, the CAS inside yield() will fail and we won't suspend
        executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
            // On cancellation, remove from queue
            _ = self.entry.waiters.remove(&task.awaitable.wait_node);
            return err;
        };

        // Consume the counter
        _ = self.entry.counter.swap(0, .acquire);
    }

    /// Waits for the signal to be received with a timeout.
    /// If the signal was already received (counter > 0), returns immediately.
    /// Otherwise, suspends the current task until either:
    /// - The signal is received (returns successfully)
    /// - The timeout expires (returns error.Timeout)
    /// - The task is cancelled (returns error.Canceled)
    ///
    /// This function can be called multiple times - each call will wait for a new signal.
    /// The internal counter is reset after each wait, ensuring signals are not lost.
    ///
    /// Arguments:
    /// - rt: Runtime context
    /// - timeout_ns: Timeout duration in nanoseconds
    pub fn timedWait(self: *Signal, rt: *Runtime, timeout_ns: u64) (Timeoutable || Cancelable)!void {
        // Check if we already have pending signals
        if (self.entry.counter.swap(0, .acquire) > 0) {
            return;
        }

        const task = rt.getCurrentTask();
        const executor = task.getExecutor();

        // Transition to preparing_to_wait state before adding to queue
        task.state.store(.preparing_to_wait, .release);

        // Add to wait queue
        self.entry.waiters.push(&task.awaitable.wait_node);

        // Set up timeout
        var timeout = Timeout.init;
        defer timeout.clear(rt);
        timeout.set(rt, timeout_ns);

        // Yield with atomic state transition (.preparing_to_wait -> .waiting)
        // If signal arrives before the yield, the CAS inside yield() will fail and we won't suspend
        executor.yield(.preparing_to_wait, .waiting, .allow_cancel) catch |err| {
            // Try to remove from queue
            _ = self.entry.waiters.remove(&task.awaitable.wait_node);

            // Check if this timeout triggered, otherwise it was user cancellation
            return rt.checkTimeout(&timeout, err);
        };

        // Consume the counter
        _ = self.entry.counter.swap(0, .acquire);
    }

    /// Registers a wait node to be notified when the signal is received.
    /// This is part of the Future protocol for select().
    /// Returns false if the signal was already received (no wait needed), true if added to wait queue.
    pub fn asyncWait(self: *Signal, _: *Runtime, wait_node: *WaitNode) bool {
        // Fast path: signal already received
        if (self.entry.counter.swap(0, .acquire) > 0) {
            return false;
        }

        // Add to wait queue
        self.entry.waiters.push(wait_node);
        return true;
    }

    /// Cancels a pending wait operation by removing the wait node.
    /// This is part of the Future protocol for select().
    pub fn asyncCancelWait(self: *Signal, _: *Runtime, wait_node: *WaitNode) void {
        // Simply remove from queue - no need to wake another waiter since signals broadcast to all
        _ = self.entry.waiters.remove(wait_node);
    }

    /// Gets the result value.
    /// This is part of the Future protocol for select().
    pub fn getResult(self: *Signal) void {
        // Consume the counter to ensure signal is acknowledged
        _ = self.entry.counter.swap(0, .acquire);
    }
};

test "Signal: basic signal handling" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        signal_received: bool = false,

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var h1 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h1.cancel(r);
            var h2 = try r.spawn(sendSignal, .{r}, .{});
            defer h2.cancel(r);

            try h1.join(r);
            try h2.join(r);
        }

        fn waitForSignal(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();

            try sig.wait(r);
            self.signal_received = true;
        }

        fn sendSignal(r: *Runtime) !void {
            try r.sleep(10);
            try std.posix.raise(@intFromEnum(SignalKind.interrupt));
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expect(ctx.signal_received);
}

test "Signal: multiple handlers for same signal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var h1 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h1.cancel(r);
            var h2 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h2.cancel(r);
            var h3 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h3.cancel(r);
            var h4 = try r.spawn(sendSignal, .{r}, .{});
            defer h4.cancel(r);

            try h1.join(r);
            try h2.join(r);
            try h3.join(r);
            try h4.join(r);
        }

        fn waitForSignal(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();

            try sig.wait(r);
            _ = self.count.fetchAdd(1, .monotonic);
        }

        fn sendSignal(r: *Runtime) !void {
            try r.sleep(10);
            try std.posix.raise(@intFromEnum(SignalKind.interrupt));
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expectEqual(@as(usize, 3), ctx.count.load(.monotonic));
}

test "Signal: timedWait timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        timed_out: bool = false,

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();

            sig.timedWait(r, 50 * std.time.ns_per_ms) catch |err| {
                if (err == error.Timeout) {
                    self.timed_out = true;
                    return;
                }
                return err;
            };
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expect(ctx.timed_out);
}

test "Signal: timedWait receives signal before timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const TestContext = struct {
        signal_received: bool = false,

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var h1 = try r.spawn(waitForSignalTimed, .{ self, r }, .{});
            defer h1.cancel(r);
            var h2 = try r.spawn(sendSignal, .{r}, .{});
            defer h2.cancel(r);

            try h1.join(r);
            try h2.join(r);
        }

        fn waitForSignalTimed(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.interrupt);
            defer sig.deinit();

            try sig.timedWait(r, 1000 * std.time.ns_per_ms);
            self.signal_received = true;
        }

        fn sendSignal(r: *Runtime) !void {
            try r.sleep(10);
            try std.posix.raise(@intFromEnum(SignalKind.interrupt));
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expect(ctx.signal_received);
}

test "Signal: select on multiple signals" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    const TestContext = struct {
        signal_received: std.atomic.Value(u8) = .init(0),

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var h1 = try r.spawn(waitForSignals, .{ self, r }, .{});
            defer h1.cancel(r);
            var h2 = try r.spawn(sendSignal, .{r}, .{});
            defer h2.cancel(r);

            try h1.join(r);
            try h2.join(r);
        }

        fn waitForSignals(self: *@This(), r: *Runtime) !void {
            var sig1 = try Signal.init(.user1);
            defer sig1.deinit();
            var sig2 = try Signal.init(.user2);
            defer sig2.deinit();

            const result = try select(r, .{ .sig1 = &sig1, .sig2 = &sig2 });
            switch (result) {
                .sig1 => self.signal_received.store(@intFromEnum(SignalKind.user1), .monotonic),
                .sig2 => self.signal_received.store(@intFromEnum(SignalKind.user2), .monotonic),
            }
        }

        fn sendSignal(r: *Runtime) !void {
            try r.sleep(10);
            try std.posix.raise(@intFromEnum(SignalKind.user2));
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expectEqual(@intFromEnum(SignalKind.user2), ctx.signal_received.load(.monotonic));
}

test "Signal: select with signal already received (fast path)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    const TestContext = struct {
        signal_received: bool = false,

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.user1);
            defer sig.deinit();

            // Send signal first
            try std.posix.raise(@intFromEnum(SignalKind.user1));

            // Small delay to ensure signal is processed
            try r.sleep(10);

            // Now select should return immediately (fast path)
            const result = try select(r, .{ .sig = &sig });
            switch (result) {
                .sig => self.signal_received = true,
            }
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expect(ctx.signal_received);
}

test "Signal: select with signal and task" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    const select = @import("select.zig").select;

    const TestContext = struct {
        winner: enum { signal, task } = .task,

        fn slowTask(r: *Runtime) !u32 {
            try r.sleep(100);
            return 42;
        }

        fn mainTask(self: *@This(), r: *Runtime) !void {
            var sig = try Signal.init(.user1);
            defer sig.deinit();

            var task = try r.spawn(slowTask, .{r}, .{});
            defer task.cancel(r);

            var sender = try r.spawn(sendSignal, .{r}, .{});
            defer sender.cancel(r);

            // Signal should win (arrives much sooner)
            const result = try select(r, .{ .sig = &sig, .task = &task });
            switch (result) {
                .sig => self.winner = .signal,
                .task => |val| {
                    _ = try val;
                    self.winner = .task;
                },
            }

            try sender.join(r);
        }

        fn sendSignal(r: *Runtime) !void {
            try r.sleep(10);
            try std.posix.raise(@intFromEnum(SignalKind.user1));
        }
    };

    var ctx = TestContext{};
    var handle = try rt.spawn(TestContext.mainTask, .{ &ctx, rt }, .{});
    try handle.join(rt);

    try std.testing.expectEqual(.signal, ctx.winner);
}
