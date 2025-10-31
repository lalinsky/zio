// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const meta = @import("meta.zig");
const FutureResult = @import("future_result.zig").FutureResult;

pub const DEFAULT_STACK_SIZE = if (builtin.os.tag == .windows) 2 * 1024 * 1024 else 256 * 1024; // 2MB on Windows, 256KB elsewhere - TODO: investigate why Windows needs much more stack

pub const CoroutineState = enum(u8) {
    ready = 0b0000,
    preparing_to_wait = 0b0001,
    waiting_io = 0b0100,
    waiting_sync = 0b0101,
    waiting_completion = 0b0110,
    dead = 0b1000_0000,

    pub fn isWaiting(self: CoroutineState) bool {
        return (@intFromEnum(self) & 0b0100) != 0;
    }
};

pub const stack_alignment = 16;
pub const Stack = []align(stack_alignment) u8;
pub const StackPtr = [*]align(stack_alignment) u8;

pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => if (builtin.os.tag == .windows) extern struct {
        rsp: u64,
        rbp: u64,
        rip: u64,
        // Windows TIB (Thread Information Block) fields
        fiber_data: u64, // gs:[0x20]
        stack_base: u64, // gs:[0x08]
        stack_limit: u64, // gs:[0x10]
        deallocation_stack: u64, // gs:[0x1478]
    } else extern struct {
        rsp: u64,
        rbp: u64,
        rip: u64,
    },
    .aarch64 => extern struct {
        sp: u64,
        fp: u64,
        pc: u64,
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

pub const EntryPointFn = fn () callconv(.naked) noreturn;

pub fn initContext(stack_ptr: StackPtr, entry_point: *const EntryPointFn) Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => if (builtin.os.tag == .windows) .{
            .rsp = @intFromPtr(stack_ptr),
            .rbp = 0,
            .rip = @intFromPtr(entry_point),
            .fiber_data = 0,
            .stack_base = 0,
            .stack_limit = 0,
            .deallocation_stack = 0,
        } else .{
            .rsp = @intFromPtr(stack_ptr),
            .rbp = 0,
            .rip = @intFromPtr(entry_point),
        },
        .aarch64 => .{
            .sp = @intFromPtr(stack_ptr),
            .fp = 0,
            .pc = @intFromPtr(entry_point),
        },
        else => @compileError("unsupported architecture"),
    };
}

