const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("common.zig").Cancelable;
const Timeoutable = @import("common.zig").Timeoutable;

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
    event: xev.Async = undefined,
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

                entry.event = try xev.Async.init();
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

        // Now we can safely deinit the event
        entry.event.deinit();
        entry.event = undefined;

        // Finally mark as available
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
                entry.event = try xev.Async.init();
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

        // Now we can safely deinit the event
        entry.event.deinit();
        entry.event = undefined;

        // Finally mark as available
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
            entry.event.notify() catch {};
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
            entry.event.notify() catch {};
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
    /// Returns error.Canceled if the task is cancelled while waiting.
    pub fn wait(self: *Signal, rt: *Runtime) Cancelable!void {
        // Check if we already have pending signals
        if (self.entry.counter.swap(0, .acquire) > 0) {
            return;
        }

        const AnyTask = @import("runtime.zig").AnyTask;
        const resumeTask = @import("runtime.zig").resumeTask;
        const waitForIo = @import("io/base.zig").waitForIo;

        const WaitContext = struct {
            task: *AnyTask,
            result: xev.Async.WaitError!void = undefined,
        };

        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();

        var ctx = WaitContext{ .task = task };
        var completion: xev.Completion = undefined;

        // Register async wait callback (this also adds to the loop)
        self.entry.event.wait(
            &executor.loop,
            &completion,
            WaitContext,
            &ctx,
            struct {
                fn callback(
                    userdata: ?*WaitContext,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    result: xev.Async.WaitError!void,
                ) xev.CallbackAction {
                    const context = userdata.?;
                    context.result = result;
                    resumeTask(context.task, .local);
                    return .disarm;
                }
            }.callback,
        );

        // Wait for signal (handles cancellation)
        try waitForIo(rt, &completion);

        // Check result - ignore any xev errors, just ensure signal was received
        ctx.result catch {};

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

        const AnyTask = @import("runtime.zig").AnyTask;
        const resumeTask = @import("runtime.zig").resumeTask;
        const timedWaitForIo = @import("io/base.zig").timedWaitForIo;

        const WaitContext = struct {
            task: *AnyTask,
            result: xev.Async.WaitError!void = undefined,
        };

        const task = rt.getCurrentTask() orelse unreachable;
        const executor = task.getExecutor();

        var ctx = WaitContext{ .task = task };
        var completion: xev.Completion = undefined;

        // Register async wait callback (this also adds to the loop)
        self.entry.event.wait(
            &executor.loop,
            &completion,
            WaitContext,
            &ctx,
            struct {
                fn callback(
                    userdata: ?*WaitContext,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    result: xev.Async.WaitError!void,
                ) xev.CallbackAction {
                    const context = userdata.?;
                    context.result = result;
                    resumeTask(context.task, .local);
                    return .disarm;
                }
            }.callback,
        );

        // Wait for signal with timeout (handles cancellation)
        try timedWaitForIo(rt, &completion, timeout_ns);

        // Check result - ignore any xev errors, just ensure signal was received
        ctx.result catch {};

        // Consume the counter
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
            defer h1.deinit();
            var h2 = try r.spawn(sendSignal, .{r}, .{});
            defer h2.deinit();

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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, rt }, .{});

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
            defer h1.deinit();
            var h2 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h2.deinit();
            var h3 = try r.spawn(waitForSignal, .{ self, r }, .{});
            defer h3.deinit();
            var h4 = try r.spawn(sendSignal, .{r}, .{});
            defer h4.deinit();

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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, rt }, .{});

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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, rt }, .{});

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
            defer h1.deinit();
            var h2 = try r.spawn(sendSignal, .{r}, .{});
            defer h2.deinit();

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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, rt }, .{});

    try std.testing.expect(ctx.signal_received);
}
