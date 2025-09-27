const std = @import("std");
const context = @import("context.zig");
const VirtualThread = context.VirtualThread;

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    ready_queue: std.ArrayList(*VirtualThread),
    current_thread: ?*VirtualThread,
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .allocator = allocator,
            .ready_queue = std.ArrayList(*VirtualThread).init(allocator),
            .current_thread = null,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.ready_queue.items) |thread| {
            thread.deinit(self.allocator);
            self.allocator.destroy(thread);
        }
        self.ready_queue.deinit();
    }

    pub fn spawn(self: *Scheduler, func: *const fn () void) !void {
        const thread = try self.allocator.create(VirtualThread);
        thread.* = try VirtualThread.init(self.allocator, self.next_id, func);
        self.next_id += 1;

        try self.ready_queue.append(thread);
    }

    pub fn yield(self: *Scheduler) void {
        if (self.current_thread) |current| {
            if (current.state == .running) {
                current.state = .ready;
                // Put current thread back in queue
                self.ready_queue.append(current) catch return;
            }
        }

        self.schedule();
    }

    pub fn schedule(self: *Scheduler) void {
        if (self.ready_queue.items.len == 0) {
            return;
        }

        const next_thread = self.ready_queue.orderedRemove(0);

        if (self.current_thread) |current| {
            context.switchContext(current, next_thread);
        } else {
            // First thread - set up dummy context and switch
            var dummy_regs = std.mem.zeroes(context.SavedRegs);
            next_thread.state = .running;
            context.switch_to_thread(&dummy_regs, &next_thread.registers);
        }

        self.current_thread = next_thread;
    }

    pub fn run(self: *Scheduler) void {
        while (self.ready_queue.items.len > 0 or self.current_thread != null) {
            self.schedule();

            // Check if current thread is done
            if (self.current_thread) |current| {
                if (current.state == .dead) {
                    current.deinit(self.allocator);
                    self.allocator.destroy(current);
                    self.current_thread = null;
                }
            }
        }
    }
};

var global_scheduler: ?Scheduler = null;

pub fn getScheduler() *Scheduler {
    return &global_scheduler.?;
}

pub fn initScheduler(allocator: std.mem.Allocator) void {
    global_scheduler = Scheduler.init(allocator);
}

pub fn deinitScheduler() void {
    if (global_scheduler) |*sched| {
        sched.deinit();
        global_scheduler = null;
    }
}
