// SPDX-FileCopyrightText: 2024 The Zig Contributors
// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// Managed memory pool that stores the allocator internally.
// Based on std.heap.memory_pool from Zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub fn MemoryPool(comptime Item: type) type {
    return MemoryPoolAligned(Item, .of(Item));
}

pub fn MemoryPoolAligned(comptime Item: type, comptime alignment: Alignment) type {
    return struct {
        const Pool = @This();

        allocator: Allocator,
        arena_state: std.heap.ArenaAllocator.State = .{},
        free_list: std.SinglyLinkedList = .{},

        pub const item_size = @max(@sizeOf(Node), @sizeOf(Item));
        pub const item_alignment: Alignment = .max(alignment, .of(Node));

        const Node = std.SinglyLinkedList.Node;
        pub const ItemPtr = *align(item_alignment.toByteUnits()) Item;

        pub fn init(allocator: Allocator) Pool {
            return .{ .allocator = allocator };
        }

        pub fn deinit(pool: *Pool) void {
            pool.arena_state.promote(pool.allocator).deinit();
            pool.* = undefined;
        }

        pub fn create(pool: *Pool) Allocator.Error!ItemPtr {
            const ptr: ItemPtr = if (pool.free_list.popFirst()) |node|
                @ptrCast(@alignCast(node))
            else
                @ptrCast(try pool.allocNew());

            ptr.* = undefined;
            return ptr;
        }

        pub fn destroy(pool: *Pool, ptr: ItemPtr) void {
            ptr.* = undefined;
            pool.free_list.prepend(@ptrCast(ptr));
        }

        fn allocNew(pool: *Pool) Allocator.Error!*align(item_alignment.toByteUnits()) [item_size]u8 {
            var arena = pool.arena_state.promote(pool.allocator);
            defer pool.arena_state = arena.state;
            const memory = try arena.allocator().alignedAlloc(u8, item_alignment, item_size);
            return memory[0..item_size];
        }
    };
}

test "basic" {
    var pool = MemoryPool(u32).init(std.testing.allocator);
    defer pool.deinit();

    const p1 = try pool.create();
    const p2 = try pool.create();
    const p3 = try pool.create();

    try std.testing.expect(p1 != p2);
    try std.testing.expect(p1 != p3);
    try std.testing.expect(p2 != p3);

    pool.destroy(p2);
    const p4 = try pool.create();

    try std.testing.expect(p2 == p4);
}

test "aligned" {
    const Foo = struct {
        data: u64 align(16),
    };

    var pool = MemoryPoolAligned(Foo, .@"16").init(std.testing.allocator);
    defer pool.deinit();

    const foo: *align(16) Foo = try pool.create();
    pool.destroy(foo);
}
