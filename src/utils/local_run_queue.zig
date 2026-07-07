// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Per-executor local run queue for the work-stealing scheduler (issue #460).
//!
//! Holds `num_stacks` intrusive LIFO stacks plus a drain cursor. One stack is
//! drained at a time (the `pop_cursor` stack); new work is pushed round-robin
//! across the *other* stacks. Draining one stack at a time — with an I/O poll
//! between stacks, done by the caller — is what makes LIFO ordering acceptable:
//! a task re-queued mid-drain (e.g. after a yield) lands in a stack that isn't
//! currently being drained, so it cannot run again until the cursor rotates,
//! which the executor does only after a poll.
//!
//! Concurrency — PHASE 1 (no stealing yet):
//!   * `push` and `pop` are called ONLY by the owning executor thread.
//!   * cross-thread wakes do NOT come here — they go to the runtime global
//!     queue — so the stacks are effectively single-threaded.
//!
//! When stealing is added (phase 2), a thief will drain a whole victim stack
//! with a single atomic `swap(null)`. At that point the owner `pop` below (a
//! plain load/store) becomes unsafe against a concurrent steal and MUST be
//! replaced by the tagged-pointer mutation-lock protocol (option C in #460):
//! the read of `node.next` has to happen while the head is locked so the node
//! cannot be stolen, run, and freed underneath us. This is deliberately NOT
//! done yet — phase 1 only needs to prove the structure doesn't regress.
//!
//! `T` must have a `next: ?*T` field and (in debug builds) an `in_list: bool`.

const std = @import("std");

pub fn LocalRunQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Number of stacks. Comptime-tunable; #460 suggests benchmarking 2/4/8.
        pub const num_stacks = 4;

        stacks: [num_stacks]Stack = @splat(.{}),
        /// Stack currently being drained.
        pop_cursor: usize = 0,
        /// Next round-robin push target; kept off `pop_cursor`.
        push_cursor: usize = 0,

        /// A single lock-free LIFO stack. Push is thread-safe (CAS) so a phase-2
        /// steal's `swap(null)` can race the owner push benignly; the owner pop
        /// is single-threaded-only (see the file header).
        const Stack = struct {
            head: std.atomic.Value(?*T) = std.atomic.Value(?*T).init(null),

            fn push(self: *Stack, node: *T) void {
                var current = self.head.load(.acquire);
                while (true) {
                    node.next = current;
                    if (self.head.cmpxchgWeak(current, node, .release, .acquire)) |actual| {
                        current = actual;
                    } else return;
                }
            }

            /// OWNER-ONLY, and only safe while no steal races this stack (phase 1).
            fn popOwner(self: *Stack) ?*T {
                const node = self.head.load(.acquire) orelse return null;
                self.head.store(node.next, .release);
                node.next = null;
                return node;
            }

            fn isEmpty(self: *const Stack) bool {
                return self.head.load(.acquire) == null;
            }
        };

        /// Push a task. Owner-only. Round-robins across the stacks that are not
        /// currently being drained, so a task re-queued during a drain lands in
        /// a stack the cursor won't revisit until after the next poll.
        pub fn push(self: *Self, node: *T) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(!node.in_list);
                node.in_list = true;
            }
            self.push_cursor = (self.push_cursor + 1) % num_stacks;
            if (self.push_cursor == self.pop_cursor) {
                self.push_cursor = (self.push_cursor + 1) % num_stacks;
            }
            self.stacks[self.push_cursor].push(node);
        }

        /// Pop one task from the current drain stack, or null if it is empty.
        /// Owner-only. Does not rotate the cursor — the caller rotates via
        /// `rotate()` after its I/O poll, so an emptied stack is only revisited
        /// once a poll has happened.
        pub fn pop(self: *Self) ?*T {
            const node = self.stacks[self.pop_cursor].popOwner() orelse return null;
            if (std.debug.runtime_safety) node.in_list = false;
            return node;
        }

        /// True if the current drain stack is empty (the caller uses this to
        /// decide whether to rotate the cursor to the next stack).
        pub fn currentEmpty(self: *const Self) bool {
            return self.stacks[self.pop_cursor].isEmpty();
        }

        /// Advance the drain cursor to the next stack.
        pub fn rotate(self: *Self) void {
            self.pop_cursor = (self.pop_cursor + 1) % num_stacks;
        }

        /// True if every stack is empty (used for the executor's wait/no-wait
        /// I/O poll decision).
        pub fn isEmpty(self: *const Self) bool {
            for (&self.stacks) |*s| {
                if (!s.isEmpty()) return false;
            }
            return true;
        }
    };
}
