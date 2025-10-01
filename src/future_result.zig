const std = @import("std");

pub fn FutureResult(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = enum(u8) { not_set, set };

        state: std.atomic.Value(State) = std.atomic.Value(State).init(.not_set),
        result: T = undefined,

        pub fn set(self: *Self, value: T) void {
            const prev = self.state.cmpxchgStrong(.not_set, .set, .acq_rel, .monotonic);
            if (prev == null) {
                self.result = value;
            }
        }

        pub fn get(self: *const Self) ?T {
            if (self.state.load(.acquire) == .set) {
                return self.result;
            }
            return null;
        }
    };
}
