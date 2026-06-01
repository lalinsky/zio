// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Platform-neutral facade for coroutine stack management.
//!
//! Shared types (`StackInfo`, `StackPoolConfig`) and the standalone alloc/free/extend
//! API live here; the actual allocation lives in the per-platform backends
//! (`stack_posix.zig` / `stack_windows.zig`) selected by `impl`. Valgrind stack
//! bookkeeping for the standalone API is applied here so both backends stay
//! free of it. `StackPool` resolves to the backend's pool implementation.

const std = @import("std");
const builtin = @import("builtin");
const coroutines = @import("coroutines.zig");

pub const page_size = if (builtin.os.tag == .freestanding) 1 else std.heap.page_size_min;

const impl = if (builtin.os.tag == .windows)
    @import("stack_windows.zig")
else
    @import("stack_posix.zig");

pub const StackInfo = extern struct {
    allocation_ptr: [*]align(page_size) u8, // deallocation_stack on Windows (TEB offset 0x1478)
    base: usize, // stack_base on Windows (TEB offset 0x08)
    limit: usize, // stack_limit on Windows (TEB offset 0x10)
    allocation_len: usize,
    valgrind_stack_id: usize = 0,
    // Opaque value owned by the stack pool, used to locate the backing
    // allocation in O(1) on release (e.g. the POSIX slab pointer).
    // void on Windows where the per-stack pool needs no back-pointer.
    pool_cookie: if (builtin.os.tag == .windows) void else usize = if (builtin.os.tag == .windows) {} else 0,
};

pub const StackExtendMode = enum {
    /// Grow by 1.5x the current committed size (default incremental growth)
    grow,
    /// Commit the entire remaining uncommitted stack
    full,
};

pub const StackPoolConfig = struct {
    /// Maximum size of stacks in this pool (in bytes).
    /// This is the total virtual address space reserved for each stack.
    maximum_size: usize,

    /// Initial committed size of stacks in this pool (in bytes).
    /// This is the amount of physical memory initially committed.
    committed_size: usize,

    /// Maximum number of unused stacks to keep in the pool.
    /// When this limit is exceeded, the oldest stack is freed.
    max_unused_stacks: usize = 16,

    /// Number of stacks carved from a single mmap reservation (slab).
    /// Batching amortizes the per-stack mmap/munmap syscall cost, which
    /// dominates short-lived workloads (CLI tools). 0 selects an
    /// implementation default. Only honored by the POSIX slab allocator.
    slab_stacks: usize = 0,

    /// Maximum age of an unused stack.
    /// Stacks older than this will be freed on the next release() call.
    /// .zero means no age limit.
    max_age: @import("../time.zig").Duration = .zero,
};

/// Coroutine stack pool. On Windows, stacks are created per-stack via
/// RtlCreateUserStack; on POSIX, they are carved from batched mmap slabs to
/// amortize syscall cost. Both expose the same init/deinit/acquire/release/
/// cleanup interface.
pub const StackPool = impl.StackPool;

/// Panic handler that ensures coroutine stacks are fully committed before unwinding.
/// This prevents SIGSEGV during stack trace generation when the default panic handler
/// resets signal handlers.
///
/// Usage in your root file:
///   pub const panic = zio.coro.panicHandler;
///
pub fn panicHandler(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;

    if (coroutines.current_context) |ctx| {
        impl.stackExtend(&ctx.stack_info, .full) catch {};
    }

    std.debug.defaultPanic(msg, ret_addr);
}

test "Stack: automatic growth through the pool" {
    // Exercises growth end-to-end via StackPool on both platforms: the
    // SIGSEGV/SIGBUS handler on POSIX, PAGE_GUARD on Windows.
    try StackPool.setup();
    defer StackPool.teardown();

    var parent_context: coroutines.Context = undefined;
    var coro: coroutines.Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };

    // Small initial commit, large maximum, so the coroutine forces growth.
    var pool = StackPool.init(std.testing.allocator, .{
        .maximum_size = 256 * 1024,
        .committed_size = 4096,
        .slab_stacks = 1,
    });
    defer pool.deinit();
    coro.context.stack_info = try pool.acquire();
    defer pool.release(coro.context.stack_info, .zero);

    const initial_committed = coro.context.stack_info.base - coro.context.stack_info.limit;

    const RecursiveFn = struct {
        noinline fn recurse(c: *coroutines.Coroutine, depth: u32, target: u32) u32 {
            var buffer: [1024]u8 = undefined;
            // volatile pointer forces the 1KB frame to actually exist on the stack
            const p: *volatile [1024]u8 = &buffer;
            p[depth & 0xFF] = @intCast(depth & 0xFF);
            if (depth >= target) return p[0];
            // Use result after volatile read to prevent tail-call optimization
            const result = recurse(c, depth + 1, target);
            return result +% p[depth & 0xFF] -% p[depth & 0xFF];
        }
        fn start(c: *coroutines.Coroutine, target: u32) u32 {
            return recurse(c, 0, target);
        }
    };

    const Closure = coroutines.Closure(RecursiveFn.start);
    var closure = Closure.init(.{100}); // ~100KB, far past the 4KB initial commit
    coro.setup(&Closure.start, &closure);

    while (!closure.finished) {
        coro.step();
    }

    const final_committed = coro.context.stack_info.base - coro.context.stack_info.limit;
    try std.testing.expect(final_committed >= initial_committed);
}
