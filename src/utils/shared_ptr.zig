// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

// Copyright 2025 Lukas Lalinsky
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RefCounter = @import("ref_counter.zig").RefCounter;

/// Thread-safe shared pointer with automatic reference counting.
///
/// SharedPtr provides shared ownership of a dynamically allocated value.
/// Multiple SharedPtr instances can point to the same data, and the data
/// is automatically freed when the last reference is released.
///
/// This is similar to C++'s std::shared_ptr or Rust's Arc<T>.
///
/// ## Thread Safety
///
/// SharedPtr is thread-safe across OS threads, not just within a single zio
/// Runtime. The reference counting uses atomic operations to ensure safe
/// concurrent access.
///
/// ## Usage
///
/// The SharedPtr exposes the `value` field directly for ergonomic access:
/// ```zig
/// var ptr = try SharedPtr(u32, void).init(allocator, 42);
/// defer ptr.deinit(allocator);
///
/// // Direct access to the value
/// ptr.value.* = 100;
/// std.debug.print("{}\n", .{ptr.value.*});
/// ```
///
/// ## Custom Cleanup with Context
///
/// Use the Context parameter to provide custom cleanup logic for complex types:
///
/// ```zig
/// const Buffer = struct {
///     data: []u8,
/// };
///
/// const BufferContext = struct {
///     pub fn deinit(buffer: *Buffer, allocator: Allocator) void {
///         allocator.free(buffer.data);
///     }
/// };
///
/// var buf_ptr = try SharedPtr(Buffer, BufferContext).init(allocator, .{
///     .data = try allocator.alloc(u8, 1024),
/// });
/// defer buf_ptr.deinit(allocator);
/// ```
///
/// For simple types that don't need cleanup, use void:
/// ```zig
/// var ptr = try SharedPtr(u32, void).init(allocator, 42);
/// ```
///
/// ## Example: Shared Connection Pool
///
/// ```zig
/// const Connection = struct {
///     socket: Socket,
///
///     fn close(self: *Connection) void {
///         self.socket.close();
///     }
/// };
///
/// const ConnectionContext = struct {
///     pub fn deinit(conn: *Connection, allocator: Allocator) void {
///         _ = allocator;
///         conn.close();
///     }
/// };
///
/// const SharedConnection = SharedPtr(Connection, ConnectionContext);
///
/// // Create connection
/// var conn1 = try SharedConnection.init(allocator, .{ .socket = socket });
/// defer conn1.deinit(allocator);
///
/// // Share with another thread/task
/// var conn2 = conn1.clone();
/// defer conn2.deinit(allocator);
///
/// // Both can use the connection
/// try conn1.value.socket.write("Hello");
/// ```
///
/// The Context parameter allows customization of cleanup behavior. If Context
/// has a `deinit` function, it will be called when the last reference is released.
/// Use `void` for no custom cleanup.
///
/// Context.deinit signature: fn(data: *T, allocator: Allocator) void
pub fn SharedPtr(comptime T: type, comptime Context: type) type {
    const has_deinit = if (Context == void) false else @hasDecl(Context, "deinit");

    return struct {
        /// Direct access to the shared value.
        ///
        /// This pointer remains valid as long as at least one SharedPtr
        /// instance pointing to this data exists.
        value: *T,

        const Self = @This();

        const Inner = struct {
            ref_count: RefCounter(u32),
            data: T,
        };

        /// Creates a new SharedPtr with the given value.
        ///
        /// The allocator is used to allocate memory for both the reference
        /// counter and the data. You must pass the same allocator to deinit().
        pub fn init(allocator: Allocator, data: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .ref_count = RefCounter(u32).init(),
                .data = data,
            };
            return .{ .value = &inner.data };
        }

        fn getInner(self: *const Self) *Inner {
            return @fieldParentPtr("data", self.value);
        }

        /// Creates a new reference to the same data.
        ///
        /// The returned SharedPtr points to the same data and increments
        /// the reference count. Both the original and cloned pointers
        /// must be independently deinitialized.
        pub fn clone(self: *const Self) Self {
            const inner = self.getInner();
            inner.ref_count.incr();
            return .{ .value = self.value };
        }

        /// Releases this reference to the shared data.
        ///
        /// If this is the last reference, the Context's deinit function
        /// (if present) is called, and then the memory is freed using
        /// the provided allocator.
        ///
        /// The allocator must be the same one used in init().
        pub fn deinit(self: *Self, allocator: Allocator) void {
            const inner = self.getInner();
            if (inner.ref_count.decr()) {
                // Call context deinit if provided
                if (has_deinit) {
                    Context.deinit(&inner.data, allocator);
                }

                allocator.destroy(inner);
            }
        }

        /// Returns the current reference count.
        ///
        /// This is intended for debugging and testing only. The value may be
        /// stale immediately after reading due to concurrent modifications.
        pub fn getRefCount(self: *const Self) u32 {
            const inner = self.getInner();
            return inner.ref_count.count();
        }
    };
}

