// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Shared cross-loop socket registration table (single-owner model).
//!
//! A socket fd is monitored in the poller (epoll/kqueue) of exactly *one* loop
//! per direction — the loop that first parked on that `(fd, direction)`. That
//! loop is the "owner": it gets the readiness edges and services every waiter,
//! including completions that were submitted on other loops and handed over at
//! submit time. This avoids registering the same fd on every loop's poller
//! (which task migration would otherwise cause) while staying correct when a
//! socket is driven from different loops over its life.
//!
//! The table is backend-agnostic: it tracks ownership, a per-direction edge
//! readiness latch, and the parked-completion queues. The actual poller syscall
//! (epoll_ctl / kevent) is issued by the backend while holding the fd's shard
//! lock. Read and write are tracked independently so a reader on loop A and a
//! writer on loop B can each own their own direction of the same socket.
//!
//! Entries are keyed by fd and live until the socket is closed (`removeFd`),
//! which any loop may call: closing the fd removes it from every poller at the
//! kernel level, so teardown only has to drop the software bookkeeping.

const std = @import("std");
const os = @import("../os/root.zig");
const Completion = @import("completion.zig").Completion;
const Queue = @import("queue.zig").Queue;

pub const Dir = enum(u1) { read, write };

/// Per-fd registration record. `owner`/`ready`/`waiters` are split per direction
/// but kept in one entry so a single shard lock covers the whole fd and a close
/// drops both directions at once.
pub const Entry = struct {
    /// The loop (opaque `*Loop`) whose poller has this fd registered for the
    /// direction, or null if no loop is registered for it yet.
    read_owner: ?*anyopaque = null,
    write_owner: ?*anyopaque = null,
    /// Edge-triggered readiness latch: set when an edge fired but no waiter
    /// consumed it, so a parker that raced the edge retries instead of sleeping.
    read_ready: bool = false,
    write_ready: bool = false,
    /// Completions parked on this fd/direction, serviced by the owner.
    read_waiters: Queue(Completion) = .{},
    write_waiters: Queue(Completion) = .{},

    pub fn ownerPtr(self: *Entry, dir: Dir) *?*anyopaque {
        return switch (dir) {
            .read => &self.read_owner,
            .write => &self.write_owner,
        };
    }

    pub fn readyPtr(self: *Entry, dir: Dir) *bool {
        return switch (dir) {
            .read => &self.read_ready,
            .write => &self.write_ready,
        };
    }

    pub fn waiters(self: *Entry, dir: Dir) *Queue(Completion) {
        return switch (dir) {
            .read => &self.read_waiters,
            .write => &self.write_waiters,
        };
    }

    /// Whether the entry has nothing left to track and can be dropped.
    pub fn isEmpty(self: *const Entry) bool {
        return self.read_owner == null and self.write_owner == null and
            self.read_waiters.head == null and self.write_waiters.head == null;
    }
};

const shard_count = 64; // power of two

pub const Shard = struct {
    mutex: os.Mutex = .init(),
    map: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
};

/// Sharded fd -> Entry table shared by every loop in a group. Loops acquire it
/// on init and release it on deinit; the maps are freed when the last loop goes.
pub const Table = struct {
    mutex: os.Mutex = .init(),
    refcount: usize = 0,
    allocator: std.mem.Allocator = undefined,
    shards: [shard_count]Shard = [_]Shard{.{}} ** shard_count,

    pub fn acquire(self: *Table, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.refcount == 0) self.allocator = allocator;
        self.refcount += 1;
    }

    pub fn release(self: *Table) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refcount -= 1;
        if (self.refcount == 0) {
            for (&self.shards) |*shard| {
                shard.map.deinit(self.allocator);
                shard.map = .empty;
            }
        }
    }

    pub fn shardForFd(self: *Table, fd: i32) *Shard {
        const key: u32 = @bitCast(fd);
        return &self.shards[key & (shard_count - 1)];
    }
};
