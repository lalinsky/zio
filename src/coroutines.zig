const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

const is_supported = switch (builtin.cpu.arch) {
    .x86_64 => true,
    .aarch64 => true,
    else => false,
};

pub const stack_alignment = 16;
pub const Stack = []align(stack_alignment) u8;

pub const Error = error{
    StackTooSmall,
    UnsupportedPlatform,
    TooManyCoroutines,
};

threadlocal var current_coroutine: ?*Coroutine = null;

pub fn getCurrentCoroutine() ?*Coroutine {
    return current_coroutine;
}

pub fn yield() void {
    const coro = current_coroutine orelse unreachable;
    swapContext(&coro.context, coro.parent_context);
}

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

pub const CoroutineState = enum(u8) {
    ready = 0,
    running = 1,
    waiting = 2,
    dead = 3,
};

pub const CoroutineResult = union(enum) {
    pending: void, // Coroutine hasn't finished yet
    success: void, // Coroutine completed successfully
    failure: anyerror, // Coroutine failed with this error
};

pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
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

pub fn initContext(stack_ptr: usize, entry_point: *const fn () callconv(.withStackAlign(.c, 16)) noreturn) Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
            // x86_64 System V ABI requires 16-byte alignment before CALL instruction.
            // Since we use JMP (not CALL), we must simulate the post-CALL state:
            // CALL would push 8-byte return address, so we subtract 8 to simulate this.
            // The function never returns, so we don't need an actual return address.
            .rsp = stack_ptr - 8,
            .rbp = 0,
            .rip = @intFromPtr(entry_point),
        },
        .aarch64 => .{
            // ARM64 AAPCS: Stack must always remain 16-byte aligned.
            // Unlike x86_64, ARM64 stores return address in x30 register (not stack),
            // so no stack adjustment is needed to simulate post-call state.
            .sp = stack_ptr,
            .fp = 0,
            .pc = @intFromPtr(entry_point),
        },
        else => @compileError("unsupported architecture"),
    };
}

/// Context switching function using C calling convention.
///
/// This function follows C ABI, which means:
/// - Caller-saved registers (rax, rcx, rdx, rsi, rdi, r8-r11, xmm0-xmm15 on x86_64;
///   x0-x18, x30, v0-v7, v16-v31 on ARM64) can be freely modified
/// - Callee-saved registers must be preserved OR marked as clobbered
///
/// Since we're doing a context switch, all callee-saved registers will have
/// different values when we "return" (jump to new context), so we mark them
/// as clobbered to inform the compiler they cannot be relied upon.
pub fn swapContext(
    noalias current_context: *Context,
    noalias new_context: *Context,
) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
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
              [new] "{rcx}" (new_context)
            : "rbx", "r12", "r13", "r14", "r15", "xmm16", "xmm17", "xmm18", "xmm19", "xmm20", "xmm21", "xmm22", "xmm23", "xmm24", "xmm25", "xmm26", "xmm27", "xmm28", "xmm29", "xmm30", "xmm31", "memory"
        ),
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
              [new] "{x1}" (new_context)
            : "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "memory"
        ),
        else => @compileError("unsupported architecture"),
    }
}

pub const Coroutine = struct {
    context: Context,
    stack: Stack,
    state: CoroutineState,
    parent_context: *Context,
    id: u64,
    result: CoroutineResult,

    pub fn init(id: u64, stack: Stack, comptime func: anytype, args: anytype) Error!Coroutine {
        if (!is_supported) return error.UnsupportedPlatform;

        const Args = @TypeOf(args);
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = @intFromPtr(stack.ptr + stack.len);

        // Store args at the end of the stack
        const stack_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(Args), stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Store the arguments at this location
        const args_ptr: *align(1) Args = @ptrFromInt(stack_ptr);
        args_ptr.* = args;

        // No need to reserve stack space for context - it's stored in the Coroutine struct

        // Create entry point - no args needed, we'll look them up
        const entry_point = struct {
            fn entry() callconv(.withStackAlign(.c, 16)) noreturn {
                const coro = current_coroutine orelse unreachable;
                // Calculate args location from the stack boundaries
                const coro_stack_end = @intFromPtr(coro.stack.ptr) + coro.stack.len;
                const args_location: *align(1) Args = @ptrFromInt(std.mem.alignBackward(usize, coro_stack_end - @sizeOf(Args), stack_alignment));

                // Handle both void and error union return types
                const ReturnType = @TypeOf(@call(.auto, func, args_location.*));

                if (ReturnType == void) {
                    @call(.auto, func, args_location.*);
                    coro.result = .success;
                } else {
                    const return_info = @typeInfo(ReturnType);
                    if (return_info == .error_union) {
                        if (@call(.auto, func, args_location.*)) |_| {
                            coro.result = .success;
                        } else |err| {
                            coro.result = .{ .failure = err };
                        }
                    } else {
                        // Non-void, non-error return type - just call and mark success
                        _ = @call(.auto, func, args_location.*);
                        coro.result = .success;
                    }
                }

                coro.state = .dead;
                const parent = coro.parent_context;
                coro.parent_context = undefined;
                swapContext(&coro.context, parent);
                unreachable;
            }
        }.entry;

        return Coroutine{
            .context = initContext(stack_ptr, &entry_point),
            .stack = stack,
            .state = .ready,
            .parent_context = undefined, // Will be set when switchTo is called
            .id = id,
            .result = .pending,
        };
    }

    pub fn switchTo(self: *Coroutine, parent_context: *Context) void {
        const old_coro = current_coroutine;
        current_coroutine = self;
        defer current_coroutine = old_coro;

        self.parent_context = parent_context;
        swapContext(parent_context, &self.context);
    }

    pub fn waitForReady(self: *Coroutine) void {
        self.state = .waiting;
        yield();
    }
};

fn fiberEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmpq *(%%rsp)
        ),
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ ldr x2, [sp, #-8]
            \\ br x2
        ),
        else => @compileError("unsupported architecture"),
    }
}
