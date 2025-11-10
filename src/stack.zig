const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;

pub const page_size = std.heap.page_size_min;

const STACK_RESERVE_SIZE = 8 * 1024 * 1024; // 8MB

pub const StackPosix = struct {
    allocation: []align(page_size) u8,
    base: usize,
    limit: usize,

    pub fn alloc(maximum_size: usize, committed_size: usize) error{OutOfMemory}!*@This() {
        _ = committed_size; // Ignored on POSIX - we commit everything

        const size = std.math.ceilPowerOfTwo(usize, maximum_size) catch |err| {
            std.log.err("Failed to calculate stack size: {}", .{err});
            return error.OutOfMemory;
        };

        // Allocate extra space for the guard page at the bottom of the stack
        const total_size = size + page_size;

        const allocation = posix.mmap(
            null, // Address hint (null for system to choose)
            total_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1, // File descriptor (not applicable)
            0, // Offset within the file (not applicable)
        ) catch |err| {
            std.log.err("Failed to allocate stack memory: {}", .{err});
            return error.OutOfMemory;
        };
        errdefer posix.munmap(allocation);

        // Protect the first page as a guard page (no read/write access)
        // This will trigger a segfault if the stack overflows
        posix.mprotect(
            allocation.ptr[0..page_size],
            posix.PROT.NONE,
        ) catch |err| {
            std.log.err("Failed to protect guard page: {}", .{err});
            return error.OutOfMemory;
        };

        // Place the Stack metadata at the top of the allocation (high address)
        const self_ptr = std.mem.alignBackward(usize, @intFromPtr(allocation.ptr) + allocation.len - @sizeOf(@This()), @alignOf(@This()));
        const self: *@This() = @ptrFromInt(self_ptr);

        // Stack layout (grows downward from high to low addresses):
        // [guard_page][usable_stack_space][metadata]
        // ^           ^                   ^
        // allocation  limit               base
        self.* = .{
            .allocation = allocation,
            .base = self_ptr, // Top of stack (high address, where metadata is)
            .limit = @intFromPtr(allocation.ptr) + page_size, // Bottom of usable stack (just after guard)
        };

        return self;
    }

    pub fn free(self: *@This()) void {
        posix.munmap(self.allocation);
    }
};

pub const StackWindows = struct {
    allocation: []align(page_size) u8,
    base: usize,
    limit: usize,

    pub fn alloc(maximum_size: usize, committed_size: usize) error{OutOfMemory}!*@This() {
        const max_size = std.math.ceilPowerOfTwo(usize, maximum_size) catch |err| {
            std.log.err("Failed to calculate maximum stack size: {}", .{err});
            return error.OutOfMemory;
        };

        // Round committed size up to page boundary
        const commit_size = std.mem.alignForward(usize, committed_size, page_size);

        // Ensure committed size doesn't exceed maximum size
        if (commit_size > max_size) {
            std.log.err("Committed size ({}) exceeds maximum size ({})", .{ commit_size, max_size });
            return error.OutOfMemory;
        }

        // Reserve address space for maximum size plus guard page
        const total_size = max_size + page_size;

        // Reserve the address space without committing physical memory
        const stack_mem = windows.VirtualAlloc(
            null, // Address hint (null for system to choose)
            total_size,
            windows.MEM_RESERVE,
            windows.PAGE_NOACCESS,
        ) catch |err| {
            std.log.err("Failed to reserve stack memory: {}", .{err});
            return error.OutOfMemory;
        };
        errdefer windows.VirtualFree(stack_mem, 0, windows.MEM_RELEASE);

        // Convert to aligned slice (VirtualAlloc returns 64KB-aligned memory)
        const allocation: []align(page_size) u8 = @alignCast(@as([*]u8, @ptrCast(stack_mem))[0..total_size]);
        const stack_addr = @intFromPtr(allocation.ptr);

        // Calculate the layout:
        // [uncommitted][guard_page][committed][metadata]
        const uncommitted_size = max_size - commit_size;
        const guard_start = stack_addr + uncommitted_size;
        const committed_start = guard_start + page_size;

        // Commit the guard page with PAGE_GUARD attribute
        // This will trigger a one-shot exception if accessed
        _ = windows.VirtualAlloc(
            @ptrFromInt(guard_start),
            page_size,
            windows.MEM_COMMIT,
            windows.PAGE_READWRITE | windows.PAGE_GUARD,
        ) catch |err| {
            std.log.err("Failed to commit guard page: {}", .{err});
            return error.OutOfMemory;
        };

        // Commit the requested portion of the usable stack space
        // The rest remains reserved but uncommitted at the bottom
        _ = windows.VirtualAlloc(
            @ptrFromInt(committed_start),
            commit_size,
            windows.MEM_COMMIT,
            windows.PAGE_READWRITE,
        ) catch |err| {
            std.log.err("Failed to commit stack memory: {}", .{err});
            return error.OutOfMemory;
        };

        // Place the Stack metadata at the top of the allocation (high address)
        const self_ptr = std.mem.alignBackward(usize, stack_addr + total_size - @sizeOf(@This()), @alignOf(@This()));
        const self: *@This() = @ptrFromInt(self_ptr);

        // Stack layout (grows downward from high to low addresses):
        // [uncommitted][guard_page][committed_stack_space][metadata]
        // ^            ^           ^                       ^
        // allocation   guard       limit                   base
        self.* = .{
            .allocation = allocation,
            .base = self_ptr, // Top of stack (high address, where metadata is)
            .limit = committed_start, // Bottom of committed stack (just after guard)
        };

        return self;
    }

    pub fn free(self: *@This()) void {
        windows.VirtualFree(self.allocation.ptr, 0, windows.MEM_RELEASE);
    }
};

pub const Stack = switch (builtin.os.tag) {
    .windows => StackWindows,
    else => StackPosix,
};

test "Stack: alloc/free" {
    const maximum_size = 8192;
    const committed_size = 1024;
    const stack = try Stack.alloc(maximum_size, committed_size);
    defer stack.free();

    // Verify allocation size includes guard page
    try std.testing.expectEqual(page_size + maximum_size, stack.allocation.len);

    // Verify base is at the top (high address)
    try std.testing.expect(stack.base > stack.limit);

    // Verify limit calculation based on platform
    // Note: committed_size gets rounded up to page boundary
    const commit_size_rounded = std.mem.alignForward(usize, committed_size, page_size);
    const expected_limit = switch (builtin.os.tag) {
        // On Windows: [uncommitted][guard][committed][metadata]
        // limit points to start of committed region
        .windows => @intFromPtr(stack.allocation.ptr) + (maximum_size - commit_size_rounded) + page_size,
        // On POSIX: [guard][committed][metadata]
        // limit points to start after guard page
        else => @intFromPtr(stack.allocation.ptr) + page_size,
    };
    try std.testing.expectEqual(expected_limit, stack.limit);

    // Verify base is within the allocation
    try std.testing.expect(stack.base >= @intFromPtr(stack.allocation.ptr));
    try std.testing.expect(stack.base < @intFromPtr(stack.allocation.ptr) + stack.allocation.len);
}
