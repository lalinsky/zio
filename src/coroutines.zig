const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

threadlocal var current_coroutine: ?*Coroutine = null;

pub inline fn getCurrent() ?*Coroutine {
    return current_coroutine;
}

pub inline fn yield() void {
    const coro = current_coroutine orelse unreachable;
    switchContext(&coro.context, coro.parent_context_ptr);
}

const DEFAULT_STACK_SIZE = 64 * 1024;

pub const CoroutineState = enum(u8) {
    ready = 0,
    running = 1,
    waiting = 2,
    dead = 3,
};

pub const AnyCoroutineResult = union(enum) {
    pending: void, // Coroutine hasn't finished yet
    success: *anyopaque, // Pointer to coroutine result
    failure: anyerror, // Coroutine failed with this error
};

pub fn CoroutineResult(comptime T: type) type {
    return struct {
        const Self = @This();
        any_result: *AnyCoroutineResult,

        pub fn get(self: Self) T {
            switch (self.any_result.*) {
                .pending => {
                    @panic("Coroutine is still pending");
                },
                .success => |ptr| {
                    if (T == void) {
                        return {};
                    } else {
                        const type_info = @typeInfo(T);
                        if (type_info == .error_union) {
                            // For error unions, we stored only the payload, so return it directly
                            const payload_type = type_info.error_union.payload;
                            if (payload_type == void) {
                                return {};
                            } else {
                                const typed_ptr: *payload_type = @ptrCast(@alignCast(ptr));
                                return typed_ptr.*;
                            }
                        } else {
                            const typed_ptr: *T = @ptrCast(@alignCast(ptr));
                            return typed_ptr.*;
                        }
                    }
                },
                .failure => |err| {
                    const type_info = @typeInfo(T);
                    if (type_info == .error_union) {
                        return @errorCast(err);
                    } else {
                        @panic("Coroutine failed but result type cannot represent errors");
                    }
                },
            }
        }
    };
}

pub const stack_alignment = 16;
pub const Stack = []align(stack_alignment) u8;
pub const StackPtr = [*]align(stack_alignment) u8;

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

pub const EntryPointFn = fn () callconv(.naked) noreturn;

pub fn initContext(stack_ptr: StackPtr, entry_point: *const EntryPointFn) Context {
    return switch (builtin.cpu.arch) {
        .x86_64 => .{
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
              [new] "{rcx}" (new_context),
            : "rdx", "rbx", "rdi", "rsi", "r12", "r13", "r14", "r15", "xmm6", "xmm7", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", "memory"
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
              [new] "{x1}" (new_context),
            : "x9", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "memory"
        ),
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
                asm volatile (
                    \\ pushq $0
                    \\ leaq 8(%%rsp), %%rcx
                    \\ jmpq *8(%%rsp)
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

pub const CoroutineOptions = struct {
    stack_size: usize = DEFAULT_STACK_SIZE,
};

pub const Coroutine = struct {
    context: Context,
    parent_context_ptr: *Context,
    stack: Stack,
    state: CoroutineState,
    result: AnyCoroutineResult,

    pub fn init(allocator: std.mem.Allocator, comptime func: anytype, args: anytype, options: CoroutineOptions) !Coroutine {
        const Args = @TypeOf(args);
        const ReturnType = @TypeOf(@call(.always_inline, func, args));

        // For error unions, store only the payload type
        const StoredReturnType = switch (@typeInfo(ReturnType)) {
            .error_union => |info| info.payload,
            else => ReturnType,
        };

        const CoroutineData = struct {
            func: *const fn (*anyopaque) callconv(.c) noreturn,
            args: Args,
            result: StoredReturnType,

            fn wrapper(self_ptr: *anyopaque) callconv(.c) noreturn {
                const self: *@This() = @ptrCast(@alignCast(self_ptr));
                const coro = current_coroutine orelse unreachable;
                coro.state = .running;

                // Handle both void and error union return types
                const return_info = @typeInfo(ReturnType);
                if (return_info == .error_union) {
                    if (@call(.always_inline, func, self.args)) |result| {
                        self.result = result;
                        coro.result = .{ .success = &self.result };
                    } else |err| {
                        coro.result = .{ .failure = err };
                    }
                } else {
                    // Non-void, non-error return type - call and store result
                    if (ReturnType == void) {
                        @call(.always_inline, func, self.args);
                        // For void, we still need to point to something valid
                        coro.result = .{ .success = &self.result };
                    } else {
                        self.result = @call(.always_inline, func, self.args);
                        coro.result = .{ .success = &self.result };
                    }
                }

                coro.state = .dead;
                switchContext(&coro.context, coro.parent_context_ptr);
                unreachable;
            }
        };

        // Allocate stack
        const stack_size = std.mem.alignForward(usize, options.stack_size + @sizeOf(CoroutineData), stack_alignment);
        const stack = try allocator.alignedAlloc(u8, stack_alignment, stack_size);
        errdefer allocator.free(stack);

        // Convert the stack pointer to ints for calculations
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = stack_base + stack.len;

        // Store function pointer, args, and result space as a contiguous block at the end of stack
        const data_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(CoroutineData), stack_alignment);

        // Set up function pointer and args
        const data: *CoroutineData = @ptrFromInt(data_ptr);
        data.func = &CoroutineData.wrapper;
        data.args = args;

        return Coroutine{
            .context = initContext(@ptrCast(@alignCast(data)), &coroEntry),
            .stack = stack,
            .state = .ready,
            .parent_context_ptr = undefined, // Will be set when switchTo is called
            .result = .pending,
        };
    }

    pub fn deinit(self: *Coroutine, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }

    pub fn switchTo(self: *Coroutine, parent_context_ptr: *Context) void {
        const old_coro = current_coroutine;
        current_coroutine = self;
        defer current_coroutine = old_coro;

        self.parent_context_ptr = parent_context_ptr;
        switchContext(parent_context_ptr, &self.context);
    }

    pub fn waitForReady(self: *Coroutine) void {
        self.state = .waiting;
        yield();
    }

    pub fn getResult(self: *Coroutine, comptime T: type) CoroutineResult(T) {
        return CoroutineResult(T){ .any_result = &self.result };
    }
};
