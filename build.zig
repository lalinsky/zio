// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(
        []const u8,
        "backend",
        "Override the default event loop backend (io_uring, epoll, kqueue, iocp, poll)",
    );

    // Create options for backend selection
    var options = b.addOptions();
    options.addOption(?[]const u8, "backend", backend);

    const zio = b.addModule("zio", .{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zio.addOptions("zio_options", options);

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
        .{ .name = "tcp-echo-server-plain", .file = "examples/tcp_echo_server_plain.zig" },
        .{ .name = "tcp-client", .file = "examples/tcp_client.zig" },
        .{ .name = "http-server", .file = "examples/http_server.zig" },
        .{ .name = "tls-demo", .file = "examples/tls_demo.zig" },
        .{ .name = "mutex-demo", .file = "examples/mutex_demo.zig" },
        .{ .name = "producer-consumer", .file = "examples/producer_consumer.zig" },
        .{ .name = "signal-demo", .file = "examples/signal_demo.zig" },
        .{ .name = "udp-echo-server", .file = "examples/udp_echo_server.zig" },
        .{ .name = "coro-demo", .file = "examples/coro_demo.zig" },
        .{ .name = "ev-demo", .file = "examples/ev_demo.zig" },
    };

    // Benchmarks configuration
    const benchmarks = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "ping_pong_benchmark", .file = "benchmarks/ping_pong.zig" },
        .{ .name = "echo_server_benchmark", .file = "benchmarks/echo_server.zig" },
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
    const emit_test_bin = b.option(bool, "emit-test-bin", "Build test binary without running") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Filter for test names");

    const lib_unit_tests = b.addTest(.{
        .root_module = zio,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const test_step = b.step("test", "Run unit tests");
    if (emit_test_bin) {
        test_step.dependOn(&b.addInstallArtifact(lib_unit_tests, .{}).step);
    } else {
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        run_lib_unit_tests.has_side_effects = true;
        test_step.dependOn(&run_lib_unit_tests.step);
    }
}
