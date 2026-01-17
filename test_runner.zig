// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
// });

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .warn },
    },
    .logFn = customLogFn,
};

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// Log capture for suppressing logs in passing tests
const LogCapture = struct {
    capture_writer: ?*std.Io.Writer = null,
    mutex: std.Thread.Mutex = .{},

    pub fn logFn(
        self: *@This(),
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const scope_prefix = "(" ++ @tagName(scope) ++ "/" ++ @tagName(level) ++ "): ";

        if (self.capture_writer) |writer| {
            // Write to capture buffer
            writer.print(scope_prefix ++ format ++ "\n", args) catch return;
        } else {
            // Write to stderr (no locking needed, std.debug.print handles it)
            std.debug.print(scope_prefix ++ format ++ "\n", args);
        }
    }

    pub fn startCapture(self: *@This(), writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.capture_writer = writer;
    }

    pub fn stopCapture(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.capture_writer = null;
    }
};

var log_capture = LogCapture{};

pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_capture.logFn(level, scope, format, args);
}

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var env = Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    var log_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer log_buffer.deinit();

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filters.items.len > 0) {
            if (is_unnamed_test) {
                continue;
            }
            var matches = false;
            for (env.filters.items) |f| {
                if (std.mem.indexOf(u8, t.name, f) != null) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                continue;
            }
        }

        const friendly_name = t.name;

        current_test = friendly_name;
        std.testing.allocator_instance = .{};

        if (env.do_log_capture) {
            log_buffer.clearRetainingCapacity();
            log_capture.startCapture(&log_buffer.writer);
        }

        // Print test name before running (for debugging hangs)
        if (env.verbose) {
            Printer.fmt("{s} .. ", .{friendly_name});
        }

        const result = t.func();

        if (env.do_log_capture) {
            log_capture.stopCapture();
        }

        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        var fail_err: ?anyerror = null;
        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                fail_err = err;
            },
        }

        const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
        const status_str = switch (status) {
            .pass => "OK",
            .fail => "FAIL",
            .skip => "SKIP",
            .text => "",
        };
        if (env.verbose) {
            Printer.status(status, "{s}", .{status_str});
            Printer.fmt(" ({d:.2}ms)\n", .{ms});
        } else if (status == .fail) {
            Printer.fmt("{s} .. ", .{friendly_name});
            Printer.status(status, "{s}", .{status_str});
            Printer.fmt(" ({d:.2}ms)\n", .{ms});
        }

        // Print error details after the status line
        if (fail_err) |err| {
            Printer.fmt("{s}\n", .{BORDER});
            Printer.status(.fail, "\"{s}\" - {s}\n", .{ friendly_name, @errorName(err) });

            // Print captured logs for failed tests
            if (log_buffer.written().len > 0) {
                Printer.fmt("Test output:\n{s}", .{log_buffer.written()});
            }

            Printer.fmt("{s}\n", .{BORDER});
            if (@errorReturnTrace()) |trace| {
                if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
                    std.debug.dumpStackTrace(trace.*);
                } else {
                    std.debug.dumpStackTrace(trace);
                }
            }
            if (env.fail_first) {
                break;
            }
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.posix.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        var timer = self.timer;
        const ns = timer.lap();

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filters: std.ArrayList([]const u8),
    do_log_capture: bool,

    fn init(allocator: Allocator) Env {
        var filters: std.ArrayList([]const u8) = .empty;

        if (readEnv(allocator, "TEST_FILTER")) |filter_str| {
            defer allocator.free(filter_str);

            var iter = std.mem.splitScalar(u8, filter_str, '|');
            while (iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len > 0) {
                    const owned = allocator.dupe(u8, trimmed) catch @panic("OOM");
                    filters.append(allocator, owned) catch @panic("OOM");
                }
            }
        }

        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", false),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filters = filters,
            .do_log_capture = readEnvBool(allocator, "TEST_LOG_CAPTURE", true),
        };
    }

    fn deinit(self: *Env, allocator: Allocator) void {
        for (self.filters.items) |f| {
            allocator.free(f);
        }
        self.filters.deinit(allocator);
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
