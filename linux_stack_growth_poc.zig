// Linux lazy stack growth PoC using SIGSEGV handler
// Demonstrates true lazy commit with PROT_NONE + mprotect
//
// Build: zig build-exe linux_stack_growth_poc.zig -target x86_64-linux

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("This PoC only works on Linux");
    }
}

const STACK_RESERVE_SIZE = 8 * 1024 * 1024; // 8 MB
const INITIAL_COMMIT_SIZE = 256 * 1024;     // 256 KB
const COMMIT_CHUNK_SIZE = 64 * 1024;        // Commit 64 KB at a time on fault
const PAGE_SIZE = 4096;

const Context = extern struct {
    rsp: u64,
    rbp: u64,
    rip: u64,
};

const CoroutineData = struct {
    func: *const fn (*CoroutineData) callconv(.c) noreturn,
    depth: u32,
    stack_base: u64,
    stack_reserve_bottom: u64,
    current_limit: u64, // Lowest committed address
};

// Global state for signal handler
var g_stack_base: u64 = 0;
var g_stack_bottom: u64 = 0;
var g_current_limit: u64 = 0;

// Signal handler for SIGSEGV
fn sigsegvHandler(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = ctx_ptr;

    const fault_addr = @intFromPtr(info.fields.sigfault.addr);

    // Check if fault is within our reserved stack region
    if (fault_addr >= g_stack_bottom and fault_addr < g_current_limit) {
        // Calculate chunk to commit (align down to COMMIT_CHUNK_SIZE)
        const chunk_start = std.mem.alignBackward(usize, fault_addr, COMMIT_CHUNK_SIZE);
        const chunk_end = chunk_start + COMMIT_CHUNK_SIZE;

        // Make sure we don't go below stack bottom
        const commit_start = @max(chunk_start, g_stack_bottom);
        const commit_size = chunk_end - commit_start;

        // Commit the chunk
        const addr: [*]align(PAGE_SIZE) u8 = @ptrFromInt(commit_start);
        posix.mprotect(addr[0..commit_size], posix.PROT.READ | posix.PROT.WRITE) catch {
            std.debug.print("FATAL: mprotect failed in signal handler\n", .{});
            std.process.exit(1);
        };

        // Update current limit
        g_current_limit = commit_start;

        // Note: Can't safely print from signal handler, just commit and return
        // The main program will show the increased committed size

        // Signal handler returns, execution resumes
        return;
    }

    // Real segfault - crash
    std.debug.print("FATAL: Segmentation fault at 0x{x:0>16} (outside stack region)\n", .{fault_addr});
    std.process.exit(1);
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
        \\ leaq 40(%%rsp), %%rdi
        \\ jmpq *40(%%rsp)
    );
}

// Recursive function to trigger stack growth
fn recursiveTask(data: *CoroutineData) callconv(.c) noreturn {
    const depth = data.depth;

    // Allocate larger chunk on stack to trigger growth faster
    var buffer: [16384]u8 = undefined;
    @memset(&buffer, @intCast(depth & 0xFF));

    // Get current stack pointer
    var rsp: u64 = undefined;
    asm volatile ("movq %%rsp, %[rsp]"
        : [rsp] "=r" (rsp),
    );

    const stack_used = data.stack_base - rsp;
    const committed = data.stack_base - g_current_limit; // Use global updated by handler

    std.debug.print("Depth {d:3}: RSP=0x{x:0>16} Used={d:6} bytes Committed={d:6} bytes\n", .{
        depth,
        rsp,
        stack_used,
        committed,
    });

    // Recurse deeper to trigger growth
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

    std.process.exit(0);
}

pub fn main() !void {
    std.debug.print("Linux Lazy Stack Growth PoC\n", .{});
    std.debug.print("============================\n\n", .{});

    // Reserve 8MB of address space with PROT_NONE (inaccessible)
    const stack_mem = try posix.mmap(
        null,
        STACK_RESERVE_SIZE,
        posix.PROT.NONE, // Reserved but not accessible
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(stack_mem);

    const stack_base = @intFromPtr(stack_mem.ptr);
    const stack_top = stack_base + STACK_RESERVE_SIZE;

    std.debug.print("Reserved {d} MB at 0x{x:0>16} with PROT_NONE\n", .{
        STACK_RESERVE_SIZE / (1024 * 1024),
        stack_base,
    });

    // Commit initial portion at top of stack
    const initial_commit_start = stack_top - INITIAL_COMMIT_SIZE;
    const initial_region: [*]align(PAGE_SIZE) u8 = @ptrFromInt(initial_commit_start);
    try posix.mprotect(initial_region[0..INITIAL_COMMIT_SIZE], posix.PROT.READ | posix.PROT.WRITE);

    std.debug.print("Committed initial {d} KB at top (0x{x:0>16}-0x{x:0>16})\n", .{
        INITIAL_COMMIT_SIZE / 1024,
        initial_commit_start,
        stack_top,
    });
    std.debug.print("Uncommitted region: 0x{x:0>16}-0x{x:0>16} ({d} MB remains PROT_NONE)\n\n", .{
        stack_base,
        initial_commit_start,
        (STACK_RESERVE_SIZE - INITIAL_COMMIT_SIZE) / (1024 * 1024),
    });

    // Set up global state for signal handler
    g_stack_base = stack_top;
    g_stack_bottom = stack_base;
    g_current_limit = initial_commit_start;

    // Allocate alternate signal stack (signal handler needs its own stack!)
    const sigstack_size = 1024 * 1024; // 1 MB for signal handler
    const sigstack = try posix.mmap(
        null,
        sigstack_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    var ss: linux.stack_t = .{
        .sp = sigstack.ptr,
        .flags = 0,
        .size = sigstack_size,
    };
    _ = linux.sigaltstack(&ss, null);

    // Install SIGSEGV handler with SA_ONSTACK flag
    const empty_set = std.mem.zeroes(posix.sigset_t);
    var sa = posix.Sigaction{
        .handler = .{ .sigaction = &sigsegvHandler },
        .mask = empty_set,
        .flags = linux.SA.SIGINFO | linux.SA.ONSTACK, // Use alternate stack!
    };
    posix.sigaction(posix.SIG.SEGV, &sa, null);

    std.debug.print("SIGSEGV handler installed\n", .{});
    std.debug.print("Starting recursive test (will trigger lazy commits)...\n\n", .{});

    // Set up coroutine data at top of stack
    const data_addr = stack_top - @sizeOf(CoroutineData) - 64;
    const data_ptr: *CoroutineData = @ptrFromInt(data_addr);
    data_ptr.* = .{
        .func = recursiveTask,
        .depth = 1,
        .stack_base = stack_top,
        .stack_reserve_bottom = stack_base,
        .current_limit = initial_commit_start,
    };

    // Initialize coroutine context
    var coro_context = Context{
        .rsp = @intFromPtr(data_ptr),
        .rbp = 0,
        .rip = @intFromPtr(&coroEntry),
    };

    // Save main thread context
    var main_context: Context = undefined;

    // Switch to coroutine
    switchContext(&main_context, &coro_context);

    unreachable;
}
