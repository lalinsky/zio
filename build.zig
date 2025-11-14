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

    // Standalone test programs
    const stack_overflow_exe = b.addExecutable(.{
        .name = "test_stack_overflow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/stack_overflow.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stack_overflow_exe.root_module.addImport("coro", mod);

    const install_stack_overflow = b.addInstallArtifact(stack_overflow_exe, .{});

    const segfault_exe = b.addExecutable(.{
        .name = "test_segfault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/segfault.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    segfault_exe.root_module.addImport("coro", mod);

    const install_segfault = b.addInstallArtifact(segfault_exe, .{});

    const install_signal_tests_step = b.step("install-signal-tests", "Install standalone signal test programs");
    install_signal_tests_step.dependOn(&install_stack_overflow.step);
    install_signal_tests_step.dependOn(&install_segfault.step);
}
