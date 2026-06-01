// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Windows coroutine stack pool.
//!
//! Stacks are created per-stack via RtlCreateUserStack, which sets up automatic
//! growth through the PAGE_GUARD mechanism, so there is no manual fault handler.
//! `WindowsStackPool` keeps freed stacks on an intrusive free list (the node is
//! stored inside the unused stack). Stack allocation and deallocation live
//! entirely within the pool struct. The platform-neutral facade lives in `stack.zig`.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("../os/windows.zig");
const os = @import("../os/root.zig");

const stack = @import("stack.zig");
const StackInfo = stack.StackInfo;
const StackExtendMode = stack.StackExtendMode;
const StackPoolConfig = stack.StackPoolConfig;
const page_size = stack.page_size;

const Allocator = std.mem.Allocator;
const Timestamp = @import("../time.zig").Timestamp;
const log = @import("../common.zig").log;

/// Windows handles stack growth automatically via PAGE_GUARD; nothing to do.
/// Exposed for the facade's panicHandler (commit-full before unwinding).
pub fn stackExtend(info: *StackInfo, mode: StackExtendMode) error{StackOverflow}!void {
    _ = info;
    _ = mode;
}

/// A node in the free list, stored at the base of an unused stack.
const FreeNode = struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
    stack_info: StackInfo,
    timestamp: Timestamp,
};

