const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const Allocator = std.mem.Allocator;

/// Cross-platform signal types
pub const Signal = enum(u8) {
    int = 0, // SIGINT / CTRL_C_EVENT
    term = 1, // SIGTERM / CTRL_CLOSE_EVENT
    // Unix-only signals (no-op on Windows)
    hup = 2, // SIGHUP
    quit = 3, // SIGQUIT
    usr1 = 4, // SIGUSR1
    usr2 = 5, // SIGUSR2

    const COUNT = 6;

    /// Convert Signal to platform-specific signal number (Unix only)
    fn toNative(self: Signal) u8 {
        return switch (self) {
            .int => std.posix.SIG.INT,
            .term => std.posix.SIG.TERM,
            .hup => std.posix.SIG.HUP,
            .quit => std.posix.SIG.QUIT,
            .usr1 => std.posix.SIG.USR1,
            .usr2 => std.posix.SIG.USR2,
        };
    }

    /// Convert native signal number to Signal (Unix only)
    fn fromNative(sig: c_int) ?Signal {
        if (sig == std.posix.SIG.INT) return .int;
        if (sig == std.posix.SIG.TERM) return .term;
        if (sig == std.posix.SIG.HUP) return .hup;
        if (sig == std.posix.SIG.QUIT) return .quit;
        if (sig == std.posix.SIG.USR1) return .usr1;
        if (sig == std.posix.SIG.USR2) return .usr2;
        return null;
    }
};

/// Global signal handler state
/// This must be global because C signal handlers can't capture context
const GlobalState = struct {
    /// Atomic counters for each signal type (incremented by signal handler)
    counters: [Signal.COUNT]std.atomic.Value(u32),
    /// Async handle to wake up the event loop
    async_handle: ?*xev.Async,
    /// Whether the global state is initialized
    initialized: std.atomic.Value(bool),

    var instance: GlobalState = .{
        .counters = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** Signal.COUNT,
        .async_handle = null,
        .initialized = std.atomic.Value(bool).init(false),
    };

    fn incrementCounter(signal: Signal) void {
        const idx = @intFromEnum(signal);
        _ = instance.counters[idx].fetchAdd(1, .release);

        // Wake up the event loop
        if (instance.async_handle) |async_h| {
            async_h.notify() catch {};
        }
    }

    /// Atomically read and reset a counter, returning the previous value
    fn consumeCounter(signal: Signal) u32 {
        const idx = @intFromEnum(signal);
        return instance.counters[idx].swap(0, .acq_rel);
    }
};

// Platform-specific signal handler implementations
const posix = if (builtin.os.tag != .windows) struct {
    fn signalHandler(sig: c_int) callconv(.c) void {
        // CRITICAL: This runs in signal context - only async-signal-safe operations!
        const signal = Signal.fromNative(sig) orelse return;
        GlobalState.incrementCounter(signal);
    }

    fn installSignalHandler(signal: Signal) void {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(signal.toNative(), &act, null);
    }

    fn restoreSignalHandler(signal: Signal) void {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(signal.toNative(), &act, null);
    }
} else struct {};

const windows = if (builtin.os.tag == .windows) struct {
    const BOOL = std.os.windows.BOOL;
    const TRUE = std.os.windows.TRUE;
    const FALSE = std.os.windows.FALSE;
    const DWORD = std.os.windows.DWORD;

    const CTRL_C_EVENT = 0;
    const CTRL_BREAK_EVENT = 1;
    const CTRL_CLOSE_EVENT = 2;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (DWORD) callconv(.winapi) BOOL,
        add: BOOL,
    ) callconv(.winapi) BOOL;

    fn ctrlHandler(ctrl_type: DWORD) callconv(.winapi) BOOL {
        // This runs in a separate thread spawned by the system
        const signal: ?Signal = switch (ctrl_type) {
            CTRL_C_EVENT => .int,
            CTRL_CLOSE_EVENT => .term,
            else => null,
        };

        if (signal) |sig| {
            GlobalState.incrementCounter(sig);
            return TRUE; // Signal handled
        }

        return FALSE; // Signal not handled
    }

    fn installCtrlHandler() !void {
        if (SetConsoleCtrlHandler(&ctrlHandler, TRUE) == FALSE) {
            return error.SetConsoleCtrlHandlerFailed;
        }
    }

    fn removeCtrlHandler() void {
        _ = SetConsoleCtrlHandler(&ctrlHandler, FALSE);
    }
} else struct {};

