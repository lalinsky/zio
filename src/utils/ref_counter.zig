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

/// Thread-safe atomic reference counter for shared ownership.
///
/// A reference counter tracks the number of references to a shared resource.
/// When the count reaches zero, the resource can be safely deallocated.
///
/// This is thread-safe and can be used across multiple OS threads. It uses
/// atomic operations with carefully chosen memory orderings:
/// - Monotonic ordering for increments (weakest safe ordering)
/// - Release ordering for decrements (ensures visibility of operations)
/// - Acquire ordering when reaching zero (synchronizes with all releases)
///
/// This primitive is included to help with shared memory management in server
/// applications, particularly when sharing resources across multiple connections
/// or threads.
///
/// Unlike other sync primitives in this module, RefCounter is thread-safe across
/// OS threads, not just within a single zio Runtime.
///
/// ## Example
///
/// ```zig
/// const MyResource = struct {
///     ref_count: RefCounter(u32),
///     data: []u8,
///
///     fn acquire(self: *MyResource) void {
///         self.ref_count.incr();
///     }
///
///     fn release(self: *MyResource, allocator: Allocator) void {
///         if (self.ref_count.decr()) {
///             allocator.free(self.data);
///             allocator.destroy(self);
///         }
///     }
/// };
///
/// var resource = try allocator.create(MyResource);
/// resource.* = .{
///     .ref_count = RefCounter(u32).init(),
///     .data = try allocator.alloc(u8, 1024),
/// };
/// ```
pub fn RefCounter(comptime T: type) type {
    return struct {
        refs: std.atomic.Value(T),

        pub const Self = @This();

        /// Initializes a reference counter with an initial count of 1.
        pub fn init() Self {
            return .{
                .refs = std.atomic.Value(T).init(1),
            };
        }

        /// Increments the reference count.
        ///
        /// Call this when creating a new reference to the shared resource.
        /// Uses monotonic ordering since new references can only be created
        /// from existing ones, which already provide necessary synchronization.
        pub fn incr(self: *Self) void {
            const prev_ref_count = self.refs.fetchAdd(1, .monotonic);
            std.debug.assert(prev_ref_count > 0);
        }

        /// Decrements the reference count.
        ///
        /// Call this when releasing a reference to the shared resource.
        /// Returns `true` if the count reached zero, indicating the resource
        /// should be deallocated. Returns `false` if other references still exist.
        ///
        /// Uses release ordering to ensure all previous memory operations are
        /// visible to the thread that deallocates the resource.
        pub fn decr(self: *Self) bool {
            const prev_ref_count = self.refs.fetchSub(1, .release);
            std.debug.assert(prev_ref_count > 0);
            if (prev_ref_count == 1) {
                // Use acquire load as substitute for fence (Zig 0.14 doesn't have @fence)
                // This synchronizes with all release operations from other threads
                _ = self.refs.load(.acquire);
                return true;
            }
            return false;
        }

        /// Returns the current reference count.
        ///
        /// This is intended for debugging and testing only. The value may be
        /// stale immediately after reading due to concurrent modifications.
        pub fn count(self: *const Self) T {
            return self.refs.load(.monotonic);
        }
    };
}

// Test the RefCounter implementation
test "RefCounter basic operations" {
    var counter = RefCounter(u32).init();

    // Initial count should be 1
    try std.testing.expect(counter.count() == 1);

    // Increment
    counter.incr();
    try std.testing.expect(counter.count() == 2);

    // Decrement (not yet zero)
    try std.testing.expect(!counter.decr());
    try std.testing.expect(counter.count() == 1);

    // Final decrement (reaches zero)
    try std.testing.expect(counter.decr());
    try std.testing.expect(counter.count() == 0);
}

test "RefCounter thread safety simulation" {
    var counter = RefCounter(u32).init();

    // Simulate multiple increments
    counter.incr();
    counter.incr();
    counter.incr();
    try std.testing.expect(counter.count() == 4);

    // Simulate multiple decrements
    try std.testing.expect(!counter.decr()); // 3
    try std.testing.expect(!counter.decr()); // 2
    try std.testing.expect(!counter.decr()); // 1
    try std.testing.expect(counter.decr()); // 0 - should return true
}