pub const WindowsStackPool = struct {
    config: StackPoolConfig,
    mutex: os.Mutex,
    head: ?*FreeNode,
    tail: ?*FreeNode,
    pool_size: usize,

    /// The `allocator` parameter is unused (free nodes live inside the stacks
    /// themselves) but kept for a uniform interface with PosixStackPool.
    pub fn init(allocator: Allocator, config: StackPoolConfig) WindowsStackPool {
        _ = allocator;
        return .{
            .config = config,
            .mutex = .init(),
            .head = null,
            .tail = null,
            .pool_size = 0,
        };
    }

    pub fn deinit(self: *WindowsStackPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all stacks in the pool
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.freeStack(node.stack_info);
            current = next;
        }

        self.head = null;
        self.tail = null;
        self.pool_size = 0;
    }

    /// No-op on Windows (stack growth is automatic via PAGE_GUARD). Present for
    /// interface parity with PosixStackPool.setup.
    pub fn setup() !void {}

    /// No-op on Windows (nothing to clean up).
    pub fn teardown() void {}

    /// Allocate a fresh stack via RtlCreateUserStack.
    fn allocStack(self: *WindowsStackPool) error{OutOfMemory}!StackInfo {
        const commit_size = std.mem.alignForward(usize, self.config.committed_size, page_size);
        const max_size = std.mem.alignForward(usize, self.config.maximum_size, page_size);

        if (commit_size > max_size) {
            log.err("Committed size ({d}) exceeds maximum size ({d}) after alignment", .{ commit_size, max_size });
            return error.OutOfMemory;
        }

        const ALLOCATION_GRANULARITY = 65536; // 64KB on Windows
        var initial_teb: w.INITIAL_TEB = undefined;
        const status = w.RtlCreateUserStack(commit_size, max_size, 0, page_size, ALLOCATION_GRANULARITY, &initial_teb);
        if (status != .SUCCESS) {
            log.err("RtlCreateUserStack failed with status: 0x{x}", .{@intFromEnum(status)});
            return error.OutOfMemory;
        }

        const stack_base = @intFromPtr(initial_teb.StackBase);
        const alloc_base = @intFromPtr(initial_teb.StackAllocationBase);
        return .{
            .allocation_ptr = @ptrCast(@alignCast(initial_teb.StackAllocationBase)),
            .base = stack_base,
            .limit = @intFromPtr(initial_teb.StackLimit),
            .allocation_len = stack_base - alloc_base,
        };
    }

    /// Return a stack's address space to the OS.
    fn freeStack(_: *WindowsStackPool, info: StackInfo) void {
        w.RtlFreeUserStack(info.allocation_ptr);
    }

    /// Acquires a stack from the pool, or allocates a new one if the pool is empty.
    /// All stacks from this pool have the configured maximum_size and committed_size.
    pub fn acquire(self: *WindowsStackPool) error{OutOfMemory}!StackInfo {
        // Try to get from pool under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |node| {
                const stack_info = node.stack_info;
                self.removeNode(node);
                return stack_info;
            }
        }

        // Pool was empty, allocate new stack outside the lock
        return self.allocStack();
    }

    /// Releases a stack back to the pool.
    /// Expired stacks are removed before adding the new stack to avoid depleting the pool.
    /// If the pool is full, frees the oldest stack and adds this one.
    /// If the stack's committed region is too small to store the FreeNode, the stack is freed instead.
    pub fn release(self: *WindowsStackPool, stack_info: StackInfo, timestamp: Timestamp) void {
        // Check if the stack has enough committed space to store the FreeNode
        // The FreeNode is stored at the base of the stack (aligned backward)
        const node_addr = std.mem.alignBackward(usize, stack_info.base - @sizeOf(FreeNode), @alignOf(FreeNode));

        // Verify the FreeNode fits within the committed region (between limit and base)
        if (node_addr < stack_info.limit) {
            // Stack is too small to hold the FreeNode, free it instead of pooling
            self.freeStack(stack_info);
            return;
        }

        // Store the FreeNode at the base of the stack
        const node = @as(*FreeNode, @ptrFromInt(node_addr));
        node.* = .{
            .prev = null,
            .next = null,
            .stack_info = stack_info,
            .timestamp = timestamp,
        };

        // Collect stacks to free in a temporary singly-linked list
        // Limit how many we free per call to bound latency
        const max_free_per_release = 4;
        var to_free_head: ?*FreeNode = null;
        var to_free_count: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Remove expired stacks from the front of the list (up to limit)
            // Do this before adding the new stack to avoid the situation where we'd
            // remove all stacks (including the one we're about to add) and end up with an empty pool
            if (self.config.max_age.value > 0) {
                while (self.head) |expired| {
                    if (to_free_count >= max_free_per_release) break;
                    const age = expired.timestamp.durationTo(timestamp);
                    if (age.value > self.config.max_age.value) {
                        self.removeNode(expired);
                        expired.next = to_free_head;
                        to_free_head = expired;
                        to_free_count += 1;
                    } else {
                        // List is ordered by timestamp, so we can stop
                        break;
                    }
                }
            }

            // If pool is at capacity and under limit, remove the oldest stack
            if (self.pool_size >= self.config.max_unused_stacks and to_free_count < max_free_per_release) {
                if (self.head) |oldest| {
                    self.removeNode(oldest);
                    oldest.next = to_free_head;
                    to_free_head = oldest;
                    to_free_count += 1;
                }
            }

            // Add to the tail of the list (most recently released)
            self.addNode(node);
        }

        // Free collected stacks - no lock held
        while (to_free_head) |free_node| {
            const next = free_node.next;
            self.freeStack(free_node.stack_info);
            to_free_head = next;
        }
    }

    /// Evicts up to `limit` expired stacks from the pool.
    /// Intended to be called periodically from a timer to reclaim idle stacks.
    pub fn cleanup(self: *WindowsStackPool, now: Timestamp, limit: usize) void {
        if (self.config.max_age.value == 0) return;

        var to_free_head: ?*FreeNode = null;
        var to_free_count: usize = 0;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.head) |node| {
                if (to_free_count >= limit) break;
                const age = node.timestamp.durationTo(now);
                if (age.value > self.config.max_age.value) {
                    self.removeNode(node);
                    node.next = to_free_head;
                    to_free_head = node;
                    to_free_count += 1;
                } else {
                    break;
                }
            }
        }

        while (to_free_head) |free_node| {
            const next = free_node.next;
            self.freeStack(free_node.stack_info);
            to_free_head = next;
        }
    }

    /// Removes a node from the doubly linked list and updates pool_size.
    fn removeNode(self: *WindowsStackPool, node: *FreeNode) void {
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            // This is the head
            self.head = node.next;
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            // This is the tail
            self.tail = node.prev;
        }

        self.pool_size -= 1;
    }

    /// Adds a node to the tail of the doubly linked list and updates pool_size.
    fn addNode(self: *WindowsStackPool, node: *FreeNode) void {
        node.prev = self.tail;
        node.next = null;

        if (self.tail) |tail| {
            tail.next = node;
        } else {
            // List is empty
            self.head = node;
        }

        self.tail = node;
        self.pool_size += 1;
    }
};

/// The pool selected for this platform (see stack.zig).
pub const StackPool = WindowsStackPool;
