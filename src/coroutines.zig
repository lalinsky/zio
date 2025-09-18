const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

const ContextSwitcher = switch (builtin.cpu.arch) {
    .x86_64 => switch (builtin.os.tag) {
        .windows => Intel_Microsoft,
        else => Intel_SysV,
    },
    .aarch64 => Arm_64,
    else => Unsupported,
};

const is_supported = switch (builtin.cpu.arch) {
    .x86_64 => true,
    .aarch64 => true,
    else => false,
};

pub const stack_alignment = ContextSwitcher.alignment;
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
    ContextSwitcher.swap(&coro.context, &coro.scheduler.main_context);
}

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

pub const CoroutineState = enum {
    ready,
    running,
    waiting,
    dead,
};

pub const CoroutineResult = union(enum) {
    pending: void,    // Coroutine hasn't finished yet
    success: void,    // Coroutine completed successfully
    failure: anyerror, // Coroutine failed with this error
};

pub const Coroutine = struct {
    context: *anyopaque,
    stack: Stack,
    state: CoroutineState,
    scheduler: *Scheduler,
    id: u32,
    result: CoroutineResult,

    fn init(scheduler: *Scheduler, id: u32, stack: Stack, comptime func: anytype, args: anytype) Error!Coroutine {
        if (!is_supported) return error.UnsupportedPlatform;

        const Args = @TypeOf(args);
        const stack_base = @intFromPtr(stack.ptr);
        const stack_end = @intFromPtr(stack.ptr + stack.len);

        // Store args at the end of the stack
        var stack_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(Args), stack_alignment);
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Store the arguments at this location
        const args_ptr: *align(1) Args = @ptrFromInt(stack_ptr);
        args_ptr.* = args;

        // Reserve space for the context switching data
        stack_ptr = std.mem.alignBackward(usize, stack_ptr - @sizeOf(usize) * ContextSwitcher.word_count, stack_alignment);
        assert(std.mem.isAligned(stack_ptr, stack_alignment));
        if (stack_ptr < stack_base) return error.StackTooSmall;

        // Create entry point using the zefi pattern
        const entry_point = struct {
            fn entry() callconv(.c) noreturn {
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
                ContextSwitcher.swap(&coro.context, &coro.scheduler.main_context);
                unreachable;
            }
        }.entry;

        // Set up the entry point in the context
        var entry: [*]*const fn () callconv(.c) noreturn = @ptrFromInt(stack_ptr);
        entry[ContextSwitcher.entry_offset] = entry_point;

        return Coroutine{
            .context = @ptrFromInt(stack_ptr),
            .stack = stack,
            .state = .ready,
            .scheduler = scheduler,
            .id = id,
            .result = .pending,
        };
    }

    pub fn switchTo(self: *Coroutine) void {
        const old_coro = current_coroutine;
        current_coroutine = self;
        defer current_coroutine = old_coro;

        ContextSwitcher.swap(&self.scheduler.main_context, &self.context);
    }
};

