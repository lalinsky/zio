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

const BootstrapData = struct {
    func_ptr: usize,
    coro_ptr: usize,
};

const CoroutineState = enum {
    ready,
    running,
    suspended,
    dead,
};

const Coroutine = struct {
    state: CoroutineState,
    registers: SavedRegs,
    stack: []u8,
};

var main_context: SavedRegs = undefined;
var current_coro: ?*Coroutine = null;

fn getCurrentStackPointer() usize {
    return asm volatile ("movq %%rsp, %[result]" : [result] "=r" (-> usize));
}

// This is where new coroutines start execution
fn coroutineEntry() callconv(.C) noreturn {
    // Get bootstrap data from stack (8 bytes above current rsp)
    const rsp = getCurrentStackPointer();
    const bootstrap_ptr: *BootstrapData = @ptrFromInt(rsp + 8);
    const bootstrap = bootstrap_ptr.*;

    const func_ptr: *const fn() void = @ptrFromInt(bootstrap.func_ptr);
    const coro: *Coroutine = @ptrFromInt(bootstrap.coro_ptr);

    // Mark coroutine as running
    coro.state = .running;
    current_coro = coro;

    // Call the actual user function
    func_ptr();

    // When function returns, mark coroutine as dead
    coro.state = .dead;

    // Switch back to main
    switch_to_thread(&coro.registers, &main_context);

    unreachable;
}

fn switch_to_thread(old_regs: *SavedRegs, new_regs: *SavedRegs) void {
    asm volatile (
        \\# Save callee-saved registers
        \\movq %%rbx, 0(%[old])
        \\movq %%rbp, 8(%[old])
        \\movq %%rsp, 16(%[old])
        \\movq %%r12, 24(%[old])
        \\movq %%r13, 32(%[old])
        \\movq %%r14, 40(%[old])
        \\movq %%r15, 48(%[old])
        \\
        \\# Restore callee-saved registers
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

fn yield() void {
    if (current_coro) |coro| {
        coro.state = .suspended;
        switch_to_thread(&coro.registers, &main_context);
    }
}

fn spawn(allocator: std.mem.Allocator, func: *const fn() void) !*Coroutine {
    const stack = try allocator.alloc(u8, 4096);
    const coro = try allocator.create(Coroutine);

    coro.* = Coroutine{
        .state = .ready,
        .registers = std.mem.zeroes(SavedRegs),
        .stack = stack,
    };

    // Set up stack with bootstrap data at the top
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    const bootstrap_addr = (stack_top - @sizeOf(BootstrapData)) & ~@as(usize, 15);

    const bootstrap: *BootstrapData = @ptrFromInt(bootstrap_addr);
    bootstrap.* = BootstrapData{
        .func_ptr = @intFromPtr(func),
        .coro_ptr = @intFromPtr(coro),
    };

    // Stack layout: [return_addr] <- rsp points here
    //               [bootstrap_data] <- 8 bytes above rsp
    const return_addr = bootstrap_addr - 8;
    @as(*usize, @ptrFromInt(return_addr)).* = @intFromPtr(&coroutineEntry);
    coro.registers.rsp = return_addr;

    return coro;
}

// Test functions
fn task1() void {
    std.debug.print("Task 1 start\n", .{});
    yield();
    std.debug.print("Task 1 middle\n", .{});
    yield();
    std.debug.print("Task 1 end\n", .{});
}

fn task2() void {
    std.debug.print("Task 2 start\n", .{});
    yield();
    std.debug.print("Task 2 end\n", .{});
}

pub fn main() !void {
    std.debug.print("Coroutine demo with proper entry point\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const coro1 = try spawn(allocator, task1);
    defer allocator.destroy(coro1);
    defer allocator.free(coro1.stack);

    const coro2 = try spawn(allocator, task2);
    defer allocator.destroy(coro2);
    defer allocator.free(coro2.stack);

    // Simple round-robin execution
    const coros = [_]*Coroutine{ coro1, coro2 };

    while (true) {
        var any_running = false;

        for (coros) |coro| {
            if (coro.state == .ready or coro.state == .suspended) {
                std.debug.print("Switching to coroutine\n", .{});
                switch_to_thread(&main_context, &coro.registers);
                any_running = true;
            }
        }

        if (!any_running) break;
    }

    std.debug.print("All coroutines finished\n", .{});
}