/// Internal signal handler state (owned by Runtime)
pub const SignalHandler = struct {
    const ARGS_SIZE = 64;

    const HandlerEntry = struct {
        callback: *const fn (*anyopaque) void,
        args_data: [ARGS_SIZE]u8 align(16), // Use 16-byte alignment to handle most types
        args_size: usize,
    };

    runtime: *Runtime,
    allocator: Allocator,
    async_handle: xev.Async,
    async_completion: xev.Completion,
    handlers: [Signal.COUNT]?HandlerEntry,
    active_signals: [Signal.COUNT]bool,

    /// Initialize signal handling system
    pub fn init(runtime: *Runtime, allocator: Allocator) !*SignalHandler {
        const self = try allocator.create(SignalHandler);
        errdefer allocator.destroy(self);

        self.* = .{
            .runtime = runtime,
            .allocator = allocator,
            .async_handle = try xev.Async.init(),
            .async_completion = .{},
            .handlers = [_]?HandlerEntry{null} ** Signal.COUNT,
            .active_signals = [_]bool{false} ** Signal.COUNT,
        };

        // Initialize global state if not already done
        const was_initialized = GlobalState.instance.initialized.swap(true, .acq_rel);
        if (!was_initialized) {
            // First initialization - install platform-specific handlers
            if (builtin.os.tag == .windows) {
                try windows.installCtrlHandler();
            }
        }

        // Set global async handle
        GlobalState.instance.async_handle = &self.async_handle;

        // Register async wait to wake up when signals arrive
        self.async_handle.wait(
            &runtime.loop,
            &self.async_completion,
            SignalHandler,
            self,
            asyncCallback,
        );

        return self;
    }

    pub fn deinit(self: *SignalHandler) void {
        // Uninstall signal handlers
        for (self.active_signals, 0..) |active, i| {
            if (active) {
                const signal: Signal = @enumFromInt(i);
                if (builtin.os.tag != .windows) {
                    posix.restoreSignalHandler(signal);
                }
            }
        }

        // Remove platform-specific handlers
        if (builtin.os.tag == .windows) {
            windows.removeCtrlHandler();
        }

        // Clear global state
        GlobalState.instance.async_handle = null;
        GlobalState.instance.initialized.store(false, .release);

        self.async_handle.deinit();
        self.allocator.destroy(self);
    }

    /// Register a signal handler callback with args
    pub fn installHandler(
        self: *SignalHandler,
        signal: Signal,
        comptime callback: anytype,
        args: anytype,
    ) !void {
        const idx = @intFromEnum(signal);

        // Check if signal is supported on this platform
        if (builtin.os.tag == .windows) {
            switch (signal) {
                .int, .term => {}, // Supported on Windows
                else => return, // Unix-only signals are no-op on Windows
            }
        }

        // Get the function parameter type
        const fn_info = @typeInfo(@TypeOf(callback)).@"fn";
        comptime {
            if (fn_info.params.len != 1) {
                @compileError("Signal handler callback must take exactly 1 parameter");
            }
        }
        const ParamType = fn_info.params[0].type.?;
        const param_size = @sizeOf(ParamType);
        const param_align = @alignOf(ParamType);

        // Verify args fit in reserved space
        comptime {
            if (param_size > ARGS_SIZE) {
                @compileError(std.fmt.comptimePrint(
                    "Signal handler args too large: {} bytes (max {})",
                    .{ param_size, ARGS_SIZE },
                ));
            }
            if (param_align > 16) {
                @compileError(std.fmt.comptimePrint(
                    "Signal handler args alignment too large: {} (max 16)",
                    .{param_align},
                ));
            }
        }

        // Create wrapper that extracts args and calls user callback
        const Wrapper = struct {
            fn call(args_ptr: *anyopaque) void {
                // Cast the args pointer directly to the function's expected parameter type
                const param_ptr: *const ParamType = @ptrCast(@alignCast(args_ptr));
                callback(param_ptr.*);
            }
        };

        // Store the callback and args
        var entry = HandlerEntry{
            .callback = &Wrapper.call,
            .args_data = undefined,
            .args_size = param_size,
        };

        // Copy args into the data buffer
        if (param_size > 0) {
            // We need to ensure proper alignment when copying
            // Cast args to bytes and copy
            const src_ptr: [*]const u8 = @ptrCast(&args);
            @memcpy(entry.args_data[0..param_size], src_ptr[0..param_size]);
        }

        self.handlers[idx] = entry;
        self.active_signals[idx] = true;

        // Install platform-specific handler
        if (builtin.os.tag != .windows) {
            posix.installSignalHandler(signal);
        }
    }

    /// Async callback when signals arrive
    fn asyncCallback(
        self_opt: ?*SignalHandler,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = result catch unreachable;
        const self = self_opt.?;

        // Check which signals fired and dispatch to handlers
        for (0..Signal.COUNT) |i| {
            if (self.handlers[i]) |*entry| {
                const signal: Signal = @enumFromInt(i);
                const count = GlobalState.consumeCounter(signal);

                // Call handler once for each signal received (in case of coalescing)
                var j: u32 = 0;
                while (j < count) : (j += 1) {
                    // Call with pointer to args data
                    entry.callback(@ptrCast(&entry.args_data));
                }
            }
        }

        return .rearm;
    }
};

