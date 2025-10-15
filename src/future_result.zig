const std = @import("std");
const meta = @import("meta.zig");

pub fn FutureResult(comptime T: type) type {
    const E = meta.ErrorSet(T);
    const P = meta.Payload(T);

    return struct {
        const Self = @This();
        const State = enum(u8) { not_set, setting, ok, err };

        state: std.atomic.Value(State) = std.atomic.Value(State).init(.not_set),
        err_value: E = undefined,
        ok_value: P = undefined,

        pub fn set(self: *Self, value: T) bool {
            const prev = self.state.cmpxchgStrong(.not_set, .setting, .release, .monotonic);
            if (prev == null) {
                const is_error_union = @typeInfo(T) == .error_union;
                if (is_error_union) {
                    if (value) |ok| {
                        self.ok_value = ok;
                        self.state.store(.ok, .release);
                    } else |err| {
                        self.err_value = err;
                        self.state.store(.err, .release);
                    }
                } else {
                    self.ok_value = value;
                    self.state.store(.ok, .release);
                }
                return true;
            }
            return false;
        }

        pub fn get(self: *const Self) ?T {
            const state = self.state.load(.acquire);
            const is_error_union = @typeInfo(T) == .error_union;
            if (is_error_union) {
                return switch (state) {
                    .ok => self.ok_value,
                    .err => self.err_value,
                    else => null,
                };
            } else {
                if (state == .ok) {
                    return self.ok_value;
                }
                return null;
            }
        }
    };
}
