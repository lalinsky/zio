const std = @import("std");

pub fn FutureResult(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = enum(u8) { not_set, setting, set };

        state: std.atomic.Value(State) = std.atomic.Value(State).init(.not_set),
        value: T = undefined,
        err: ?anyerror = null,

        pub fn set(self: *Self, result: anyerror!T) bool {
            const prev = self.state.cmpxchgStrong(.not_set, .setting, .release, .monotonic);
            if (prev == null) {
                if (result) |value| {
                    self.value = value;
                    self.err = null;
                } else |error_value| {
                    self.err = error_value;
                }
                self.state.store(.set, .release);
                return true;
            }
            return false;
        }

        pub fn get(self: *const Self) ?anyerror!T {
            if (self.state.load(.acquire) == .set) {
                if (self.err) |e| {
                    return e;
                }
                return self.value;
            }
            return null;
        }
    };
}
