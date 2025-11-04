// zig fmt: off
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

pub const stack_alignment = 16;
pub const Stack = []align(stack_alignment) u8;
pub const StackPtr = [*]align(stack_alignment) u8;

const WindowsTIB = extern struct {
    fiber_data: u64, // TEB offset 0x20
    deallocation_stack: u64, // TEB offset 0x1478
    stack_base: u64, // TEB offset 0x08
    stack_limit: u64, // TEB offset 0x10
};

const ExtraContext = if (builtin.os.tag == .windows) WindowsTIB else void;

pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        rsp: u64,
        rbp: u64,
        rip: u64,
        extra: ExtraContext,
    },
    .aarch64 => extern struct {
        sp: u64,
        fp: u64,
        pc: u64,
        extra: ExtraContext,
    },
    .riscv64 => extern struct {
        sp: u64,
        fp: u64,
        ra: u64,
        extra: ExtraContext,
    },
    .riscv32 => extern struct {
        sp: u32,
        fp: u32,
        ra: u32,
        extra: ExtraContext,
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

pub const EntryPointFn = fn () callconv(.naked) noreturn;

pub fn initContext(stack_ptr: StackPtr, entry_point: *const EntryPointFn) Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
            .rsp = @intFromPtr(stack_ptr),
            .rbp = 0,
            .rip = @intFromPtr(entry_point),
            .extra = undefined,
        },
        .aarch64 => .{
            .sp = @intFromPtr(stack_ptr),
            .fp = 0,
            .pc = @intFromPtr(entry_point),
            .extra = undefined,
        },
        .riscv64 => .{
            .sp = @intFromPtr(stack_ptr),
            .fp = 0,
            .ra = @intFromPtr(entry_point),
            .extra = undefined,
        },
        .riscv32 => .{
            .sp = @intCast(@intFromPtr(stack_ptr)),
            .fp = 0,
            .ra = @intCast(@intFromPtr(entry_point)),
            .extra = undefined,
        },
        else => @compileError("unsupported architecture"),
    };
}