pub const Scheduler = struct {
    coroutines: [MAX_COROUTINES]Coroutine,
    current: i32,
    count: u32,
    main_context: *anyopaque,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Scheduler {
        return Scheduler{
            .coroutines = undefined,
            .current = -1,
            .count = 0,
            .main_context = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (0..self.count) |i| {
            self.allocator.free(self.coroutines[i].stack);
        }
    }

    pub fn spawn(self: *Scheduler, comptime func: anytype, args: anytype) !u32 {
        if (self.count >= MAX_COROUTINES) {
            return error.TooManyCoroutines;
        }

        const id = self.count;
        const stack = try self.allocator.alignedAlloc(u8, stack_alignment, STACK_SIZE);

        self.coroutines[id] = try Coroutine.init(self, id, stack, func, args);
        self.count += 1;

        return id;
    }

    pub fn runOnce(self: *Scheduler) bool {
        // Find next ready coroutine
        var next: i32 = -1;
        for (0..self.count) |i| {
            if (self.coroutines[i].state == .ready) {
                next = @intCast(i);
                break;
            }
        }

        if (next == -1) return false; // No ready coroutines

        self.current = next;
        self.coroutines[@intCast(next)].state = .running;
        self.coroutines[@intCast(next)].switchTo();

        return true;
    }

    pub fn run(self: *Scheduler) void {
        self.current = -1;

        while (true) {
            if (!self.runOnce()) break;
        }

        for (0..self.count) |i| {
            self.allocator.free(self.coroutines[i].stack);
        }
        self.count = 0;
    }

    pub fn yieldCurrent(self: *Scheduler) void {
        if (self.current == -1) return;
        // Don't change state - let the coroutine decide its own state before yielding
        yield();
    }
};

// Platform-specific context switching implementations
const Unsupported = struct {
    pub const alignment = 16;
    pub const word_count = 0;
    pub const entry_offset = 0;

    pub fn swap(
        noalias _: **anyopaque,
        noalias _: **anyopaque,
    ) void {
        @panic("unsupported platform");
    }
};

const Intel_SysV = struct {
    pub const word_count = 7;
    pub const entry_offset = word_count - 1;
    pub const alignment = 16;
    pub const swap = zefi_stack_swap;

    extern fn zefi_stack_swap(
        noalias current_context_ptr: **anyopaque,
        noalias new_context_ptr: **anyopaque,
    ) void;

    comptime {
        asm (assembly);
    }

    const assembly =
        \\.global zefi_stack_swap
        \\zefi_stack_swap:
        \\  pushq %rbx
        \\  pushq %rbp
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\
        \\  movq %rsp, (%rdi)
        \\  movq (%rsi), %rsp
        \\
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rbp
        \\  popq %rbx
        \\
        \\  retq
    ;
};

const Intel_Microsoft = struct {
    pub const word_count = 31;
    pub const entry_offset = word_count - 1;
    pub const alignment = 16;
    pub const swap = zefi_stack_swap;

    extern fn zefi_stack_swap(
        noalias current_context_ptr: **anyopaque,
        noalias new_context_ptr: **anyopaque,
    ) void;

    comptime {
        asm (assembly);
    }

    const assembly =
        \\.global zefi_stack_swap
        \\zefi_stack_swap:
        \\  pushq %gs:0x10
        \\  pushq %gs:0x08
        \\
        \\  pushq %rbx
        \\  pushq %rbp
        \\  pushq %rdi
        \\  pushq %rsi
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\
        \\  subq $160, %rsp
        \\  movups %xmm6, 0x00(%rsp)
        \\  movups %xmm7, 0x10(%rsp)
        \\  movups %xmm8, 0x20(%rsp)
        \\  movups %xmm9, 0x30(%rsp)
        \\  movups %xmm10, 0x40(%rsp)
        \\  movups %xmm11, 0x50(%rsp)
        \\  movups %xmm12, 0x60(%rsp)
        \\  movups %xmm13, 0x70(%rsp)
        \\  movups %xmm14, 0x80(%rsp)
        \\  movups %xmm15, 0x90(%rsp)
        \\
        \\  movq %rsp, (%rcx)
        \\  movq (%rdx), %rsp
        \\
        \\  movups 0x00(%rsp), %xmm6
        \\  movups 0x10(%rsp), %xmm7
        \\  movups 0x20(%rsp), %xmm8
        \\  movups 0x30(%rsp), %xmm9
        \\  movups 0x40(%rsp), %xmm10
        \\  movups 0x50(%rsp), %xmm11
        \\  movups 0x60(%rsp), %xmm12
        \\  movups 0x70(%rsp), %xmm13
        \\  movups 0x80(%rsp), %xmm14
        \\  movups 0x90(%rsp), %xmm15
        \\  addq $160, %rsp
        \\
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rsi
        \\  popq %rdi
        \\  popq %rbp
        \\  popq %rbx
        \\
        \\  popq %gs:0x08
        \\  popq %gs:0x10
        \\
        \\  retq
    ;
};

const Arm_64 = struct {
    pub const word_count = 20;
    pub const entry_offset = 0;
    pub const alignment = 16;
    pub const swap = zefi_stack_swap;

    extern fn zefi_stack_swap(
        noalias current_context_ptr: **anyopaque,
        noalias new_context_ptr: **anyopaque,
    ) void;

    comptime {
        asm (assembly);
    }

    const assembly =
        \\.global zefi_stack_swap
        \\zefi_stack_swap:
        \\  stp lr, fp, [sp, #-20*8]!
        \\  stp d8, d9, [sp, #2*8]
        \\  stp d10, d11, [sp, #4*8]
        \\  stp d12, d13, [sp, #6*8]
        \\  stp d14, d15, [sp, #8*8]
        \\  stp x19, x20, [sp, #10*8]
        \\  stp x21, x22, [sp, #12*8]
        \\  stp x23, x24, [sp, #14*8]
        \\  stp x25, x26, [sp, #16*8]
        \\  stp x27, x28, [sp, #18*8]
        \\
        \\  mov x9, sp
        \\  str x9, [x0]
        \\  ldr x9, [x1]
        \\  mov sp, x9
        \\
        \\  ldp x27, x28, [sp, #18*8]
        \\  ldp x25, x26, [sp, #16*8]
        \\  ldp x23, x24, [sp, #14*8]
        \\  ldp x21, x22, [sp, #12*8]
        \\  ldp x19, x20, [sp, #10*8]
        \\  ldp d14, d15, [sp, #8*8]
        \\  ldp d12, d13, [sp, #6*8]
        \\  ldp d10, d11, [sp, #4*8]
        \\  ldp d8, d9, [sp, #2*8]
        \\  ldp lr, fp, [sp], #20*8
        \\
        \\  ret
    ;
};