const std = @import("std");
const Heap = @import("heap.zig").Heap;
const HeapNode = @import("heap.zig").HeapNode;
const Completion = @import("completion.zig").Completion;
const Cancelable = @import("completion.zig").Cancelable;

pub const TimerError = Cancelable;

pub const Timer = struct {
    c: Completion,
    result: TimerError!void = undefined,
    delay_ms: u64,
    deadline_ms: u64 = 0,
    heap: HeapNode(Timer) = .{},

    pub fn init(delay_ms: u64) Timer {
        return .{
            .c = .init(.timer),
            .delay_ms = delay_ms,
        };
    }

    pub fn fromCompletion(c: *Completion) *Timer {
        std.debug.assert(c.op == .timer);
        return @fieldParentPtr("c", c);
    }
};

pub fn timerDeadlineLess(_: void, a: *Timer, b: *Timer) bool {
    return a.deadline_ms < b.deadline_ms;
}

pub const TimerHeap = Heap(Timer, void, timerDeadlineLess);
