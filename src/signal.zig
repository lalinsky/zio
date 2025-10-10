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
    fn signalHandler(sig: c_int) callconv(.C) void {
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
    const WINAPI = std.os.windows.WINAPI;
    const BOOL = std.os.windows.BOOL;
    const TRUE = std.os.windows.TRUE;
    const FALSE = std.os.windows.FALSE;
    const DWORD = std.os.windows.DWORD;

    const CTRL_C_EVENT = 0;
    const CTRL_BREAK_EVENT = 1;
    const CTRL_CLOSE_EVENT = 2;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (DWORD) callconv(WINAPI) BOOL,
        add: BOOL,
    ) callconv(WINAPI) BOOL;

    fn ctrlHandler(ctrl_type: DWORD) callconv(WINAPI) BOOL {
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

/// Signal handler registration
pub const SignalHandler = struct {
    runtime: *Runtime,
    allocator: Allocator,
    async_handle: xev.Async,
    async_completion: xev.Completion,
    handlers: [Signal.COUNT]?*const fn () void,
    active_signals: [Signal.COUNT]bool,
    running: std.atomic.Value(bool),

    /// Initialize signal handling system
    pub fn init(runtime: *Runtime, allocator: Allocator) !*SignalHandler {
        const self = try allocator.create(SignalHandler);
        errdefer allocator.destroy(self);

        self.* = .{
            .runtime = runtime,
            .allocator = allocator,
            .async_handle = try xev.Async.init(),
            .async_completion = .{},
            .handlers = [_]?*const fn () void{null} ** Signal.COUNT,
            .active_signals = [_]bool{false} ** Signal.COUNT,
            .running = std.atomic.Value(bool).init(true),
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
        // Stop the handler coroutine
        self.running.store(false, .release);

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

    /// Register a signal handler callback
    pub fn installHandler(
        self: *SignalHandler,
        signal: Signal,
        comptime callback: fn () void,
    ) !void {
        const idx = @intFromEnum(signal);

        // Check if signal is supported on this platform
        if (builtin.os.tag == .windows) {
            switch (signal) {
                .int, .term => {}, // Supported on Windows
                else => return, // Unix-only signals are no-op on Windows
            }
        }

        // Store the callback
        self.handlers[idx] = callback;
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
            if (self.handlers[i]) |handler| {
                const signal: Signal = @enumFromInt(i);
                const count = GlobalState.consumeCounter(signal);

                // Call handler once for each signal received (in case of coalescing)
                var j: u32 = 0;
                while (j < count) : (j += 1) {
                    handler();
                }
            }
        }

        return .rearm;
    }

    /// Run the signal handler loop (should be spawned as a coroutine)
    pub fn run(self: *SignalHandler) !void {
        while (self.running.load(.acquire)) {
            // Yield to allow other coroutines to run
            try self.runtime.yield(.ready);
        }
    }
};

/// Helper function to install a signal handler
/// This spawns the signal handling coroutine automatically
pub fn installHandler(
    runtime: *Runtime,
    allocator: Allocator,
    signal: Signal,
    comptime callback: fn () void,
) !*SignalHandler {
    const handler = try SignalHandler.init(runtime, allocator);
    errdefer handler.deinit();

    try handler.installHandler(signal, callback);

    // Spawn coroutine to run the handler loop
    _ = try runtime.spawn(SignalHandler.run, .{handler}, .{});

    return handler;
}

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
