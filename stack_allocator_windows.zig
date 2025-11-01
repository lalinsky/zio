// Windows stack allocator using RtlCreateUserStack
// This provides automatic stack growth via Windows kernel

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const assert = std.debug.assert;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("This module is Windows-only");
    }
}

const INITIAL_TEB = extern struct {
    OldStackBase: ?*anyopaque,
    OldStackLimit: ?*anyopaque,
    StackBase: ?*anyopaque,
    StackLimit: ?*anyopaque,
    StackAllocationBase: ?*anyopaque,
};

extern "ntdll" fn RtlCreateUserStack(
    CommittedStackSize: usize,
    MaximumStackSize: usize,
    ZeroBits: usize,
    PageSize: usize,
    ReserveAlignment: usize,
    InitialTeb: *INITIAL_TEB,
) callconv(.winapi) windows.NTSTATUS;

extern "ntdll" fn RtlFreeUserStack(
    StackAllocationBase: ?*anyopaque,
) callconv(.winapi) void;

pub const WindowsStack = struct {
    base: [*]align(16) u8,        // Top of stack (StackBase)
    limit: [*]align(16) u8,        // Bottom of committed region (StackLimit)
    allocation_base: [*]align(16) u8, // For deallocation
    reserved_size: usize,
    committed_size: usize,

    /// Allocate a new stack with Windows' native RtlCreateUserStack
    /// This automatically sets up guard pages and enables kernel-managed stack growth
    pub fn create(reserved_size: usize, initial_commit: usize) !WindowsStack {
        const PAGE_SIZE = std.mem.page_size;
        const ALLOCATION_GRANULARITY = 65536; // 64 KB on Windows

        var initial_teb: INITIAL_TEB = undefined;

        const status = RtlCreateUserStack(
            initial_commit,
            reserved_size,
            0, // ZeroBits
            PAGE_SIZE,
            ALLOCATION_GRANULARITY, // ReserveAlignment
            &initial_teb,
        );

        if (status != .SUCCESS) {
            return error.StackAllocationFailed;
        }

        const stack_base = @intFromPtr(initial_teb.StackBase.?);
        const stack_limit = @intFromPtr(initial_teb.StackLimit.?);
        const alloc_base = @intFromPtr(initial_teb.StackAllocationBase.?);

        return WindowsStack{
            .base = @ptrFromInt(stack_base),
            .limit = @ptrFromInt(stack_limit),
            .allocation_base = @ptrFromInt(alloc_base),
            .reserved_size = stack_base - alloc_base,
            .committed_size = stack_base - stack_limit,
        };
    }

    /// Free the stack
    pub fn destroy(self: WindowsStack) void {
        RtlFreeUserStack(self.allocation_base);
    }

    /// Get the stack pointer for a new coroutine
    /// Returns pointer to top of usable stack (accounting for data structures)
    pub fn getInitialStackPointer(self: WindowsStack, comptime data_size: usize) [*]align(16) u8 {
        const top = @intFromPtr(self.base);
        const data_ptr = std.mem.alignBackward(usize, top - data_size, 16);
        return @ptrFromInt(data_ptr);
    }

    /// Get TIB fields for context switching
    /// These must be saved/restored when switching between coroutines
    pub fn getTIBFields(self: WindowsStack) TIBFields {
        return TIBFields{
            .stack_base = @intFromPtr(self.base),
            .stack_limit = @intFromPtr(self.limit),
            .deallocation_stack = @intFromPtr(self.allocation_base),
        };
    }
};

pub const TIBFields = struct {
    stack_base: u64,
    stack_limit: u64,
    deallocation_stack: u64,
};

test "WindowsStack creation and destruction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const stack = try WindowsStack.create(8 * 1024 * 1024, 256 * 1024);
    defer stack.destroy();

    // Verify sizes
    try std.testing.expectEqual(8 * 1024 * 1024, stack.reserved_size);
    try std.testing.expect(stack.committed_size >= 256 * 1024);
    try std.testing.expect(stack.committed_size < stack.reserved_size);

    // Verify alignment
    try std.testing.expect(@intFromPtr(stack.base) % 16 == 0);
}

test "WindowsStack TIB fields" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const stack = try WindowsStack.create(8 * 1024 * 1024, 256 * 1024);
    defer stack.destroy();

    const tib_fields = stack.getTIBFields();

    // StackBase should be at the top
    try std.testing.expectEqual(@intFromPtr(stack.base), tib_fields.stack_base);

    // StackLimit should be lower than StackBase (stack grows down)
    try std.testing.expect(tib_fields.stack_limit < tib_fields.stack_base);

    // DeallocationStack should be at the bottom
    try std.testing.expect(tib_fields.deallocation_stack < tib_fields.stack_limit);
}
