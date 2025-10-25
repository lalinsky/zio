const std = @import("std");
const builtin = @import("builtin");

const Backend = switch (builtin.os.tag) {
    .linux => @import("backends/epoll.zig"),
    else => @compileError("Unsupported OS"),
};

const RunMode = enum {
    no_wait,
    once,
    until_done,
};

const Loop = struct {
    state: State,
    backend: Backend,

    const State = packed struct {
        initialized: bool = false,
        running: bool = false,
        stopped: bool = false,
    };

    pub fn init(self: *Loop) !void {
        self.* = .{
            .state = .{},
            .backend = undefined,
        };

        try self.backend.init();
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
        return self.state.stopped;
    }

    /// Run the event loop. See RunMode documentation for details on modes.
    /// Once the loop is run, the pointer MUST remain stable.
    pub fn run(self: *Loop, mode: RunMode) !void {
        std.debug.assert(self.state.initialized);
        switch (mode) {
            .no_wait => try self.tick(false),
            .once => try self.tick(true),
            .until_done => while (!self.done()) try self.tick(true),
        }
    }

    fn tick(self: *Loop, can_block: bool) !void {
        while (!self.state.stopped) {
            if (!can_block) break;
        }
    }
};

test "Loop: run" {
    var loop: Loop = undefined;
    try loop.init();
    defer loop.deinit();

    try loop.run(.no_wait);
}
