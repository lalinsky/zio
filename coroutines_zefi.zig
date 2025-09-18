const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const assert = std.debug.assert;

// Embedded zefi implementation
const Fiber = struct {
    pub const stack_alignment = StackContext.alignment;
    pub const Stack = []align(stack_alignment) u8;

    pub const Error = error{
        StackTooSmall,
        UnsupportedPlatform,
    };

    pub fn init(stack: Stack, user_data: usize, comptime func: anytype, args: anytype) Error!*Fiber {
        if (!is_supported) return error.UnsupportedPlatform;

        const Args = @TypeOf(args);
        const state = try State.init(stack, user_data, @sizeOf(Args), struct {
            fn entry() callconv(.c) noreturn {
                const state = tls_state orelse unreachable;

                const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
                @call(.auto, func, args_ptr.*);

                StackContext.swap(&state.stack_context, &state.caller_context);
                unreachable;
            }
        }.entry);

        const args_ptr: *align(1) Args = @ptrFromInt(@intFromPtr(state) - @sizeOf(Args));
        args_ptr.* = args;

        return @ptrCast(state);
    }

    threadlocal var tls_state: ?*State = null;

    pub inline fn current() ?*Fiber {
        return @ptrCast(tls_state);
    }

    pub fn getUserDataPtr(fiber: *Fiber) *usize {
        const state: *State = @ptrCast(@alignCast(fiber));
        return &state.user_data;
    }

    pub fn switchTo(fiber: *Fiber) void {
        const state: *State = @ptrCast(@alignCast(fiber));

        const old_state = tls_state;
        assert(old_state != state);
        tls_state = state;
        defer tls_state = old_state;

        StackContext.swap(&state.caller_context, &state.stack_context);
    }

    pub fn yield() void {
        const state = tls_state orelse unreachable;
        StackContext.swap(&state.stack_context, &state.caller_context);
    }

    const State = extern struct {
        caller_context: *anyopaque,
        stack_context: *anyopaque,
        user_data: usize,

        fn init(stack: Stack, user_data: usize, args_size: usize, entry_point: *const fn () callconv(.c) noreturn) Error!*State {
            const stack_base = @intFromPtr(stack.ptr);
            const stack_end = @intFromPtr(stack.ptr + stack.len);

            var stack_ptr = std.mem.alignBackward(usize, stack_end - @sizeOf(State), stack_alignment);
            if (stack_ptr < stack_base) return error.StackTooSmall;

            const state: *State = @ptrFromInt(stack_ptr);

            stack_ptr = std.mem.alignBackward(usize, stack_ptr - args_size, stack_alignment);
            if (stack_ptr < stack_base) return error.StackTooSmall;

            stack_ptr = std.mem.alignBackward(usize, stack_ptr - @sizeOf(usize) * StackContext.word_count, stack_alignment);
            assert(std.mem.isAligned(stack_ptr, stack_alignment));
            if (stack_ptr < stack_base) return error.StackTooSmall;

            var entry: [*]@TypeOf(entry_point) = @ptrFromInt(stack_ptr);
            entry[StackContext.entry_offset] = entry_point;

            state.* = .{
                .caller_context = undefined,
                .stack_context = @ptrFromInt(stack_ptr),
                .user_data = user_data,
            };

            return state;
        }
    };

    const StackContext = switch (builtin.cpu.arch) {
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

    const symbol = switch (builtin.target.os.tag) {
        .macos => "_zefi_stack_swap",
        else => "zefi_stack_swap",
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
            std.fmt.comptimePrint(
                \\.global {[symbol]s}
                \\{[symbol]s}:
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
            , .{ .symbol = symbol });
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
            std.fmt.comptimePrint(
                \\.global {[symbol]s}
                \\{[symbol]s}:
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
            , .{ .symbol = symbol });
    };
};

const MAX_COROUTINES = 32;
const STACK_SIZE = 8192;

const CoroutineState = enum {
    ready,
    running,
    dead,
};

const Coroutine = struct {
    fiber: *Fiber,
    stack: Fiber.Stack,
    state: CoroutineState,
    func: *const fn () void,
};

const Scheduler = struct {
    coroutines: [MAX_COROUTINES]Coroutine,
    current: i32,
    count: u32,
    allocator: Allocator,

    fn init(allocator: Allocator) Scheduler {
        var scheduler = Scheduler{
            .coroutines = undefined,
            .current = -1,
            .count = 0,
            .allocator = allocator,
        };

        for (&scheduler.coroutines) |*coro| {
            coro.* = Coroutine{
                .fiber = undefined,
                .stack = &[_]u8{},
                .state = .ready,
                .func = undefined,
            };
        }

        return scheduler;
    }

    fn deinit(self: *Scheduler) void {
        for (0..self.count) |i| {
            self.allocator.free(self.coroutines[i].stack);
        }
    }
};

var g_scheduler: Scheduler = undefined;

fn coroutineWrapper(func: *const fn () void) void {
    func();

    // Mark current coroutine as dead
    if (g_scheduler.current >= 0) {
        g_scheduler.coroutines[@intCast(g_scheduler.current)].state = .dead;
    }

    // Yield back to main scheduler
    Fiber.yield();
}

pub fn schedulerSpawn(func: *const fn () void) !u32 {
    if (g_scheduler.count >= MAX_COROUTINES) {
        return error.TooManyCoroutines;
    }

    const id = g_scheduler.count;
    g_scheduler.count += 1;
    const coro = &g_scheduler.coroutines[id];

    coro.stack = try g_scheduler.allocator.alignedAlloc(u8, Fiber.stack_alignment, STACK_SIZE);
    coro.func = func;
    coro.state = .ready;

    coro.fiber = try Fiber.init(coro.stack, 0, coroutineWrapper, .{func});

    return id;
}

pub fn schedulerYield() void {
    if (g_scheduler.current == -1) return;

    const current_coro = &g_scheduler.coroutines[@intCast(g_scheduler.current)];
    current_coro.state = .ready;

    Fiber.yield();
}

pub fn schedulerRun() void {
    g_scheduler.current = -1;

    while (true) {
        var next: i32 = -1;
        for (0..g_scheduler.count) |i| {
            if (g_scheduler.coroutines[i].state == .ready) {
                next = @intCast(i);
                break;
            }
        }

        if (next == -1) break;

        g_scheduler.current = next;
        g_scheduler.coroutines[@intCast(next)].state = .running;

        g_scheduler.coroutines[@intCast(next)].fiber.switchTo();
    }

    for (0..g_scheduler.count) |i| {
        g_scheduler.allocator.free(g_scheduler.coroutines[i].stack);
    }
    g_scheduler.count = 0;
}

fn task1() void {
    for (0..5) |i| {
        print("Task 1: iteration {}\n", .{i});
        schedulerYield();
    }
    print("Task 1: finished\n", .{});
}

fn task2() void {
    for (0..3) |i| {
        print("Task 2: iteration {}\n", .{i});
        schedulerYield();
    }
    print("Task 2: finished\n", .{});
}

fn task3() void {
    for (0..4) |i| {
        print("Task 3: iteration {}\n", .{i});
        schedulerYield();
    }
    print("Task 3: finished\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    g_scheduler = Scheduler.init(allocator);
    defer g_scheduler.deinit();

    print("Starting coroutine demo\n", .{});

    _ = try schedulerSpawn(task1);
    _ = try schedulerSpawn(task2);
    _ = try schedulerSpawn(task3);

    schedulerRun();

    print("All coroutines finished\n", .{});
}