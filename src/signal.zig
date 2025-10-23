const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const Runtime = @import("runtime.zig").Runtime;
const runIo = @import("io/base.zig").runIo;

/// Signal types that can be waited on across all platforms.
pub const SignalType = enum {
    /// SIGINT on Unix (Ctrl+C), CTRL_C_EVENT on Windows
    int,
    /// SIGTERM on Unix, CTRL_CLOSE_EVENT on Windows
    term,
};

/// Cross-platform signal handler.
///
/// Allows waiting for OS signals in a coroutine-friendly way using the
/// async runtime. Multiple coroutines can wait on the same signal.
///
/// ## Example
/// ```zig
/// const sig = zio.Signal.init(.int);
/// while (true) {
///     try sig.wait(rt);
///     std.log.info("Received SIGINT, shutting down...", .{});
///     break;
/// }
/// ```
pub const Signal = struct {
    impl: Impl,

    const Impl = if (builtin.os.tag == .windows)
        WindowsImpl
    else if (builtin.os.tag == .linux)
        LinuxImpl
    else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd)
        KqueueImpl
    else
        @compileError("Unsupported platform for signal handling");

    pub fn init(signal_type: SignalType) Signal {
        return .{
            .impl = Impl.init(signal_type),
        };
    }

    /// Wait for the signal to be received.
    /// Blocks the current coroutine until the signal arrives.
    pub fn wait(self: *Signal, rt: *Runtime) !void {
        return self.impl.wait(rt);
    }

    /// Cleanup resources. Must be called when done with the signal.
    pub fn deinit(self: *Signal) void {
        self.impl.deinit();
    }
};

// Unix signal mask registry for reference counting
const UnixSignalMaskRegistry = if (builtin.os.tag == .linux or
    builtin.os.tag == .macos or
    builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd or
    builtin.os.tag == .openbsd)
    struct {
        var mutex: std.Thread.Mutex = .{};
        var refcounts: [2]usize = .{ 0, 0 }; // Index 0 = SIGINT, 1 = SIGTERM

        fn indexForSignal(signal_type: SignalType) usize {
            return switch (signal_type) {
                .int => 0,
                .term => 1,
            };
        }

        fn incrementAndMaskIfNeeded(signal_type: SignalType) !void {
            mutex.lock();
            defer mutex.unlock();

            const idx = indexForSignal(signal_type);
            if (refcounts[idx] == 0) {
                // First instance for this signal type - mask it
                const signum: c_int = switch (signal_type) {
                    .int => std.posix.SIG.INT,
                    .term => std.posix.SIG.TERM,
                };

                var mask = std.posix.sigemptyset();
                std.posix.sigaddset(&mask, @intCast(signum));
                std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
            }
            refcounts[idx] += 1;
        }

        fn decrementAndUnmaskIfNeeded(signal_type: SignalType) void {
            mutex.lock();
            defer mutex.unlock();

            const idx = indexForSignal(signal_type);
            if (refcounts[idx] > 0) {
                refcounts[idx] -= 1;
                if (refcounts[idx] == 0) {
                    // Last instance for this signal type - unmask it
                    const signum: c_int = switch (signal_type) {
                        .int => std.posix.SIG.INT,
                        .term => std.posix.SIG.TERM,
                    };

                    var mask = std.posix.sigemptyset();
                    std.posix.sigaddset(&mask, @intCast(signum));
                    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
                }
            }
        }
    }
else
    void;

// Linux implementation using signalfd
const LinuxImpl = struct {
    signal_type: SignalType,
    fd: std.posix.fd_t = -1,
    mutex: std.Thread.Mutex = .{},

    fn init(signal_type: SignalType) LinuxImpl {
        return .{ .signal_type = signal_type };
    }

    fn wait(self: *LinuxImpl, rt: *Runtime) !void {
        // Lazy initialization on first wait
        self.mutex.lock();
        const needs_init = self.fd == -1;
        self.mutex.unlock();

        if (needs_init) {
            try self.initializeSignal();
        }

        // Read from signalfd - this blocks in xev's event loop
        var info: std.os.linux.signalfd_siginfo = undefined;
        var completion: xev.Completion = .{
            .op = .{
                .read = .{
                    .fd = self.fd,
                    .buffer = .{ .slice = std.mem.asBytes(&info) },
                },
            },
        };

        _ = try runIo(rt, &completion, "read");
    }

    fn initializeSignal(self: *LinuxImpl) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check after acquiring lock
        if (self.fd != -1) return;

        // Increment refcount and mask signal if this is the first instance
        try UnixSignalMaskRegistry.incrementAndMaskIfNeeded(self.signal_type);

        const signum: c_int = switch (self.signal_type) {
            .int => std.posix.SIG.INT,
            .term => std.posix.SIG.TERM,
        };

        // Create signalfd
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, @intCast(signum));
        self.fd = try std.posix.signalfd(-1, &mask, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
    }

    fn deinit(self: *LinuxImpl) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.fd != -1) {
            std.posix.close(self.fd);
            self.fd = -1;

            // Decrement refcount and unmask signal if this is the last instance
            UnixSignalMaskRegistry.decrementAndUnmaskIfNeeded(self.signal_type);
        }
    }
};

