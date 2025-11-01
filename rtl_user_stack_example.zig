// Example of using RtlCreateUserStack from Zig
//
// Build: zig build-exe rtl_user_stack_example.zig -target x86_64-windows

const std = @import("std");
const windows = std.os.windows;

// INITIAL_TEB structure (documented in Windows internals)
const INITIAL_TEB = extern struct {
    OldStackBase: ?*anyopaque,
    OldStackLimit: ?*anyopaque,
    StackBase: ?*anyopaque,           // Top of stack (high address)
    StackLimit: ?*anyopaque,          // Bottom of committed region
    StackAllocationBase: ?*anyopaque, // Bottom of reservation (for deallocation)
};

// RtlCreateUserStack from ntdll.dll
extern "ntdll" fn RtlCreateUserStack(
    CommittedStackSize: usize,
    MaximumStackSize: usize,
    ZeroBits: usize,
    PageSize: usize,
    ReserveAlignment: usize,
    InitialTeb: *INITIAL_TEB,
) callconv(.winapi) windows.NTSTATUS;

// RtlFreeUserStack from ntdll.dll
extern "ntdll" fn RtlFreeUserStack(
    StackAllocationBase: ?*anyopaque,
) callconv(.winapi) void;

pub fn main() !void {
    std.debug.print("RtlCreateUserStack Example\n", .{});
    std.debug.print("===========================\n\n", .{});

    const PAGE_SIZE = 4096;
    const ALLOCATION_GRANULARITY = 65536; // 64 KB on Windows
    const STACK_RESERVE = 8 * 1024 * 1024; // 8 MB
    const STACK_COMMIT = 256 * 1024;       // 256 KB initial commit

    var initial_teb: INITIAL_TEB = undefined;

    // Create a user stack using Windows' native API
    // PageSize and ReserveAlignment must be non-zero (ReactOS checks this)
    const status = RtlCreateUserStack(
        STACK_COMMIT,
        STACK_RESERVE,
        0, // ZeroBits
        PAGE_SIZE,
        ALLOCATION_GRANULARITY, // ReserveAlignment (must match allocation granularity)
        &initial_teb,
    );

    if (status != .SUCCESS) {
        std.debug.print("RtlCreateUserStack failed with status: 0x{x}\n", .{@intFromEnum(status)});
        return error.StackCreationFailed;
    }

    std.debug.print("Stack created successfully!\n\n", .{});
    std.debug.print("Stack Details:\n", .{});
    std.debug.print("  StackAllocationBase: 0x{x}\n", .{@intFromPtr(initial_teb.StackAllocationBase.?)});
    std.debug.print("  StackLimit:          0x{x}\n", .{@intFromPtr(initial_teb.StackLimit.?)});
    std.debug.print("  StackBase:           0x{x}\n", .{@intFromPtr(initial_teb.StackBase.?)});

    const reserved = @intFromPtr(initial_teb.StackBase.?) - @intFromPtr(initial_teb.StackAllocationBase.?);
    const committed = @intFromPtr(initial_teb.StackBase.?) - @intFromPtr(initial_teb.StackLimit.?);

    std.debug.print("\n  Total reserved:  {d} MB\n", .{reserved / (1024 * 1024)});
    std.debug.print("  Initial commit:  {d} KB\n", .{committed / 1024});
    std.debug.print("  Uncommitted:     {d} MB\n", .{(reserved - committed) / (1024 * 1024)});

    // Verify guard page exists by checking memory protection
    var mem_info: windows.MEMORY_BASIC_INFORMATION = undefined;
    const query_result = windows.VirtualQuery(
        initial_teb.StackLimit,
        &mem_info,
        @sizeOf(windows.MEMORY_BASIC_INFORMATION),
    ) catch 0;

    if (query_result > 0) {
        std.debug.print("\nMemory at StackLimit:\n", .{});
        std.debug.print("  State: ", .{});
        switch (mem_info.State) {
            windows.MEM_COMMIT => std.debug.print("MEM_COMMIT\n", .{}),
            windows.MEM_RESERVE => std.debug.print("MEM_RESERVE\n", .{}),
            windows.MEM_FREE => std.debug.print("MEM_FREE\n", .{}),
            else => std.debug.print("Unknown (0x{x})\n", .{mem_info.State}),
        }
        std.debug.print("  Protect: 0x{x}", .{mem_info.Protect});

        // Check for PAGE_GUARD flag (0x100)
        if ((mem_info.Protect & 0x100) != 0) {
            std.debug.print(" (PAGE_GUARD set!)\n", .{});
        } else {
            std.debug.print("\n", .{});
        }
    }

    // Clean up
    std.debug.print("\nFreeing stack...\n", .{});
    RtlFreeUserStack(initial_teb.StackAllocationBase);
    std.debug.print("Done!\n", .{});
}
