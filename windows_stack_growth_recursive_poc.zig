// Windows automatic stack growth PoC using RtlCreateUserStack
// Demonstrates kernel-managed stack expansion via guard pages
//
// Build: zig build-exe windows_stack_growth_recursive_poc.zig -target x86_64-windows

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("This PoC only works on Windows");
    }
}

const STACK_RESERVE_SIZE = 8 * 1024 * 1024; // 8 MB
const INITIAL_COMMIT_SIZE = 256 * 1024;     // 256 KB

// INITIAL_TEB structure
const INITIAL_TEB = extern struct {
    OldStackBase: ?*anyopaque,
    OldStackLimit: ?*anyopaque,
    StackBase: ?*anyopaque,
    StackLimit: ?*anyopaque,
    StackAllocationBase: ?*anyopaque,
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

const Context = extern struct {
    rsp: u64,
    rbp: u64,
    rip: u64,
};

const CoroutineData = struct {
    func: *const fn (*CoroutineData) callconv(.c) noreturn,
    depth: u32,
    stack_base: u64,
    initial_teb: *INITIAL_TEB,
};

// Update TIB (Thread Information Block) fields for Windows stack management
fn updateTIBFields(stack_limit: u64, stack_base: u64, deallocation_stack: u64) void {
    const teb = windows.teb();
    teb.NtTib.StackBase = @ptrFromInt(stack_base);
    teb.NtTib.StackLimit = @ptrFromInt(stack_limit);

    // DeallocationStack is not exposed in Zig's TEB struct, use inline asm
    asm volatile (
        \\ movq %[deallocation_stack], %%gs:0x1478
        :
        : [deallocation_stack] "r" (deallocation_stack),
    );
}

// Context switch implementation
fn switchContext(
    noalias current_context: *Context,
    noalias new_context: *Context,
) void {
    asm volatile (
        \\ leaq 0f(%%rip), %%rdx
        \\ movq %%rsp, 0(%%rax)
        \\ movq %%rbp, 8(%%rax)
        \\ movq %%rdx, 16(%%rax)
        \\
        \\ movq 0(%%rcx), %%rsp
        \\ movq 8(%%rcx), %%rbp
        \\ jmpq *16(%%rcx)
        \\0:
        :
        : [current] "{rax}" (current_context),
          [new] "{rcx}" (new_context),
        : .{
          .rax = true,
          .rcx = true,
          .rdx = true,
          .rbx = true,
          .rdi = true,
          .rsi = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .r12 = true,
          .r13 = true,
          .r14 = true,
          .r15 = true,
          .mm0 = true,
          .mm1 = true,
          .mm2 = true,
          .mm3 = true,
          .mm4 = true,
          .mm5 = true,
          .mm6 = true,
          .mm7 = true,
          .zmm0 = true,
          .zmm1 = true,
          .zmm2 = true,
          .zmm3 = true,
          .zmm4 = true,
          .zmm5 = true,
          .zmm6 = true,
          .zmm7 = true,
          .zmm8 = true,
          .zmm9 = true,
          .zmm10 = true,
          .zmm11 = true,
          .zmm12 = true,
          .zmm13 = true,
          .zmm14 = true,
          .zmm15 = true,
          .zmm16 = true,
          .zmm17 = true,
          .zmm18 = true,
          .zmm19 = true,
          .zmm20 = true,
          .zmm21 = true,
          .zmm22 = true,
          .zmm23 = true,
          .zmm24 = true,
          .zmm25 = true,
          .zmm26 = true,
          .zmm27 = true,
          .zmm28 = true,
          .zmm29 = true,
          .zmm30 = true,
          .zmm31 = true,
          .fpsr = true,
          .fpcr = true,
          .mxcsr = true,
          .rflags = true,
          .dirflag = true,
          .memory = true,
        }
    );
}

// Coroutine entry point
fn coroEntry() callconv(.naked) noreturn {
    asm volatile (
        \\ subq $32, %%rsp
        \\ pushq $0
        \\ leaq 40(%%rsp), %%rcx
        \\ jmpq *40(%%rsp)
    );
}

// Recursive function to trigger stack growth
fn recursiveTask(data: *CoroutineData) callconv(.c) noreturn {
    const depth = data.depth;

    // Allocate a chunk on stack to make growth visible
    var buffer: [16384]u8 = undefined;
    @memset(&buffer, @intCast(depth & 0xFF));

    // Get current stack pointer
    var rsp: u64 = undefined;
    asm volatile ("movq %%rsp, %[rsp]"
        : [rsp] "=r" (rsp),
    );

    const stack_used = data.stack_base - rsp;

    // Read current StackLimit from TIB (updated by Windows when stack grows)
    const teb = windows.teb();
    const current_stack_limit = @intFromPtr(teb.NtTib.StackLimit);
    const committed = data.stack_base - current_stack_limit;

    std.debug.print("Depth {d:3}: RSP=0x{x:0>16} Used={d:6} bytes Committed={d:6} bytes\n", .{
        depth,
        rsp,
        stack_used,
        committed,
    });

    // Recurse to trigger automatic stack growth
    if (depth < 50) {
        data.depth = depth + 1;
        return recursiveTask(data);
    }

    std.debug.print("\nStack growth completed successfully!\n", .{});
    std.debug.print("Final committed size: {d} KB (started with {d} KB)\n", .{
        committed / 1024,
        INITIAL_COMMIT_SIZE / 1024,
    });
    std.debug.print("Total stack used: {d} KB\n", .{stack_used / 1024});
    std.debug.print("\nWindows kernel automatically grew the stack via guard page mechanism!\n", .{});

    std.process.exit(0);
}

pub fn main() !void {
    std.debug.print("Windows Automatic Stack Growth PoC\n", .{});
    std.debug.print("===================================\n\n", .{});

    const PAGE_SIZE = 4096;
    const ALLOCATION_GRANULARITY = 65536;

    var initial_teb: INITIAL_TEB = undefined;

    // Create stack using RtlCreateUserStack
    const status = RtlCreateUserStack(
        INITIAL_COMMIT_SIZE,
        STACK_RESERVE_SIZE,
        0,
        PAGE_SIZE,
        ALLOCATION_GRANULARITY,
        &initial_teb,
    );

    if (status != .SUCCESS) {
        std.debug.print("RtlCreateUserStack failed with status: 0x{x}\n", .{@intFromEnum(status)});
        return error.StackCreationFailed;
    }

    const stack_base = @intFromPtr(initial_teb.StackBase.?);
    const stack_limit = @intFromPtr(initial_teb.StackLimit.?);
    const alloc_base = @intFromPtr(initial_teb.StackAllocationBase.?);

    std.debug.print("Stack created with RtlCreateUserStack:\n", .{});
    std.debug.print("  StackBase:       0x{x:0>16}\n", .{stack_base});
    std.debug.print("  StackLimit:      0x{x:0>16}\n", .{stack_limit});
    std.debug.print("  AllocBase:       0x{x:0>16}\n", .{alloc_base});
    std.debug.print("  Reserved:        {d} MB\n", .{(stack_base - alloc_base) / (1024 * 1024)});
    std.debug.print("  Initial commit:  {d} KB\n", .{(stack_base - stack_limit) / 1024});
    std.debug.print("\nStarting recursive test (Windows will auto-grow stack)...\n\n", .{});

    // Set up coroutine data at top of stack
    const data_addr = stack_base - @sizeOf(CoroutineData) - 64;
    const data_ptr: *CoroutineData = @ptrFromInt(data_addr);
    data_ptr.* = .{
        .func = recursiveTask,
        .depth = 1,
        .stack_base = stack_base,
        .initial_teb = &initial_teb,
    };

    // Initialize coroutine context
    var coro_context = Context{
        .rsp = @intFromPtr(data_ptr),
        .rbp = 0,
        .rip = @intFromPtr(&coroEntry),
    };

    // Save main thread context
    var main_context: Context = undefined;

    // Update TIB fields so Windows kernel knows about our custom stack
    // This is critical for automatic stack growth via PAGE_GUARD
    updateTIBFields(stack_limit, stack_base, alloc_base);

    // Switch to coroutine - Windows will handle stack growth automatically
    switchContext(&main_context, &coro_context);

    unreachable;
}