// macOS/BSD implementation using kqueue EVFILT_SIGNAL
const KqueueImpl = struct {
    signal_type: SignalType,
    initialized: bool = false,
    mutex: std.Thread.Mutex = .{},

    fn init(signal_type: SignalType) KqueueImpl {
        return .{ .signal_type = signal_type };
    }

    fn wait(self: *KqueueImpl, rt: *Runtime) !void {
        // Lazy initialization on first wait
        self.mutex.lock();
        const needs_init = !self.initialized;
        self.mutex.unlock();

        if (needs_init) {
            try self.initializeSignal();
        }

        // Wait for signal using xev's signal operation
        var completion: xev.Completion = .{
            .op = .{
                .signal = .{
                    .signum = switch (self.signal_type) {
                        .int => std.posix.SIG.INT,
                        .term => std.posix.SIG.TERM,
                    },
                },
            },
        };

        _ = try runIo(rt, &completion, "signal");
    }

    fn initializeSignal(self: *KqueueImpl) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check after acquiring lock
        if (self.initialized) return;

        // Increment refcount and mask signal if this is the first instance
        try UnixSignalMaskRegistry.incrementAndMaskIfNeeded(self.signal_type);

        self.initialized = true;
    }

    fn deinit(self: *KqueueImpl) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.initialized) {
            // Decrement refcount and unmask signal if this is the last instance
            UnixSignalMaskRegistry.decrementAndUnmaskIfNeeded(self.signal_type);
            self.initialized = false;
        }
    }
};

// Windows implementation using SetConsoleCtrlHandler + ResetEvent
const WindowsImpl = struct {
    signal_type: SignalType,
    event: ResetEvent = ResetEvent.init,
    registry_id: ?usize = null,
    mutex: std.Thread.Mutex = .{},
    registered: bool = false,

    const ResetEvent = @import("sync.zig").ResetEvent;

    fn init(signal_type: SignalType) WindowsImpl {
        return .{ .signal_type = signal_type };
    }

    fn wait(self: *WindowsImpl, rt: *Runtime) !void {
        // Lazy initialization on first wait
        self.mutex.lock();
        const needs_init = !self.registered;
        self.mutex.unlock();

        if (needs_init) {
            try self.initializeSignal();
        }

        // Wait for signal - event will be set by console handler
        try self.event.wait(rt);

        // Reset for next wait
        self.event.reset();
    }

    fn initializeSignal(self: *WindowsImpl) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Double-check after acquiring lock
        if (self.registered) return;

        // Register with global handler
        self.registry_id = try GlobalHandlerRegistry.register(self.signal_type, &self.event);
        self.registered = true;
    }

    fn deinit(self: *WindowsImpl) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.registry_id) |id| {
            GlobalHandlerRegistry.unregister(id);
            self.registry_id = null;
            self.registered = false;
        }
    }

    // Global registry for Windows console control handlers
    const GlobalHandlerRegistry = struct {
        var mutex: std.Thread.Mutex = .{};
        var handlers: std.ArrayListUnmanaged(HandlerEntry) = .{};
        var ctrl_handler_installed: bool = false;
        var next_id: usize = 0;

        const HandlerEntry = struct {
            id: usize,
            signal_type: SignalType,
            event: *ResetEvent,
        };

        fn register(signal_type: SignalType, event: *ResetEvent) !usize {
            mutex.lock();
            defer mutex.unlock();

            const id = next_id;
            next_id += 1;

            try handlers.append(std.heap.page_allocator, .{
                .id = id,
                .signal_type = signal_type,
                .event = event,
            });

            if (!ctrl_handler_installed) {
                const result = std.os.windows.kernel32.SetConsoleCtrlHandler(consoleCtrlHandler, 1);
                if (result == 0) return error.SetConsoleCtrlHandlerFailed;
                ctrl_handler_installed = true;
            }

            return id;
        }

        fn unregister(id: usize) void {
            mutex.lock();
            defer mutex.unlock();

            var i: usize = 0;
            while (i < handlers.items.len) {
                if (handlers.items[i].id == id) {
                    _ = handlers.swapRemove(i);
                    break;
                }
                i += 1;
            }
        }

        fn consoleCtrlHandler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
            mutex.lock();
            defer mutex.unlock();

            const signal_type: ?SignalType = switch (ctrl_type) {
                std.os.windows.CTRL_C_EVENT, std.os.windows.CTRL_BREAK_EVENT => .int,
                std.os.windows.CTRL_CLOSE_EVENT, std.os.windows.CTRL_LOGOFF_EVENT, std.os.windows.CTRL_SHUTDOWN_EVENT => .term,
                else => null,
            };

            if (signal_type) |sig_type| {
                // Set all matching events - ResetEvent.set() can be called from any thread
                for (handlers.items) |entry| {
                    if (entry.signal_type == sig_type) {
                        entry.event.set();
                    }
                }
                return 1; // Signal handled
            }

            return 0; // Not handled
        }
    };
};

// Note: Real signal handling tests would need to actually send signals to the process,
// which is difficult to test in unit tests. Signal handling should be tested via
// integration tests or manual testing.

test {
    std.testing.refAllDecls(@This());
}