// Tests

test "SharedPtr basic operations" {
    const allocator = std.testing.allocator;

    var ptr1 = try SharedPtr(u32, void).init(allocator, 42);
    defer ptr1.deinit(allocator);

    // Initial count should be 1
    try std.testing.expectEqual(@as(u32, 1), ptr1.getRefCount());

    // Direct access to value
    try std.testing.expectEqual(@as(u32, 42), ptr1.value.*);

    // Modify value
    ptr1.value.* = 100;
    try std.testing.expectEqual(@as(u32, 100), ptr1.value.*);

    // Clone increases ref count
    var ptr2 = ptr1.clone();
    defer ptr2.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), ptr1.getRefCount());
    try std.testing.expectEqual(@as(u32, 2), ptr2.getRefCount());

    // Both point to the same data
    try std.testing.expectEqual(@as(u32, 100), ptr2.value.*);
    ptr2.value.* = 200;
    try std.testing.expectEqual(@as(u32, 200), ptr1.value.*);
}

test "SharedPtr with custom context" {
    const allocator = std.testing.allocator;

    const Buffer = struct {
        data: []u8,
        freed: *bool,
    };

    const BufferContext = struct {
        pub fn deinit(buffer: *Buffer, alloc: Allocator) void {
            alloc.free(buffer.data);
            buffer.freed.* = true;
        }
    };

    var freed = false;
    var ptr1 = try SharedPtr(Buffer, BufferContext).init(allocator, .{
        .data = try allocator.alloc(u8, 16),
        .freed = &freed,
    });

    // Copy some data
    @memcpy(ptr1.value.data, "Hello, World!!!!");

    // Clone it
    var ptr2 = ptr1.clone();
    try std.testing.expectEqual(@as(u32, 2), ptr1.getRefCount());

    // Both can access the data
    try std.testing.expectEqualStrings("Hello, World!!!!", ptr2.value.data);

    // First deinit should not free
    ptr1.deinit(allocator);
    try std.testing.expect(!freed);

    // Second deinit should free
    ptr2.deinit(allocator);
    try std.testing.expect(freed);
}

test "SharedPtr multiple clones" {
    const allocator = std.testing.allocator;

    var ptr1 = try SharedPtr(u32, void).init(allocator, 1);
    defer ptr1.deinit(allocator);

    var ptr2 = ptr1.clone();
    defer ptr2.deinit(allocator);

    var ptr3 = ptr1.clone();
    defer ptr3.deinit(allocator);

    var ptr4 = ptr2.clone();
    defer ptr4.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), ptr1.getRefCount());

    // All point to the same value
    ptr1.value.* = 42;
    try std.testing.expectEqual(@as(u32, 42), ptr2.value.*);
    try std.testing.expectEqual(@as(u32, 42), ptr3.value.*);
    try std.testing.expectEqual(@as(u32, 42), ptr4.value.*);
}

test "SharedPtr with struct" {
    const allocator = std.testing.allocator;

    const Point = struct {
        x: i32,
        y: i32,
    };

    var ptr = try SharedPtr(Point, void).init(allocator, .{ .x = 10, .y = 20 });
    defer ptr.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 10), ptr.value.x);
    try std.testing.expectEqual(@as(i32, 20), ptr.value.y);

    ptr.value.x = 30;
    try std.testing.expectEqual(@as(i32, 30), ptr.value.x);
}
