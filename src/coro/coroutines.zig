// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

// zig fmt: off

const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;
const StackInfo = @import("stack.zig").StackInfo;
const stackAlloc = @import("stack.zig").stackAlloc;
const stackFree = @import("stack.zig").stackFree;
const tsan = @import("tsan.zig");

/// Current coroutine context for this thread. Used by the SIGSEGV signal handler
/// to determine if a fault is from a coroutine stack and to access stack metadata.
pub threadlocal var current_context_DO_NOT_ACCESS_DIRECTLY: ?*Context = null;

/// Get the current coroutine context for this thread, or null if not in coroutine context.
pub noinline fn getCurrentContext() ?*Context {
    return current_context_DO_NOT_ACCESS_DIRECTLY;
}

noinline fn setCurrentContext(current: ?*Context) void {
    current_context_DO_NOT_ACCESS_DIRECTLY = current;
}

pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        rsp: u64,
        rbp: u64,
        rip: u64,
        fiber_data: if (builtin.os.tag == .windows) u64 else void = if (builtin.os.tag == .windows) 0 else {}, // Windows only (TEB offset 0x20)
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    .aarch64 => extern struct {
        sp: u64,  // x31 (stack pointer)
        fp: u64,  // x29 (frame pointer)
        lr: u64,  // x30 (link register) only saved a an optimization reusing ldp/stp
        pc: u64,
        fiber_data: if (builtin.os.tag == .windows) u64 else void = if (builtin.os.tag == .windows) 0 else {}, // Windows only (TEB offset 0x20)
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    .arm, .thumb => extern struct {
        sp: u32,  // r13 (stack pointer)
        fp: u32,  // r11 (frame pointer, r7 in Thumb)
        lr: u32,  // r14 (link register) only saved beause of https://github.com/llvm/llvm-project/pull/179740 (can't be worked around in zig)
        pc: u32,  // r15 (program counter)
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 8;  // AAPCS requires 8-byte alignment
    },
    .riscv64 => extern struct {
        sp: u64,
        fp: u64,
        pc: u64,
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    .riscv32 => extern struct {
        sp: u32,
        fp: u32,
        pc: u32,
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    .loongarch64 => extern struct {
        sp: u64,
        fp: u64,
        pc: u64,
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    .powerpc64, .powerpc64le => extern struct {
        sp: u64,   // r1 (stack pointer)
        fp: u64,   // r31 (conventional frame pointer)
        pc: u64,
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    // NOTE: untested — Zig's toolchain cannot cross-compile+link sparc64 (no bundled
    // musl, incomplete lld SPARC64 TLS support). Requires native build to verify.
    .sparc64 => extern struct {
        sp: u64,  // %o6 (stack pointer)
        fp: u64,  // %i6 (frame pointer; used by coroEntry to locate the Entrypoint)
        pc: u64,
        stack_info: StackInfo,
        tsan_fiber: tsan.Fiber = tsan.none,

        pub const stack_alignment = 16;
    },
    else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
};

pub const EntryPointFn = fn () callconv(.naked) noreturn;

pub fn setupContext(ctx: *Context, stack_ptr: usize, entry_point: *const EntryPointFn) void {
    assert(stack_ptr % Context.stack_alignment == 0);
    switch (builtin.cpu.arch) {
        .x86_64 => {
            ctx.rsp = stack_ptr;
            ctx.rbp = 0;
            ctx.rip = @intFromPtr(entry_point);
        },
        .aarch64 => {
            ctx.sp = stack_ptr;
            ctx.fp = 0;
            ctx.lr = @returnAddress();
            ctx.pc = @intFromPtr(entry_point);
        },
        .arm, .thumb => {
            ctx.sp = @intCast(stack_ptr);
            ctx.fp = 0;
            ctx.lr = @returnAddress();
            ctx.pc = @intCast(@intFromPtr(entry_point));
        },
        .riscv64 => {
            ctx.sp = stack_ptr;
            ctx.fp = 0;
            ctx.pc = @intFromPtr(entry_point);
        },
        .riscv32 => {
            ctx.sp = @intCast(stack_ptr);
            ctx.fp = 0;
            ctx.pc = @intCast(@intFromPtr(entry_point));
        },
        .loongarch64 => {
            ctx.sp = stack_ptr;
            ctx.fp = 0;
            ctx.pc = @intFromPtr(entry_point);
        },
        .powerpc64, .powerpc64le => {
            ctx.sp = stack_ptr;
            ctx.fp = 0;
            ctx.pc = @intFromPtr(entry_point);
        },
        .sparc64 => {
            // SPARC V9 uses a register save area at %sp+2047 (128 bytes).
            // Lower %sp by 2176 bytes (next 16-byte multiple above 2047+128=2175) so
            // the coroEntry window's potential save area stays below the Entrypoint.
            // coroEntry reads the Entrypoint struct via %i6, which we set to stack_ptr.
            if (stack_ptr < ctx.stack_info.limit + 2176) @panic("Stack overflow during coroutine setup: insufficient space for SPARC64 register save area headroom");
            ctx.sp = stack_ptr - 2176;
            ctx.fp = stack_ptr;
            ctx.pc = @intFromPtr(entry_point);
        },
        else => @compileError("unsupported architecture"),
    }
}

/// Context switching function using C calling convention.
pub inline fn switchContext(
    noalias current_context_param: *Context,
    noalias new_context: *Context,
) void {
    // Update current context pointer for SIGSEGV handler
    // After the switch, we'll be executing in new_context
    setCurrentContext(new_context);

    // Hand the running fiber over to TSan before the stacks are swapped.
    // We are still executing as `current_context`, so TSan's current fiber
    // corresponds to it: record that handle (this also lazily captures the
    // scheduler's native-thread context, whose fiber we never created), then
    // switch TSan onto the target's fiber. `new_context.tsan_fiber` is always
    // valid here: coroutine contexts get one in `setup`, and a scheduler
    // context is only ever switched back into after it was first switched out
    // of (which captured it just below). Compiles away when TSan is disabled.
    if (tsan.enabled) {
        current_context_param.tsan_fiber = tsan.currentFiber();
        tsan.switchToFiber(new_context.tsan_fiber);
    }

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
            : [current] "{rax}" (current_context_param),
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
              // xmm/ymm cover baseline (SSE2) and AVX; on a target without
              // AVX-512 the zmm* names don't exist and LLVM drops those clobbers,
              // which previously left xmm0-15 unclobbered and corrupted values held
              // across the switch on Windows (callee-saved xmm6-15). See #460.
              .xmm0 = true,
              .xmm1 = true,
              .xmm2 = true,
              .xmm3 = true,
              .xmm4 = true,
              .xmm5 = true,
              .xmm6 = true,
              .xmm7 = true,
              .xmm8 = true,
              .xmm9 = true,
              .xmm10 = true,
              .xmm11 = true,
              .xmm12 = true,
              .xmm13 = true,
              .xmm14 = true,
              .xmm15 = true,
              .ymm0 = true,
              .ymm1 = true,
              .ymm2 = true,
              .ymm3 = true,
              .ymm4 = true,
              .ymm5 = true,
              .ymm6 = true,
              .ymm7 = true,
              .ymm8 = true,
              .ymm9 = true,
              .ymm10 = true,
              .ymm11 = true,
              .ymm12 = true,
              .ymm13 = true,
              .ymm14 = true,
              .ymm15 = true,
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
              .cc = true,
              .dirflag = true,
              .st0 = true,
              .st1 = true,
              .st2 = true,
              .st3 = true,
              .st4 = true,
              .st5 = true,
              .st6 = true,
              .st7 = true,
              .memory = true,
            }),

        // NOTE: We technically don't need to save x30/lr, we could mark it as clobbered,
        //       but the compiler will almost always need to save it anyway, and we can
        //       fit it into our stp/ldp instructions, so we will help it out a bit.
        .aarch64 => asm volatile (
            \\ adr x9, 0f
            \\ mov x10, sp
            \\ stp x10, fp, [x0, #0]
            \\ stp lr, x9, [x0, #16]
            \\
            ++ (if (is_windows)
                \\ // Save TIB fields (x18 points to TEB on ARM64 Windows)
                \\ ldr x10, [x18, #0x20]
                \\ ldr x11, [x18, #0x1478]
                \\ stp x10, x11, [x0, #32]
                \\ ldp x10, x11, [x18, #0x08]
                \\ stp x10, x11, [x0, #48]
                \\
            else
                "")
            ++
            \\ ldp x9, fp, [x1, #0]
            \\ mov sp, x9
            \\ ldp lr, x9, [x1, #16]
            \\
            ++ (if (is_windows)
                \\ // Restore TIB fields
                \\ ldp x10, x11, [x1, #32]
                \\ str x10, [x18, #0x20]
                \\ str x11, [x18, #0x1478]
                \\ ldp x10, x11, [x1, #48]
                \\ stp x10, x11, [x18, #0x08]
                \\
            else
                "")
            ++
            \\ br x9
            \\0:
            :
            : [current] "{x0}" (current_context_param),
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
              // NEON v0-v31. The z*/p* (SVE) clobbers below currently cover these
              // (LLVM aliases them even without SVE), but clobber the NEON regs
              // explicitly so preservation of the callee-saved v8-v15 across the
              // switch never depends on that aliasing quirk (cf. x86_64 #460).
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
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
              .nzcv = true,
              .memory = true,
            }),
        .arm => asm volatile (
            \\ adr r2, 0f
            \\ str sp, [r0, #0]
            \\ str r11, [r0, #4]
            \\ str lr, [r0, #8]
            \\ str r2, [r0, #12]
            \\
            \\ ldr sp, [r1, #0]
            \\ ldr r11, [r1, #4]
            \\ ldr lr, [r1, #8]
            \\ ldr r2, [r1, #12]
            \\ bx r2
            \\0:
            :
            : [current] "{r0}" (current_context_param),
              [new] "{r1}" (new_context),
            : .{
              .r0 = true,
              .r1 = true,
              .r2 = true,
              .r3 = true,
              .r4 = true,
              .r5 = true,
              .r6 = true,
              .r7 = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = false, // frame pointer (saved)
              .r12 = true,
              .r13 = false, // stack pointer (saved)
              .r14 = false, // link register (saved)
              .d0 = true,
              .d1 = true,
              .d2 = true,
              .d3 = true,
              .d4 = true,
              .d5 = true,
              .d6 = true,
              .d7 = true,
              .d8 = true,
              .d9 = true,
              .d10 = true,
              .d11 = true,
              .d12 = true,
              .d13 = true,
              .d14 = true,
              .d15 = true,
              .d16 = true,
              .d17 = true,
              .d18 = true,
              .d19 = true,
              .d20 = true,
              .d21 = true,
              .d22 = true,
              .d23 = true,
              .d24 = true,
              .d25 = true,
              .d26 = true,
              .d27 = true,
              .d28 = true,
              .d29 = true,
              .d30 = true,
              .d31 = true,
              .fpscr = true,
              .cpsr = true,
              .memory = true,
            }),
        .thumb => asm volatile (
            // Load resume address, then explicitly set Thumb bit (LSB=1).
            // adr alone cannot target unaligned addresses on Thumb-1 (Cortex-M0),
            // so we must compute the word-aligned address first, then OR in bit 0.
            \\ adr r2, 0f
            \\ adds r2, #1
            \\ mov r3, sp
            \\ str r3, [r0, #0]
            \\ str r7, [r0, #4]
            \\ mov r3, lr
            \\ str r3, [r0, #8]
            \\ str r2, [r0, #12]
            \\
            \\ ldr r3, [r1, #0]
            \\ mov sp, r3
            \\ ldr r7, [r1, #4]
            \\ ldr r3, [r1, #8]
            \\ mov lr, r3
            \\ ldr r2, [r1, #12]
            \\ bx r2
            \\.balign 4
            \\0:
            :
            : [current] "{r0}" (current_context_param),
              [new] "{r1}" (new_context),
            : .{
              .r0 = true,
              .r1 = true,
              .r2 = true,
              .r3 = true,
              .r4 = true,
              .r5 = true,
              .r6 = true,
              .r7 = false, // frame pointer (saved)
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = false,  // stack pointer (saved)
              .r14 = false,  // link register (saved)
              .d0 = true,
              .d1 = true,
              .d2 = true,
              .d3 = true,
              .d4 = true,
              .d5 = true,
              .d6 = true,
              .d7 = true,
              .d8 = true,
              .d9 = true,
              .d10 = true,
              .d11 = true,
              .d12 = true,
              .d13 = true,
              .d14 = true,
              .d15 = true,
              .d16 = true,
              .d17 = true,
              .d18 = true,
              .d19 = true,
              .d20 = true,
              .d21 = true,
              .d22 = true,
              .d23 = true,
              .d24 = true,
              .d25 = true,
              .d26 = true,
              .d27 = true,
              .d28 = true,
              .d29 = true,
              .d30 = true,
              .d31 = true,
              .fpscr = true,
              .cpsr = true,
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
            : [current] "{a0}" (current_context_param),
              [new] "{a1}" (new_context),
            : .{
              .x1 = true,   // ra
              .x2 = false,  // sp (saved)
              .x3 = true,   // gp
              .x4 = true,   // tp
              .x5 = true,   // t0
              .x6 = true,   // t1
              .x7 = true,   // t2
              .x8 = false,  // s0/fp (saved)
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
              .fflags = true,
              .frm = true,
              // RVV v0-31: absent on the baseline build (clobber dropped, like
              // x86_64 zmm) but honored on a V-enabled build, so a vector value
              // held across the switch is preserved (cf. #460).
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
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
            : [current] "{a0}" (current_context_param),
              [new] "{a1}" (new_context),
            : .{
              .x1 = true,   // ra
              .x2 = false,  // sp (saved)
              .x3 = true,   // gp
              .x4 = true,   // tp
              .x5 = true,   // t0
              .x6 = true,   // t1
              .x7 = true,   // t2
              .x8 = false,  // s0/fp (saved)
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
              .fflags = true,
              .frm = true,
              // RVV v0-31: absent on the baseline build (clobber dropped, like
              // x86_64 zmm) but honored on a V-enabled build, so a vector value
              // held across the switch is preserved (cf. #460).
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
              .memory = true,
            }),
        .powerpc64, .powerpc64le => asm volatile (
            \\ // Get resume address into r5
            \\ bcl 20, 31, 1f
            \\1:
            \\ mflr 5
            \\ addi 5, 5, 0f - 1b
            \\ // Save current context
            \\ std 1, 0(3)
            \\ std 31, 8(3)
            \\ std 5, 16(3)
            \\
            \\ // Restore new context
            \\ ld 1, 0(4)
            \\ ld 31, 8(4)
            \\ ld 5, 16(4)
            \\ mtctr 5
            \\ bctr
            \\0:
            :
            : [current] "{r3}" (current_context_param),
              [new] "{r4}" (new_context),
            : .{
              .cr0 = true,
              .cr1 = true,
              .cr2 = true,
              .cr3 = true,
              .cr4 = true,
              .cr5 = true,
              .cr6 = true,
              .cr7 = true,
              .xer = true,
              .ctr = true,
              .lr = true,
              .r0 = true,
              .r1 = false,  // sp (saved)
              .r2 = false,  // TOC (reserved on ELFv2)
              .r3 = true,
              .r4 = true,
              .r5 = true,
              .r6 = true,
              .r7 = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = false, // thread pointer (reserved)
              .r14 = true,
              .r15 = true,
              .r16 = true,
              .r17 = true,
              .r18 = true,
              .r19 = true,
              .r20 = true,
              .r21 = true,
              .r22 = true,
              .r23 = true,
              .r24 = true,
              .r25 = true,
              .r26 = true,
              .r27 = true,
              .r28 = true,
              .r29 = true,
              .r30 = true,
              .r31 = false, // fp (saved)
              .fpscr = true,
              .vscr = true,
              .vs0 = true,
              .vs1 = true,
              .vs2 = true,
              .vs3 = true,
              .vs4 = true,
              .vs5 = true,
              .vs6 = true,
              .vs7 = true,
              .vs8 = true,
              .vs9 = true,
              .vs10 = true,
              .vs11 = true,
              .vs12 = true,
              .vs13 = true,
              .vs14 = true,
              .vs15 = true,
              .vs16 = true,
              .vs17 = true,
              .vs18 = true,
              .vs19 = true,
              .vs20 = true,
              .vs21 = true,
              .vs22 = true,
              .vs23 = true,
              .vs24 = true,
              .vs25 = true,
              .vs26 = true,
              .vs27 = true,
              .vs28 = true,
              .vs29 = true,
              .vs30 = true,
              .vs31 = true,
              .vs32 = true,
              .vs33 = true,
              .vs34 = true,
              .vs35 = true,
              .vs36 = true,
              .vs37 = true,
              .vs38 = true,
              .vs39 = true,
              .vs40 = true,
              .vs41 = true,
              .vs42 = true,
              .vs43 = true,
              .vs44 = true,
              .vs45 = true,
              .vs46 = true,
              .vs47 = true,
              .vs48 = true,
              .vs49 = true,
              .vs50 = true,
              .vs51 = true,
              .vs52 = true,
              .vs53 = true,
              .vs54 = true,
              .vs55 = true,
              .vs56 = true,
              .vs57 = true,
              .vs58 = true,
              .vs59 = true,
              .vs60 = true,
              .vs61 = true,
              .vs62 = true,
              .vs63 = true,
              .f0 = true,
              .f1 = true,
              .f2 = true,
              .f3 = true,
              .f4 = true,
              .f5 = true,
              .f6 = true,
              .f7 = true,
              .f8 = true,
              .f9 = true,
              .f10 = true,
              .f11 = true,
              .f12 = true,
              .f13 = true,
              .f14 = true,
              .f15 = true,
              .f16 = true,
              .f17 = true,
              .f18 = true,
              .f19 = true,
              .f20 = true,
              .f21 = true,
              .f22 = true,
              .f23 = true,
              .f24 = true,
              .f25 = true,
              .f26 = true,
              .f27 = true,
              .f28 = true,
              .f29 = true,
              .f30 = true,
              .f31 = true,
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
              .acc0 = true,
              .acc1 = true,
              .acc2 = true,
              .acc3 = true,
              .acc4 = true,
              .acc5 = true,
              .acc6 = true,
              .acc7 = true,
              .acc = true,
              .spefsc = true,
              .memory = true,
            }),
        .loongarch64 => asm volatile (
            \\ la.local $t0, 0f
            \\ st.d $t0, $a0, 16
            \\ st.d $sp, $a0, 0
            \\ st.d $fp, $a0, 8
            \\
            \\ ld.d $sp, $a1, 0
            \\ ld.d $fp, $a1, 8
            \\ ld.d $t0, $a1, 16
            \\ jr $t0
            \\0:
            :
            : [current] "{$r4}" (current_context_param),
              [new] "{$r5}" (new_context),
            : .{
              .r1 = true,   // ra
              .r3 = true,   // sp
              .r4 = true,   // a0
              .r5 = true,   // a1
              .r6 = true,   // a2
              .r7 = true,   // a3
              .r8 = true,   // a4
              .r9 = true,   // a5
              .r10 = true,  // a6
              .r11 = true,  // a7
              .r12 = true,  // t0
              .r13 = true,  // t1
              .r14 = true,  // t2
              .r15 = true,  // t3
              .r16 = true,  // t4
              .r17 = true,  // t5
              .r18 = true,  // t6
              .r19 = true,  // t7
              .r20 = true,  // t8
              .r22 = true,  // fp/s9
              .r23 = true,  // s0
              .r24 = true,  // s1
              .r25 = true,  // s2
              .r26 = true,  // s3
              .r27 = true,  // s4
              .r28 = true,  // s5
              .r29 = true,  // s6
              .r30 = true,  // s7
              .r31 = true,  // s8
              .f0 = true,   // fa0
              .f1 = true,   // fa1
              .f2 = true,   // fa2
              .f3 = true,   // fa3
              .f4 = true,   // fa4
              .f5 = true,   // fa5
              .f6 = true,   // fa6
              .f7 = true,   // fa7
              .f8 = true,   // ft0
              .f9 = true,   // ft1
              .f10 = true,  // ft2
              .f11 = true,  // ft3
              .f12 = true,  // ft4
              .f13 = true,  // ft5
              .f14 = true,  // ft6
              .f15 = true,  // ft7
              .f16 = true,  // ft8
              .f17 = true,  // ft9
              .f18 = true,  // ft10
              .f19 = true,  // ft11
              .f20 = true,  // ft12
              .f21 = true,  // ft13
              .f22 = true,  // ft14
              .f23 = true,  // ft15
              .f24 = true,  // fs0
              .f25 = true,  // fs1
              .f26 = true,  // fs2
              .f27 = true,  // fs3
              .f28 = true,  // fs4
              .f29 = true,  // fs5
              .f30 = true,  // fs6
              .f31 = true,  // fs7
              .fcc0 = true,
              .fcc1 = true,
              .fcc2 = true,
              .fcc3 = true,
              .fcc4 = true,
              .fcc5 = true,
              .fcc6 = true,
              .fcc7 = true,
              .fcsr0 = true,
              .fcsr1 = true,
              .fcsr2 = true,
              .fcsr3 = true,
              // LSX vr0-31 / LASX xr0-31: absent on the baseline build (clobbers
              // dropped) but honored on LSX/LASX builds (cf. #460).
              .vr0 = true,
              .vr1 = true,
              .vr2 = true,
              .vr3 = true,
              .vr4 = true,
              .vr5 = true,
              .vr6 = true,
              .vr7 = true,
              .vr8 = true,
              .vr9 = true,
              .vr10 = true,
              .vr11 = true,
              .vr12 = true,
              .vr13 = true,
              .vr14 = true,
              .vr15 = true,
              .vr16 = true,
              .vr17 = true,
              .vr18 = true,
              .vr19 = true,
              .vr20 = true,
              .vr21 = true,
              .vr22 = true,
              .vr23 = true,
              .vr24 = true,
              .vr25 = true,
              .vr26 = true,
              .vr27 = true,
              .vr28 = true,
              .vr29 = true,
              .vr30 = true,
              .vr31 = true,
              .xr0 = true,
              .xr1 = true,
              .xr2 = true,
              .xr3 = true,
              .xr4 = true,
              .xr5 = true,
              .xr6 = true,
              .xr7 = true,
              .xr8 = true,
              .xr9 = true,
              .xr10 = true,
              .xr11 = true,
              .xr12 = true,
              .xr13 = true,
              .xr14 = true,
              .xr15 = true,
              .xr16 = true,
              .xr17 = true,
              .xr18 = true,
              .xr19 = true,
              .xr20 = true,
              .xr21 = true,
              .xr22 = true,
              .xr23 = true,
              .xr24 = true,
              .xr25 = true,
              .xr26 = true,
              .xr27 = true,
              .xr28 = true,
              .xr29 = true,
              .xr30 = true,
              .xr31 = true,
              .memory = true,
            }),
        .sparc64 => asm volatile (
            // Flush all register windows to the stack before touching %sp.
            // Without flushw, a window overflow after the switch would write
            // the old context's registers to the new context's stack.
            \\ flushw
            \\
            // Compute resume address (label 0:) via rd %pc (SPARC V9, non-privileged).
            // After rd, %%o2 = address of the rd instruction (= 1b).
            // The add computes: %%o2 += (0f - 1b) → %%o2 = address of 0:.
            \\ 1: rd %%pc, %%o2
            \\ add %%o2, (0f - 1b), %%o2
            \\ stx %%o2, [%%o0 + 16]
            \\
            // Save current context.
            \\ stx %%sp, [%%o0 + 0]
            \\ stx %%i6, [%%o0 + 8]
            \\
            // Restore new context.
            \\ ldx [%%o1 + 0], %%sp
            \\ ldx [%%o1 + 8], %%i6
            \\ ldx [%%o1 + 16], %%o2
            \\ jmp %%o2
            \\ nop
            \\0:
            :
            : [current] "{o0}" (current_context_param),
              [new] "{o1}" (new_context),
            : .{
              // Globals (g0 is always zero; g6/g7 are ABI-reserved by the OS, not clobbered)
              .g1 = true, .g2 = true, .g3 = true, .g4 = true, .g5 = true,
              // Outputs (o6=%sp saved/restored, not listed)
              .o0 = true, .o1 = true, .o2 = true, .o3 = true, .o4 = true, .o5 = true, .o7 = true,
              // Locals
              .l0 = true, .l1 = true, .l2 = true, .l3 = true, .l4 = true, .l5 = true, .l6 = true, .l7 = true,
              // Inputs (i6=%fp saved/restored, not listed)
              .i0 = true, .i1 = true, .i2 = true, .i3 = true, .i4 = true, .i5 = true, .i7 = true,
              // Condition codes and misc state registers
              .y = true, .ccr = true, .icc = true, .xcc = true, .gsr = true,
              // Floating-point (q0-q15 are the 16 quad slots covering all 64 FP regs)
              .q0 = true, .q1 = true, .q2 = true, .q3 = true,
              .q4 = true, .q5 = true, .q6 = true, .q7 = true,
              .q8 = true, .q9 = true, .q10 = true, .q11 = true,
              .q12 = true, .q13 = true, .q14 = true, .q15 = true,
              .fsr = true, .fprs = true,
              .memory = true,
            }),
        else => @compileError("unsupported architecture"),
    }
}

/// Entry point for coroutines that reads function pointer and context from stack.
///
/// Expected stack layout (Entrypoint structure):
///   rsp/sp + 0 = func     (function pointer)
///   rsp/sp + 8 = context  (context pointer)
///
/// The function is called with the context pointer as the first argument.
///
/// Return address handling (for stack trace termination):
/// - Zig 0.15: Uses a sentinel label address. Stack trace dumping subtracts 1 from
///   return addresses, causing integer overflow panic if we use 0.
/// - Zig 0.16: Creates a sentinel frame with FP=0/LR=0 for proper FP-based unwinding
///   (needed for macOS). Sets LR=0 for DWARF unwinding termination.
///
/// Architecture notes:
/// - x86_64: Return address pushed on stack. System V ABI requires 16-byte alignment
///   before CALL; we push the return address to satisfy this.
/// - aarch64/riscv64/loongarch64: Return address stored in link register (x30/ra/$ra).
///   On Zig 0.16+, we create a sentinel frame on stack for FP-based unwinding.
fn coroEntry() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (builtin.os.tag == .windows) {
                // Windows x64 ABI: first integer arg in RCX, requires 32-byte shadow space
                if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
                    asm volatile (
                        \\ subq $32, %%rsp
                        \\ leaq 1f(%%rip), %%rax
                        \\ pushq %%rax
                        \\ movq 48(%%rsp), %%rcx
                        \\ jmpq *40(%%rsp)
                        \\1:
                    );
                } else {
                    asm volatile (
                        \\ subq $32, %%rsp
                        \\ pushq $0
                        \\ movq 48(%%rsp), %%rcx
                        \\ jmpq *40(%%rsp)
                    );
                }
            } else {
                // System V AMD64 ABI: first integer arg in RDI
                if (builtin.zig_version.major == 0 and builtin.zig_version.minor < 16) {
                    asm volatile (
                        \\ leaq 1f(%%rip), %%rax
                        \\ pushq %%rax
                        \\ movq 16(%%rsp), %%rdi
                        \\ jmpq *8(%%rsp)
                        \\1:
                    );
                } else {
                    asm volatile (
                        \\ pushq $0
                        \\ movq 16(%%rsp), %%rdi
                        \\ jmpq *8(%%rsp)
                    );
                }
            }
        },
        .aarch64 => {
            // Create sentinel frame for FP-based unwinding (needed for macOS/aarch64)
            asm volatile (
                \\ stp xzr, xzr, [sp, #-16]!
                \\ mov x29, sp
                \\ mov x30, xzr
                \\ ldp x2, x0, [sp, #16]
                \\ br x2
            );
        },
        .arm => {
            // Create sentinel frame for FP-based unwinding (ARM uses r11 for fp)
            asm volatile (
                \\ push {r0, r1}
                \\ mov r11, sp
                \\ mov r14, #0
                \\ ldr r0, [sp, #12]
                \\ ldr r2, [sp, #8]
                \\ bx r2
            );
        },
        .thumb => {
            // Create sentinel frame for FP-based unwinding (Thumb uses r7 for fp)
            asm volatile (
                \\ push {r0, r1}
                \\ mov r7, sp
                \\ mov r14, #0
                \\ ldr r0, [sp, #12]
                \\ ldr r2, [sp, #8]
                \\ bx r2
            );
        },
        .riscv64 => asm volatile (
            \\ ld a0, 8(sp)
            \\ ld t0, 0(sp)
            \\ jr t0
        ),
        .riscv32 => asm volatile (
            \\ lw a0, 4(sp)
            \\ lw t0, 0(sp)
            \\ jr t0
        ),
        .loongarch64 => asm volatile (
            \\ ld.d $a0, $sp, 8
            \\ ld.d $t0, $sp, 0
            \\ jr $t0
        ),
        .powerpc64, .powerpc64le => asm volatile (
            \\ ld 12, 0(1)
            \\ ld 3, 8(1)
            \\ mtctr 12
            \\ bctr
        ),
        // setupContext stores the Entrypoint address in ctx.fp (not ctx.sp).
        // ctx.sp is lowered by 2176 bytes to reserve space below the Entrypoint
        // for the SPARC V9 register save area (at %sp+2047, 128 bytes).
        // On entry: %i6 = Entrypoint address (func at +0, context at +8).
        // Zero %o7 so the callee's %i7 = 0, terminating stack traces.
        .sparc64 => asm volatile (
            \\ mov %%g0, %%o7
            \\ ldx [%%i6 + 0], %%o1
            \\ ldx [%%i6 + 8], %%o0
            \\ jmp %%o1
            \\ nop
        ),
        else => @compileError("unsupported architecture"),
    }
}

pub const Coroutine = struct {
    context: Context = undefined,
    parent_context_ptr: *Context,

    /// Returns the current coroutine for this thread, or null if not in a coroutine.
    pub fn getCurrent() ?*Coroutine {
        if (getCurrentContext()) |context| {
            return @alignCast(@fieldParentPtr("context", context));
        }
        return null;
    }

    /// Set the current coroutine context for this thread.
    pub fn setCurrent(self: *Coroutine) void {
        setCurrentContext(&self.context);
    }

    /// Clear the current coroutine context for this thread.
    pub fn clearCurrent() void {
        setCurrentContext(null);
    }

    /// Step into the coroutine
    pub fn step(self: *Coroutine) void {
        switchContext(self.parent_context_ptr, &self.context);
    }

    /// Yield control back to the caller
    pub fn yield(self: *Coroutine) void {
        switchContext(&self.context, self.parent_context_ptr);
    }

    /// Yield control to another coroutine
    pub fn yieldTo(self: *Coroutine, other: *Coroutine) void {
        switchContext(&self.context, &other.context);
    }

    pub fn setup(self: *Coroutine, func: *const fn (*Coroutine, ?*anyopaque) void, userdata: ?*anyopaque) void {
        const Entrypoint = extern struct {
            func: *const fn (*anyopaque) callconv(.c) noreturn,
            context: *anyopaque,
        };

        const CoroutineData = struct {
            coro: *Coroutine,
            func: *const fn (*Coroutine, ?*anyopaque) void,
            userdata: ?*anyopaque,

            fn entrypointFn(context_ptr: *anyopaque) callconv(.c) noreturn {
                const coro_data: *@This() = @ptrCast(@alignCast(context_ptr));
                const coro = coro_data.coro;

                coro_data.func(coro, coro_data.userdata);

                // Coroutine function has returned - caller must track completion
                coro.yield();
                unreachable;
            }
        };

        // Stack grows downward: base (high address) -> limit (low address)
        var stack_top = self.context.stack_info.base;
        const stack_limit = self.context.stack_info.limit;

        // Copy our wrapper to stack (allocate downward from top)
        stack_top = std.mem.alignBackward(usize, stack_top - @sizeOf(CoroutineData), @alignOf(CoroutineData));
        if (stack_top < stack_limit) @panic("Stack overflow during coroutine setup: not enough space for CoroutineData");
        const data: *CoroutineData = @ptrFromInt(stack_top);
        data.coro = self;
        data.func = func;
        data.userdata = userdata;

        // Allocate and configure structure for coroEntry
        stack_top = std.mem.alignBackward(usize, stack_top - @sizeOf(Entrypoint), Context.stack_alignment);
        if (stack_top < stack_limit) @panic("Stack overflow during coroutine setup: not enough space for Entrypoint");
        const entry: *Entrypoint = @ptrFromInt(stack_top);
        entry.func = &CoroutineData.entrypointFn;
        entry.context = data;

        // Initialize the context with the entry point
        setupContext(&self.context, stack_top, &coroEntry);

        // Register this coroutine as its own TSan fiber so races between it and
        // other coroutines are detected and its private memory is not flagged
        // when it migrates between OS threads. No-op unless built with TSan.
        self.context.tsan_fiber = tsan.createFiber();
    }

    /// Retire the coroutine. Call once it has finished and control is no longer
    /// on its stack (e.g. from the owning task's teardown). Currently this only
    /// retires the TSan fiber; a no-op unless built with `-fsanitize-thread`.
    pub fn deinit(self: *Coroutine) void {
        tsan.destroyFiber(self.context.tsan_fiber);
        self.context.tsan_fiber = tsan.none;
    }
};

pub fn Closure(func: anytype) type {
    const func_info = @typeInfo(@TypeOf(func));
    const ReturnType = func_info.@"fn".return_type.?;
    const FullArgs = std.meta.ArgsTuple(@TypeOf(func));

    // Build a new tuple type without the first argument (Coroutine)
    const arg_types = std.meta.fieldTypes(FullArgs);
    comptime var user_types: [arg_types.len - 1]type = undefined;
    inline for (arg_types[1..], 0..) |ArgType, i| {
        user_types[i] = ArgType;
    }
    const UserArgs = @Tuple(&user_types);

    return struct {
        args: UserArgs,
        result: ReturnType = undefined,
        finished: bool = false,

        pub fn init(a: UserArgs) @This() {
            return .{ .args = a };
        }

        pub fn start(coro: *Coroutine, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            // Prepend the coroutine to the args tuple
            const full_args = .{coro} ++ self.args;
            self.result = @call(.auto, func, full_args);
            self.finished = true;
        }
    };
}

test "Coroutine: basic" {
    var parent_context: Context = undefined;

    var coro: Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    try stackAlloc(&coro.context.stack_info, 64 * 1024, 4096);
    defer stackFree(coro.context.stack_info);

    const Fn = struct {
        fn sum(_: *Coroutine, a: u32, b: u32) u32 {
            return a + b;
        }
    };

    const C = Closure(Fn.sum);
    var closure = C.init(.{ 1, 2 });
    coro.setup(&C.start, &closure);

    while (!closure.finished) {
        coro.step();
    }

    try std.testing.expectEqual(3, closure.result);
}

test "Coroutine: recursion" {
    var parent_context: Context = undefined;

    var coro: Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    try stackAlloc(&coro.context.stack_info, 64 * 1024, 4096);
    defer stackFree(coro.context.stack_info);

    const Fn = struct {
        fn fib(c: *Coroutine, a: u32) u32 {
            if (a <= 1) return 1;
            return fib(c, a - 1) + fib(c, a - 2);
        }
    };

    const C = Closure(Fn.fib);
    var closure = C.init(.{ 10 });
    coro.setup(&C.start, &closure);

    while (!closure.finished) {
        coro.step();
    }

    try std.testing.expectEqual(89, closure.result);
}

test "Coroutine: message passing" {
    var parent_context: Context = undefined;

    var coro1: Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    try stackAlloc(&coro1.context.stack_info, 64 * 1024, 4096);
    defer stackFree(coro1.context.stack_info);

    var coro2: Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    try stackAlloc(&coro2.context.stack_info, 64 * 1024, 4096);
    defer stackFree(coro2.context.stack_info);

    // Simple single-slot channel
    const Channel = struct {
        data: ?i32 = null,

        fn send(self: *@This(), coro: *Coroutine, value: i32) void {
            while (self.data != null) {
                coro.yield(); // wait for slot to be empty
            }
            self.data = value;
        }

        fn recv(self: *@This(), coro: *Coroutine) i32 {
            while (self.data == null) {
                coro.yield(); // wait for data
            }
            const value = self.data.?;
            self.data = null;
            return value;
        }
    };

    var chan_to_receiver = Channel{};
    var chan_to_sender = Channel{};

    const sender = struct {
        fn run(coro: *Coroutine, send_chan: *Channel, recv_chan: *Channel) void {
            var counter: i32 = 0;
            while (counter < 10) {
                send_chan.send(coro, counter);
                const reply = recv_chan.recv(coro);
                assert(reply == counter); // verify we got back what we sent
                counter += 1;
            }
            // Send EOF
            send_chan.send(coro, -1);
        }
    }.run;

    const receiver = struct {
        fn run(coro: *Coroutine, recv_chan: *Channel, send_chan: *Channel) i32 {
            var last: i32 = 0;
            while (true) {
                const msg = recv_chan.recv(coro);
                if (msg == -1) break;
                last = msg;
                send_chan.send(coro, msg); // echo it back
            }
            return last;
        }
    }.run;

    const SenderClosure = Closure(sender);
    const ReceiverClosure = Closure(receiver);

    var sender_closure = SenderClosure.init(.{ &chan_to_receiver, &chan_to_sender });
    var receiver_closure = ReceiverClosure.init(.{ &chan_to_receiver, &chan_to_sender });

    coro1.setup(&SenderClosure.start, &sender_closure);
    coro2.setup(&ReceiverClosure.start, &receiver_closure);

    // Round-robin scheduler
    while (!sender_closure.finished or !receiver_closure.finished) {
        if (!sender_closure.finished) coro1.step();
        if (!receiver_closure.finished) coro2.step();
    }

    try std.testing.expectEqual(9, receiver_closure.result);
}

test "Coroutine: allocator inside coroutine" {
    // This serves two purposes:
    //  - it tests a fairly complex function inside a coroutine (uses a lot of stack)
    //  - it tests the new `std.debug` refactor in Zig 0.16
    //    (https://github.com/ziglang/zig/pull/25227)

    const st = @import("stack.zig");

    try st.setupStackGrowth();
    defer st.cleanupStackGrowth();

    var parent_context: Context = undefined;

    var coro: Coroutine = .{
        .parent_context_ptr = &parent_context,
        .context = undefined,
    };
    try stackAlloc(&coro.context.stack_info, 8 * 1024 * 1024, 4096);
    defer stackFree(coro.context.stack_info);

    const Fn = struct {
        fn main(_: *Coroutine) !void {
            for (0..8) |k| {
                var buf = try std.testing.allocator.alloc(u8, 1024);
                defer std.testing.allocator.free(buf);

                for (0..1024) |i| {
                    buf[i] = @intCast((i + k) & 0xff);
                }
            }
        }
    };

    const C = Closure(Fn.main);
    var closure = C.init(.{});
    coro.setup(&C.start, &closure);

    while (!closure.finished) {
        coro.step();
    }

    try std.testing.expectEqual({}, closure.result);
}


test "Coroutine: stack trace" {
    if (builtin.cpu.arch == .powerpc64 or builtin.cpu.arch == .powerpc64le) return error.SkipZigTest;
    // Stack unwinding works on ARM/Thumb in Zig 0.15.2 but is broken in 0.16 -
    // captureCurrentStackTrace returns an empty trace even with a sentinel frame installed.
    // See https://codeberg.org/ziglang/zig/issues/31082
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) return error.SkipZigTest;

    const stack = @import("stack.zig");

    var parent_ctx: Context = undefined;
    var coro = Coroutine{
        .parent_context_ptr = &parent_ctx,
        .context = undefined,
    };

    try stack.stackAlloc(&coro.context.stack_info, 4 * 1024 * 1024, 4 * 1024 * 1024);
    defer stack.stackFree(coro.context.stack_info);

    const TestData = struct {
        trace: std.debug.StackTrace = undefined,
        trace_addrs: [32]usize = undefined,
        finished: bool = false,

        fn coroFunc(c: *Coroutine, userdata: ?*anyopaque) void {
            c.yield(); // make it slightly more complicated and yield once
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.trace = std.debug.captureCurrentStackTrace(.{}, &self.trace_addrs);
            self.finished = true;
        }
    };

    var test_data = TestData{};
    coro.setup(&TestData.coroFunc, &test_data);

    while (!test_data.finished) {
        coro.step();
    }

    const trace_len = test_data.trace.return_addresses.len;
    std.testing.expect(trace_len > 1 and trace_len < 7) catch |err| {
        std.debug.dumpStackTrace(&test_data.trace);
        return err;
    };
}