/// Context switching function using C calling convention.
pub fn switchContext(
    noalias current_context: *Context,
    noalias new_context: *Context,
) void {
    switch (builtin.cpu.arch) {
        .x86_64 => if (builtin.os.tag == .windows) asm volatile (
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\
            \\ // Save current TIB fields
            \\ movq %%gs:0x20, %%r11
            \\ movq %%r11, 24(%%rax)
            \\ movq %%gs:0x08, %%r11
            \\ movq %%r11, 32(%%rax)
            \\ movq %%gs:0x10, %%r11
            \\ movq %%r11, 40(%%rax)
            \\ movq %%gs:0x1478, %%r11
            \\ movq %%r11, 48(%%rax)
            \\
            \\ // Restore stack pointer and base pointer
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\
            \\ // Restore new TIB fields
            \\ movq 24(%%rcx), %%r11
            \\ movq %%r11, %%gs:0x20
            \\ movq 32(%%rcx), %%r11
            \\ movq %%r11, %%gs:0x08
            \\ movq 40(%%rcx), %%r11
            \\ movq %%r11, %%gs:0x10
            \\ movq 48(%%rcx), %%r11
            \\ movq %%r11, %%gs:0x1478
            \\
            \\ jmpq *16(%%rcx)
            \\0:
            :
            : [current] "{rax}" (current_context),
              [new] "{rcx}" (new_context),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .r11 = true,
              .rbx = true,
              .rdi = true,
              .rsi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
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
            }) else asm volatile (
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
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
            }),
        .aarch64 => asm volatile (
            \\ adr x9, 0f
            \\ str x9, [x0, #16]
            \\ mov x9, sp
            \\ str x9, [x0, #0]
            \\ mov x9, fp
            \\ str x9, [x0, #8]
            \\ ldr x9, [x1, #0]
            \\ mov sp, x9
            \\ ldr x9, [x1, #8]
            \\ mov fp, x9
            \\ ldr x9, [x1, #16]
            \\ br x9
            \\0:
            :
            : [current] "{x0}" (current_context),
              [new] "{x1}" (new_context),
            : .{
              .x0 = true,
              .x1 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x18 = true,
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .memory = true,
            }),
        else => @compileError("unsupported architecture"),
    }
}

/// Entry point for coroutines that reads function pointer from stack and passes data pointer.
///
/// Expected stack layout for all platforms.
///   rsp/sp + 0 = CoroutineData.func     (function pointer)
///   rsp/sp + 8 = CoroutineData.args     (args data)
///   rsp/sp + ... = CoroutineData.result (result storage)
///
/// The function is called with a pointer to the entire CoroutineData structure.
///
/// x86_64 handles stack alignment here since we use JMP instead of CALL:
/// - x86_64 System V ABI requires 16-byte alignment before CALL instruction
/// - CALL would push 8-byte return address, so we push 0 to simulate this
/// - If the function unexpectedly returns, it will crash on null address (defensive)
///
/// ARM64 stores return address in x30 register (not stack), so we set x30=0 for safety
fn coroEntry() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (builtin.os.tag == .windows) {
                // Windows x64 ABI: first integer arg in RCX
                // Allocate shadow space before return address to match call convention
                asm volatile (
                    \\ subq $32, %%rsp
                    \\ pushq $0
                    \\ leaq 40(%%rsp), %%rcx
                    \\ jmpq *40(%%rsp)
                );
            } else {
                // System V AMD64 ABI: first integer arg in RDI
                asm volatile (
                    \\ pushq $0
                    \\ leaq 8(%%rsp), %%rdi
                    \\ jmpq *8(%%rsp)
                );
            }
        },
        .aarch64 => asm volatile (
            \\ mov x30, #0
            \\ mov x0, sp
            \\ ldr x2, [sp]
            \\ br x2
        ),
        else => @compileError("unsupported architecture"),
    }
}

pub const Coroutine = struct {
    context: Context = undefined,
    parent_context_ptr: *Context,
    stack: ?Stack,
    finished: bool = false,

    pub fn setup(self: *Coroutine, func: anytype, args: meta.ArgsType(func), result_ptr: *FutureResult(meta.ReturnType(func))) void {
        const Result = meta.ReturnType(func);
        const Args = @TypeOf(args);

        const CoroutineData = struct {
            func: *const fn (*anyopaque) callconv(.c) noreturn,
            args: Args,
            result_ptr: *FutureResult(Result),
            coro: *Coroutine,

            fn wrapper(coro_data_ptr: *anyopaque) callconv(.c) noreturn {
                const coro_data: *@This() = @ptrCast(@alignCast(coro_data_ptr));
                const coro = coro_data.coro;

                const result = @call(.always_inline, func, coro_data.args);
                _ = coro_data.result_ptr.set(result);

                coro.finished = true;
                switchContext(&coro.context, coro.parent_context_ptr);
                unreachable;
            }
        };

        // Convert the stack pointer to ints for calculations
        const stack = self.stack.?; // Stack must be non-null during setup
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = stack_base + stack.len;

        // Store function pointer, args, and result space as a contiguous block at the end of stack
        const data_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(CoroutineData), stack_alignment);

        // Set up function pointer, args, result_ptr, and coro pointer
        const data: *CoroutineData = @ptrFromInt(data_ptr);
        data.func = &CoroutineData.wrapper;
        data.args = args;
        data.result_ptr = result_ptr;
        data.coro = self;

        // Initialize the context with the entry point
        self.context = initContext(@ptrCast(@alignCast(data)), &coroEntry);

        // Initialize Windows TIB fields for the coroutine stack
        if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
            self.context.fiber_data = 0; // No fiber data for our coroutines
            self.context.stack_base = stack_end; // Top of stack (high address)
            self.context.stack_limit = stack_base; // Bottom of stack (low address)
            self.context.deallocation_stack = stack_base; // Allocation base
        }
    }
};
