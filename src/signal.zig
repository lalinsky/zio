const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Cancelable = @import("runtime.zig").Cancelable;

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
        io = std.posix.SIG.IO,
        pipe = std.posix.SIG.PIPE,
        quit = std.posix.SIG.QUIT,
        user1 = std.posix.SIG.USR1,
        user2 = std.posix.SIG.USR2,
        window_change = std.posix.SIG.WINCH,
    },
};

const NO_SIGNAL = 255;
const MAX_HANDLERS = 32;

const HandlerEntry = struct {
    kind: std.atomic.Value(u8) = .init(NO_SIGNAL),
    event: xev.Async = undefined,
};

const HandlerRegistryUnix = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = [_]HandlerEntry{.{}} ** MAX_HANDLERS,
    // Reference count for each signal value (0-255)
    // Each signal type has its own OS-level handler that needs tracking
    installed_handlers: [256]std.atomic.Value(u8) = [_]std.atomic.Value(u8){.init(0)} ** 256,
    // Store previous signal handlers to restore when refcount reaches 0
    prev_handlers: [256]std.posix.Sigaction = undefined,

    fn install(self: *HandlerRegistryUnix, kind: SignalKind) !*xev.Async {
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
            const prev = entry.kind.cmpxchgStrong(NO_SIGNAL, signum, .acq_rel, .monotonic);
            if (prev == null) {
                errdefer entry.kind.store(NO_SIGNAL, .release);

                entry.event = try xev.Async.init();

                return &entry.event;
            }
        }

        return error.TooManySignalHandlers;
    }

    fn uninstall(self: *HandlerRegistryUnix, kind: SignalKind, event: *xev.Async) void {
        const signum: u8 = @intFromEnum(kind);

        const entry: *HandlerEntry = @fieldParentPtr("event", event);
        const prev_value = entry.kind.swap(NO_SIGNAL, .acq_rel);
        std.debug.assert(prev_value == signum);

        // Restore previous handler if this was the last handler for this signal type
        const new_count = self.installed_handlers[signum].fetchSub(1, .acq_rel) - 1;
        if (new_count == 0) {
            std.posix.sigaction(@intFromEnum(kind), &self.prev_handlers[signum], null);
        }

        // Now we can safely deinit the event
        entry.event.deinit();
        entry.event = undefined;
    }
};

const HandlerRegistryWindows = struct {
    handlers: [MAX_HANDLERS]HandlerEntry = [_]HandlerEntry{.{}} ** MAX_HANDLERS,
    // Total number of handlers across all signal types
    // Only one global console control handler for all signals
    total_handlers: std.atomic.Value(usize) = .init(0),

    fn install(self: *HandlerRegistryWindows, kind: SignalKind) !*xev.Async {
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
            const prev = entry.kind.cmpxchgStrong(NO_SIGNAL, signum, .acq_rel, .monotonic);
            if (prev == null) {
                errdefer entry.kind.store(NO_SIGNAL, .release);
                entry.event = try xev.Async.init();
                return &entry.event;
            }
        }

        return error.TooManySignalHandlers;
    }

    fn uninstall(self: *HandlerRegistryWindows, kind: SignalKind, event: *xev.Async) void {
        const signum: u8 = @intFromEnum(kind);

        const entry: *HandlerEntry = @fieldParentPtr("event", event);
        const prev_value = entry.kind.swap(NO_SIGNAL, .acq_rel);
        std.debug.assert(prev_value == signum);

        // Restore previous handler if this was the last handler
        const new_total = self.total_handlers.fetchSub(1, .acq_rel) - 1;
        if (new_total == 0) {
            _ = std.os.windows.kernel32.SetConsoleCtrlHandler(consoleCtrlHandlerWindows, 0);
        }

        // Now we can safely deinit the event
        entry.event.deinit();
        entry.event = undefined;
    }
};

const HandlerRegistry = if (builtin.os.tag == .windows) HandlerRegistryWindows else HandlerRegistryUnix;

var registry: HandlerRegistry = .{};

fn signalHandlerUnix(signum: c_int) callconv(.c) void {
    for (&registry.handlers) |*entry| {
        const kind = entry.kind.load(.acquire);
        if (kind != NO_SIGNAL and kind == signum) {
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
        if (kind != NO_SIGNAL and kind == signal_value) {
            entry.event.notify() catch {};
            found_handler = true;
        }
    }

    // Return 1 if we handled it, 0 to pass to default handler
    return if (found_handler) 1 else 0;
}

pub const Signal = struct {
    kind: SignalKind,
    event: *xev.Async,
    completion: xev.Completion = undefined,

    pub fn init(kind: SignalKind) !Signal {
        const event = try registry.install(kind);
        return .{ .kind = kind, .event = event };
    }

    pub fn deinit(self: *Signal) void {
        registry.uninstall(self.kind, self.event);
        self.event = undefined;
    }

    pub fn wait(self: *Signal, rt: *Runtime) Cancelable!void {
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

        // Register async wait callback (this also adds to the loop)
        self.event.wait(
            &executor.loop,
            &self.completion,
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
        try waitForIo(rt, &self.completion);

        // Check result - ignore any xev errors, just ensure signal was received
        ctx.result catch {};
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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, &rt }, .{});

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
    try rt.runUntilComplete(TestContext.mainTask, .{ &ctx, &rt }, .{});

    try std.testing.expectEqual(@as(usize, 3), ctx.count.load(.monotonic));
}