test "signal handler basic initialization" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const handler = try SignalHandler.init(&runtime, testing.allocator);
    defer handler.deinit();

    // Just verify it initializes and cleans up correctly
    try testing.expect(handler.runtime == &runtime);
}

test "signal counter increment and consume" {
    const testing = std.testing;

    // Reset global state
    for (0..Signal.COUNT) |i| {
        _ = GlobalState.instance.counters[i].swap(0, .acq_rel);
    }

    // Increment some counters
    GlobalState.incrementCounter(.int);
    GlobalState.incrementCounter(.int);
    GlobalState.incrementCounter(.term);

    // Consume and verify
    const int_count = GlobalState.consumeCounter(.int);
    try testing.expectEqual(@as(u32, 2), int_count);

    const term_count = GlobalState.consumeCounter(.term);
    try testing.expectEqual(@as(u32, 1), term_count);

    // Should be zero after consuming
    const int_count2 = GlobalState.consumeCounter(.int);
    try testing.expectEqual(@as(u32, 0), int_count2);
}

test "signal handler with args" {
    const testing = std.testing;

    var runtime = try Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    const handler = try SignalHandler.init(&runtime, testing.allocator);
    defer handler.deinit();

    var counter: u32 = 0;
    const increment_by: u32 = 5;

    const Args = struct { counter_ptr: *u32, value: u32 };
    const TestCallback = struct {
        fn callback(args: Args) void {
            args.counter_ptr.* += args.value;
        }
    };

    const args_to_pass: Args = .{ .counter_ptr = &counter, .value = increment_by };

    try handler.installHandler(.int, TestCallback.callback, args_to_pass);

    // Simulate signal
    GlobalState.incrementCounter(.int);
    GlobalState.incrementCounter(.int);

    // Trigger async callback manually
    _ = SignalHandler.asyncCallback(handler, &runtime.loop, &handler.async_completion, {});

    try testing.expectEqual(@as(u32, 10), counter);
}
