const std = @import("std");
const assert = std.debug.assert;
const Heap = @import("heap.zig").Heap;

/// Where a timer is held in a `TimerWheel`.
pub const WheelLoc = enum(u8) { none, near, slot, far };

/// A timer store with the same interface as `Heap` that keeps the timers due
/// soon in a small heap and the rest in coarse slots.
///
/// Time is cut into slots of `1 << slot_shift` nanoseconds, numbered from the
/// epoch of the deadlines. `cursor` is the slot the last `advance` reached:
///
/// - `near`, a pairing heap, holds everything due up to the end of the cursor
///   slot, so the timers that fire next are in exact deadline order.
/// - `slots` hold the next `slot_count - 1` slots as unordered lists, which
///   makes insert and remove O(1). A slot is sorted into `near` only once the
///   cursor reaches it.
/// - `far`, a second pairing heap, holds everything past the wheel, and feeds
///   it as the cursor moves.
///
/// The cursor only moves forward, and only to the current time, so a timer
/// set far out never drags it ahead of the timers that are due sooner.
///
/// T needs `deadline: Timestamp`, `heap: HeapNode(T)` and `wheel_loc: WheelLoc`.
/// A slot list links through `heap.prev`/`heap.next`. All methods but
/// `isEmpty` must be called under the caller's lock.
pub fn TimerWheel(
    comptime T: type,
    comptime less: *const fn (ctx: void, a: *T, b: *T) bool,
    comptime slot_shift: u6,
    comptime slot_count: usize,
) type {
    comptime assert(std.math.isPowerOfTwo(slot_count) and slot_count >= 64);

    return struct {
        const Self = @This();
        const TimerHeap = Heap(T, void, less);
        const mask = slot_count - 1;
        const words = slot_count / 64;

        near: TimerHeap = .{ .context = {} },
        far: TimerHeap = .{ .context = {} },
        slots: [slot_count]?*T = @splat(null),
        /// One bit per slot with a non-empty list.
        occupied: [words]u64 = @splat(0),
        cursor: u64 = 0,
        /// Atomic so `isEmpty` can be read without the caller's lock.
        count: std.atomic.Value(usize) = .init(0),

        fn slotOf(v: *const T) u64 {
            return v.deadline.value >> slot_shift;
        }

        /// Lock-free emptiness check with the same contract as `Heap.isEmpty`:
        /// a stale non-empty read only costs a locked re-check, and an empty
        /// read is real, since only the owner thread inserts.
        pub fn isEmpty(self: *const Self) bool {
            return self.count.load(.acquire) == 0;
        }

        pub fn insert(self: *Self, v: *T) void {
            assert(v.wheel_loc == .none);
            self.place(v);
            _ = self.count.fetchAdd(1, .release);
        }

        pub fn remove(self: *Self, v: *T) void {
            switch (v.wheel_loc) {
                .none => unreachable,
                .near => self.near.remove(v),
                .far => self.far.remove(v),
                .slot => self.unlink(v),
            }
            v.wheel_loc = .none;
            v.heap = .{};
            _ = self.count.fetchSub(1, .release);
        }

        /// The timer due first, or null when there is none.
        pub fn peek(self: *Self) ?*T {
            if (self.near.peek()) |v| return v;
            if (self.nextOccupied()) |idx| {
                var best = self.slots[idx].?;
                var it = best.heap.next;
                while (it) |v| : (it = v.heap.next) {
                    if (less({}, v, best)) best = v;
                }
                return best;
            }
            return self.far.peek();
        }

        /// Move the cursor to the slot of `now`, sorting every slot it passes
        /// into `near` and pulling what comes within reach out of `far`.
        pub fn advance(self: *Self, now: u64) void {
            const target = now >> slot_shift;
            if (target <= self.cursor) return;
            while (self.nextOccupied()) |idx| {
                const abs = self.cursor + 1 + ((@as(u64, idx) -% (self.cursor + 1)) & mask);
                if (abs > target) break;
                self.cursor = abs;
                self.drainSlot(idx);
            }
            self.cursor = target;
            while (self.far.peek()) |v| {
                if (slotOf(v) >= self.cursor + slot_count) break;
                self.far.remove(v);
                v.heap = .{};
                self.place(v);
            }
        }

        fn place(self: *Self, v: *T) void {
            const s = slotOf(v);
            if (s <= self.cursor) {
                v.wheel_loc = .near;
                self.near.insert(v);
            } else if (s < self.cursor + slot_count) {
                const idx: usize = @intCast(s & mask);
                v.wheel_loc = .slot;
                v.heap = .{ .next = self.slots[idx] };
                if (self.slots[idx]) |head| head.heap.prev = v;
                self.slots[idx] = v;
                self.occupied[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
            } else {
                v.wheel_loc = .far;
                self.far.insert(v);
            }
        }

        fn unlink(self: *Self, v: *T) void {
            const idx: usize = @intCast(slotOf(v) & mask);
            if (v.heap.next) |next| next.heap.prev = v.heap.prev;
            if (v.heap.prev) |prev| {
                prev.heap.next = v.heap.next;
            } else {
                assert(self.slots[idx] == v);
                self.slots[idx] = v.heap.next;
                if (v.heap.next == null) self.occupied[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
            }
        }

        fn drainSlot(self: *Self, idx: usize) void {
            var it = self.slots[idx];
            self.slots[idx] = null;
            self.occupied[idx / 64] &= ~(@as(u64, 1) << @intCast(idx % 64));
            while (it) |v| {
                it = v.heap.next;
                v.heap = .{};
                v.wheel_loc = .near;
                self.near.insert(v);
            }
        }

        /// The first occupied slot after the cursor, in wheel order.
        fn nextOccupied(self: *const Self) ?usize {
            const start: usize = @intCast((self.cursor + 1) & mask);
            var w = start / 64;
            var bits = self.occupied[w] & (~@as(u64, 0) << @intCast(start % 64));
            for (0..words + 1) |_| {
                if (bits != 0) return w * 64 + @ctz(bits);
                w = (w + 1) % words;
                bits = self.occupied[w];
            }
            return null;
        }
    };
}

const Elem = struct {
    deadline: struct { value: u64 },
    heap: @import("heap.zig").HeapNode(Elem) = .{},
    wheel_loc: WheelLoc = .none,

    fn less(_: void, a: *Elem, b: *Elem) bool {
        return a.deadline.value < b.deadline.value;
    }
};

const TestWheel = TimerWheel(Elem, Elem.less, 4, 64);

fn popDue(w: *TestWheel, now: u64) ?*Elem {
    w.advance(now);
    const v = w.peek() orelse return null;
    if (v.deadline.value > now) return null;
    w.remove(v);
    return v;
}

test "TimerWheel fires in deadline order across near, slots and far" {
    var w: TestWheel = .{};
    var elems: [200]Elem = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (&elems) |*e| e.* = .{ .deadline = .{ .value = r.uintLessThan(u64, 5000) } };
    for (&elems) |*e| w.insert(e);

    var now: u64 = 0;
    var last: u64 = 0;
    var fired: usize = 0;
    while (fired < elems.len) : (now += 7) {
        while (popDue(&w, now)) |e| {
            try std.testing.expect(e.deadline.value >= last);
            try std.testing.expect(e.deadline.value <= now);
            last = e.deadline.value;
            fired += 1;
        }
    }
    try std.testing.expect(w.isEmpty());
}

test "TimerWheel remove from every location" {
    var w: TestWheel = .{};
    w.advance(1000);
    var near: Elem = .{ .deadline = .{ .value = 1001 } };
    var slot_a: Elem = .{ .deadline = .{ .value = 1100 } };
    var slot_b: Elem = .{ .deadline = .{ .value = 1101 } };
    var far: Elem = .{ .deadline = .{ .value = 100_000 } };
    w.insert(&near);
    w.insert(&slot_a);
    w.insert(&slot_b);
    w.insert(&far);
    try std.testing.expectEqual(WheelLoc.near, near.wheel_loc);
    try std.testing.expectEqual(WheelLoc.slot, slot_a.wheel_loc);
    try std.testing.expectEqual(WheelLoc.far, far.wheel_loc);

    w.remove(&slot_b);
    try std.testing.expectEqual(&near, w.peek().?);
    w.remove(&near);
    try std.testing.expectEqual(&slot_a, w.peek().?);
    w.remove(&slot_a);
    try std.testing.expectEqual(&far, w.peek().?);
    w.remove(&far);
    try std.testing.expect(w.isEmpty());
    try std.testing.expectEqual(@as(?*Elem, null), w.peek());
}

test "TimerWheel insert behind the cursor goes to near" {
    var w: TestWheel = .{};
    w.advance(5000);
    var late: Elem = .{ .deadline = .{ .value = 10 } };
    var soon: Elem = .{ .deadline = .{ .value = 5050 } };
    w.insert(&soon);
    w.insert(&late);
    try std.testing.expectEqual(&late, popDue(&w, 5000).?);
    try std.testing.expectEqual(@as(?*Elem, null), popDue(&w, 5000));
    try std.testing.expectEqual(&soon, popDue(&w, 5050).?);
}
