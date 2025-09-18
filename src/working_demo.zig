const std = @import("std");

const SavedRegs = struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

const Coroutine = struct {
    id: u32,
    registers: SavedRegs,
    stack: []u8,
    finished: bool = false,
};

var main_context: SavedRegs = undefined;
var coroutines: [2]Coroutine = undefined;
var current_coro_id: u32 = 0;

fn switch_context(old_regs: *SavedRegs, new_regs: *SavedRegs) void {
    asm volatile (
        \\movq %%rbx, 0(%[old])
        \\movq %%rbp, 8(%[old])
        \\movq %%rsp, 16(%[old])
        \\movq %%r12, 24(%[old])
        \\movq %%r13, 32(%[old])
        \\movq %%r14, 40(%[old])
        \\movq %%r15, 48(%[old])
        \\
        \\movq 0(%[new]), %%rbx
        \\movq 8(%[new]), %%rbp
        \\movq 16(%[new]), %%rsp
        \\movq 24(%[new]), %%r12
        \\movq 32(%[new]), %%r13
        \\movq 40(%[new]), %%r14
        \\movq 48(%[new]), %%r15
        :
        : [old] "r" (old_regs),
          [new] "r" (new_regs)
        : "memory", "rbx", "rbp", "rsp", "r12", "r13", "r14", "r15"
    );
}

fn coro_yield() void {
    const current = &coroutines[current_coro_id];
    switch_context(&current.registers, &main_context);
}

fn coro_wrapper() callconv(.C) noreturn {
    // Get the function pointer from r12 (we'll store it there)
    const func_ptr: *const fn() void = asm volatile ("movq %%r12, %[result]" : [result] "=r" (-> *const fn() void));

    // Call the actual function
    func_ptr();

    // Mark as finished
    coroutines[current_coro_id].finished = true;

    // Return to main
    switch_context(&coroutines[current_coro_id].registers, &main_context);

    unreachable;
}

fn spawn_coro(allocator: std.mem.Allocator, id: u32, func: *const fn() void) !void {
    const stack = try allocator.alloc(u8, 4096);

    // Set up stack - put return address at top
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    const aligned_stack = (stack_top - 8) & ~@as(usize, 15);
    @as(*usize, @ptrFromInt(aligned_stack)).* = @intFromPtr(&coro_wrapper);

    coroutines[id] = Coroutine{
        .id = id,
        .registers = SavedRegs{
            .rsp = aligned_stack,
            .r12 = @intFromPtr(func), // Store function pointer in r12
        },
        .stack = stack,
    };
}

// Test functions
fn task1() void {
    std.debug.print("Task 1: Start\n", .{});
    coro_yield();
    std.debug.print("Task 1: Middle\n", .{});
    coro_yield();
    std.debug.print("Task 1: End\n", .{});
}

fn task2() void {
    std.debug.print("Task 2: Start\n", .{});
    coro_yield();
    std.debug.print("Task 2: End\n", .{});
}

pub fn main() !void {
    std.debug.print("=== ZIO Virtual Threads Demo ===\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Spawn coroutines
    try spawn_coro(allocator, 0, task1);
    try spawn_coro(allocator, 1, task2);
    defer allocator.free(coroutines[0].stack);
    defer allocator.free(coroutines[1].stack);

    // Simple round-robin scheduler
    while (true) {
        var any_active = false;

        for (0..2) |i| {
            if (!coroutines[i].finished) {
                current_coro_id = @intCast(i);
                std.debug.print("-> Switching to task {}\n", .{i + 1});
                switch_context(&main_context, &coroutines[i].registers);
                any_active = true;
            }
        }

        if (!any_active) break;
    }

    std.debug.print("=== All tasks completed! ===\n", .{});
}