// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const install_tests = b.option(
        bool,
        "install-tests",
        "Install tests binary",
    ) orelse false;

    const mod = b.addModule("coro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{
            .path = b.path("src/test/runner.zig"),
            .mode = .simple,
        },
    });

    const test_step = b.step("test", "Run tests");
    const run_tests_artifact = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests_artifact.step);

    if (install_tests) {
        const install_tests_artifact = b.addInstallArtifact(tests, .{});
        b.getInstallStep().dependOn(&install_tests_artifact.step);
    }
}
