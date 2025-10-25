const std = @import("std");
const builtin = @import("builtin");

state: State = .{},
backend: Backend,

const State = packed struct {
    /// True once it is initialized.
    initialized: bool = false,

    /// Whether we're in a run or not (to prevent nested runs).
    running: bool = false,

    /// Whether our loop is in a stopped state or not.
    stopped: bool = false,
};

const Backend = switch (builtin.os.tag) {
    .linux => @import("backends/epoll.zig"),
    .else => @compileError("Unsupported OS"),
};


pub fn init() !Loop {
    return .{
        .backend = try Backend.init(),
    };
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

/// Run the event loop. See RunMode documentation for details on modes.
/// Once the loop is run, the pointer MUST remain stable.
pub fn run(self: *Loop, mode: RunMode) !void {
    switch (mode) {
        .no_wait => try self.tick(0),
        .once => try self.tick(1),
        .until_done => while (!self.done()) try self.tick(1),
    }
}

