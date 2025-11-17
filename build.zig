// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(
        []const u8,
        "backend",
        "Override the default aio backend (io_uring, epoll, kqueue, iocp, wasi_poll)",
    );

    const aio = b.dependency("aio", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
    });

    const coro = b.dependency("coro", .{
        .target = target,
        .optimize = optimize,
    });

    const zio = b.addModule("zio", .{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zio.addImport("aio", aio.module("aio"));
    zio.addImport("coro", coro.module("coro"));

    const zio_lib = b.addLibrary(.{
        .name = "zio",
        .root_module = zio,
        .linkage = .static,
    });
    b.installArtifact(zio_lib);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = zio_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // Examples configuration
    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "sleep", .file = "examples/sleep.zig" },
        .{ .name = "tcp-echo-server", .file = "examples/tcp_echo_server.zig" },
        .{ .name = "tcp-client", .file = "examples/tcp_client.zig" },
        .{ .name = "http-server", .file = "examples/http_server.zig" },
        //.{ .name = "tls-demo", .file = "examples/tls_demo.zig" },
        .{ .name = "mutex-demo", .file = "examples/mutex_demo.zig" },
        .{ .name = "producer-consumer", .file = "examples/producer_consumer.zig" },
        .{ .name = "signal-demo", .file = "examples/signal_demo.zig" },
        //.{ .name = "udp-echo", .file = "examples/udp_echo.zig" },
    };

    // Benchmarks configuration
    const benchmarks = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "ping-pong", .file = "benchmarks/ping_pong.zig" },
        .{ .name = "echo-server", .file = "benchmarks/echo_server.zig" },
        .{ .name = "concurrent-queue", .file = "benchmarks/concurrent_queue_bench.zig" },
    };

    // Create examples step
    const examples_step = b.step("examples", "Build examples");

    // Create example executables
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("zio", zio);

        // Link libc for examples that need mprotect/signals
        if (std.mem.eql(u8, example.name, "stack-overflow-demo")) {
            exe.linkLibC();
        }

        const install_exe = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install_exe.step);
    }

    // Create benchmarks step
    const benchmarks_step = b.step("benchmarks", "Build benchmarks");

    // Create benchmark executables
    for (benchmarks) |benchmark| {
        const exe = b.addExecutable(.{
            .name = benchmark.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(benchmark.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("zio", zio);

        const install_exe = b.addInstallArtifact(exe, .{});
        benchmarks_step.dependOn(&install_exe.step);
    }

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = zio,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });

    // Optional: Enable sanitizers for debugging
    const use_sanitizer = b.option(bool, "sanitize", "Enable address sanitizer") orelse false;
    if (use_sanitizer) {
        lib_unit_tests.root_module.sanitize_c = true;
    }

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Build tests without running them (useful for cross-compilation)
    const build_tests_step = b.step("build-tests", "Build unit tests without running");
    build_tests_step.dependOn(&b.addInstallArtifact(lib_unit_tests, .{}).step);
}