/// Context switching function using C calling convention.
pub fn switchContext(
    noalias current_context: *Context,
    noalias new_context: *Context,
) void {
    const is_windows = builtin.os.tag == .windows;
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\
            ++ (if (is_windows)
                \\ // Load TEB pointer and save TIB fields
                \\ movq %%gs:0x30, %%r10
                \\ movq 0x20(%%r10), %%r11
                \\ movq %%r11, 24(%%rax)
                \\ movq 0x1478(%%r10), %%r11
                \\ movq %%r11, 32(%%rax)
                \\ movq 0x08(%%r10), %%r11
                \\ movq %%r11, 40(%%rax)
                \\ movq 0x10(%%r10), %%r11
                \\ movq %%r11, 48(%%rax)
                \\
            else
                "")
            ++
            \\ // Restore stack pointer and base pointer
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\
            ++ (if (is_windows)
                \\ // Load TEB pointer and restore TIB fields
                \\ movq %%gs:0x30, %%r10
                \\ movq 24(%%rcx), %%r11
                \\ movq %%r11, 0x20(%%r10)
                \\ movq 32(%%rcx), %%r11
                \\ movq %%r11, 0x1478(%%r10)
                \\ movq 40(%%rcx), %%r11
                \\ movq %%r11, 0x08(%%r10)
                \\ movq 48(%%rcx), %%r11
                \\ movq %%r11, 0x10(%%r10)
                \\
            else
                "")
            ++
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
              .rsi = true,
              .rdi = true,
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
            \\ mov x10, fp
            \\ stp x9, x10, [x0, #0]
            \\
            ++ (if (is_windows)
                \\ // Save TIB fields (x18 points to TEB on ARM64 Windows)
                \\ ldr x10, [x18, #0x20]
                \\ ldr x11, [x18, #0x1478]
                \\ stp x10, x11, [x0, #24]
                \\ ldp x10, x11, [x18, #0x08]
                \\ stp x10, x11, [x0, #40]
                \\
            else
                "")
            ++
            \\ ldp x9, x10, [x1, #0]
            \\ mov sp, x9
            \\ mov fp, x10
            \\
            ++ (if (is_windows)
                \\ // Restore TIB fields
                \\ ldp x10, x11, [x1, #24]
                \\ str x10, [x18, #0x20]
                \\ str x11, [x18, #0x1478]
                \\ ldp x10, x11, [x1, #40]
                \\ stp x10, x11, [x18, #0x08]
                \\
            else
                "")
            ++
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
              // X18 is platform-reserved on Darwin and Windows, but free on Linux
              .x18 = !builtin.os.tag.isDarwin() and builtin.os.tag != .windows,
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
        .riscv64 => asm volatile (
            \\ lla t0, 0f
            \\ sd t0, 16(a0)
            \\ sd sp, 0(a0)
            \\ sd s0, 8(a0)
            \\
            \\ ld sp, 0(a1)
            \\ ld s0, 8(a1)
            \\ ld t0, 16(a1)
            \\ jr t0
            \\0:
            :
            : [current] "{a0}" (current_context),
              [new] "{a1}" (new_context),
            : .{
              .x1 = true,   // ra
              .x2 = true,   // sp
              .x3 = true,   // gp
              .x4 = true,   // tp
              .x5 = true,   // t0
              .x6 = true,   // t1
              .x7 = true,   // t2
              .x8 = true,   // s0/fp
              .x9 = true,   // s1
              .x10 = true,  // a0
              .x11 = true,  // a1
              .x12 = true,  // a2
              .x13 = true,  // a3
              .x14 = true,  // a4
              .x15 = true,  // a5
              .x16 = true,  // a6
              .x17 = true,  // a7
              .x18 = true,  // s2
              .x19 = true,  // s3
              .x20 = true,  // s4
              .x21 = true,  // s5
              .x22 = true,  // s6
              .x23 = true,  // s7
              .x24 = true,  // s8
              .x25 = true,  // s9
              .x26 = true,  // s10
              .x27 = true,  // s11
              .x28 = true,  // t3
              .x29 = true,  // t4
              .x30 = true,  // t5
              .x31 = true,  // t6
              .f0 = true,   // ft0
              .f1 = true,   // ft1
              .f2 = true,   // ft2
              .f3 = true,   // ft3
              .f4 = true,   // ft4
              .f5 = true,   // ft5
              .f6 = true,   // ft6
              .f7 = true,   // ft7
              .f8 = true,   // fs0
              .f9 = true,   // fs1
              .f10 = true,  // fa0
              .f11 = true,  // fa1
              .f12 = true,  // fa2
              .f13 = true,  // fa3
              .f14 = true,  // fa4
              .f15 = true,  // fa5
              .f16 = true,  // fa6
              .f17 = true,  // fa7
              .f18 = true,  // fs2
              .f19 = true,  // fs3
              .f20 = true,  // fs4
              .f21 = true,  // fs5
              .f22 = true,  // fs6
              .f23 = true,  // fs7
              .f24 = true,  // fs8
              .f25 = true,  // fs9
              .f26 = true,  // fs10
              .f27 = true,  // fs11
              .f28 = true,  // ft8
              .f29 = true,  // ft9
              .f30 = true,  // ft10
              .f31 = true,  // ft11
              .memory = true,
            }),
        .riscv32 => asm volatile (
            \\ lla t0, 0f
            \\ sw t0, 8(a0)
            \\ sw sp, 0(a0)
            \\ sw s0, 4(a0)
            \\
            \\ lw sp, 0(a1)
            \\ lw s0, 4(a1)
            \\ lw t0, 8(a1)
            \\ jr t0
            \\0:
            :
            : [current] "{a0}" (current_context),
              [new] "{a1}" (new_context),
            : .{
              .x1 = true,   // ra
              .x2 = true,   // sp
              .x3 = true,   // gp
              .x4 = true,   // tp
              .x5 = true,   // t0
              .x6 = true,   // t1
              .x7 = true,   // t2
              .x8 = true,   // s0/fp
              .x9 = true,   // s1
              .x10 = true,  // a0
              .x11 = true,  // a1
              .x12 = true,  // a2
              .x13 = true,  // a3
              .x14 = true,  // a4
              .x15 = true,  // a5
              .x16 = true,  // a6
              .x17 = true,  // a7
              .x18 = true,  // s2
              .x19 = true,  // s3
              .x20 = true,  // s4
              .x21 = true,  // s5
              .x22 = true,  // s6
              .x23 = true,  // s7
              .x24 = true,  // s8
              .x25 = true,  // s9
              .x26 = true,  // s10
              .x27 = true,  // s11
              .x28 = true,  // t3
              .x29 = true,  // t4
              .x30 = true,  // t5
              .x31 = true,  // t6
              .f0 = true,   // ft0
              .f1 = true,   // ft1
              .f2 = true,   // ft2
              .f3 = true,   // ft3
              .f4 = true,   // ft4
              .f5 = true,   // ft5
              .f6 = true,   // ft6
              .f7 = true,   // ft7
              .f8 = true,   // fs0
              .f9 = true,   // fs1
              .f10 = true,  // fa0
              .f11 = true,  // fa1
              .f12 = true,  // fa2
              .f13 = true,  // fa3
              .f14 = true,  // fa4
              .f15 = true,  // fa5
              .f16 = true,  // fa6
              .f17 = true,  // fa7
              .f18 = true,  // fs2
              .f19 = true,  // fs3
              .f20 = true,  // fs4
              .f21 = true,  // fs5
              .f22 = true,  // fs6
              .f23 = true,  // fs7
              .f24 = true,  // fs8
              .f25 = true,  // fs9
              .f26 = true,  // fs10
              .f27 = true,  // fs11
              .f28 = true,  // ft8
              .f29 = true,  // ft9
              .f30 = true,  // ft10
              .f31 = true,  // ft11
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
        .riscv64 => asm volatile (
            \\ li ra, 0
            \\ mv a0, sp
            \\ ld t0, 0(sp)
            \\ jr t0
        ),
        .riscv32 => asm volatile (
            \\ li ra, 0
            \\ mv a0, sp
            \\ lw t0, 0(sp)
            \\ jr t0
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
        if (builtin.os.tag == .windows) {
            self.context.extra.fiber_data = 0; // No fiber data for our coroutines
            self.context.extra.stack_base = stack_end; // Top of stack (high address)
            self.context.extra.stack_limit = stack_base; // Bottom of stack (low address)
            self.context.extra.deallocation_stack = stack_base; // Allocation base
        }
    }
};
