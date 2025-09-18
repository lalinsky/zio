const std = @import("std");

pub const VirtualThread = struct {
    id: u32,
    stack: []u8,
    stack_ptr: usize,
    state: State,
    registers: SavedRegs,
    func: ?*const fn () void,

    pub const State = enum {
        ready,
        running,
        suspended,
        dead,
    };

    pub fn init(allocator: std.mem.Allocator, id: u32, func: *const fn () void) !VirtualThread {
        const stack = try allocator.alloc(u8, 8 * 1024); // 8KB stack
        const stack_top = @intFromPtr(stack.ptr) + stack.len;

        // Align stack to 16 bytes
        const aligned_stack = (stack_top) & ~@as(usize, 15);

        // Set up stack with thread_wrapper as return address, then the actual function
        const stack_ptr = aligned_stack - 16;
        @as(*usize, @ptrFromInt(stack_ptr)).* = @intFromPtr(&thread_wrapper);
        @as(*usize, @ptrFromInt(stack_ptr + 8)).* = @intFromPtr(func);

        var registers = std.mem.zeroes(SavedRegs);
        registers.rsp = stack_ptr;

        return VirtualThread{
            .id = id,
            .stack = stack,
            .stack_ptr = stack_ptr,
            .state = .ready,
            .registers = registers,
            .func = null,
        };
    }

    pub fn deinit(self: *VirtualThread, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }
};

// x86_64 callee-saved registers only
pub const SavedRegs = struct {
    rbx: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

fn thread_wrapper() callconv(.C) noreturn {
    // The actual function pointer is on the stack at rsp+8
    const func_ptr: *const fn() void = @ptrFromInt(asm volatile ("movq 8(%%rsp), %[result]" : [result] "=r" (-> usize)));
    func_ptr();

    // Thread finished - mark as dead and yield forever
    // In a real implementation, we'd notify the scheduler
    while (true) {
        asm volatile ("hlt");
    }
}

// Assembly context switching functions using inline assembly
pub fn switch_to_thread(old_regs: *SavedRegs, new_regs: *SavedRegs) void {
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


pub fn switchContext(from: *VirtualThread, to: *VirtualThread) void {
    from.state = .suspended;
    to.state = .running;

    // Always use register switching - for new threads, we'll set up the registers properly
    switch_to_thread(&from.registers, &to.registers);
}