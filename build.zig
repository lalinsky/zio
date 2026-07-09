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

    const ResolveBeneathMode = enum { strict, best_effort };
    const resolve_beneath_mode = b.option(
        ResolveBeneathMode,
        "resolve-beneath-mode",
        "How to handle resolve_beneath on platforms without kernel support: strict (error.Unsupported) or best_effort (log warning, continue)",
    ) orelse .strict;

    const no_hacks = b.option(bool, "no-hacks", "Avoid unsafe performance tricks (bool smuggling, etc.)") orelse false;

    const task_migration = b.option(bool, "task-migration", "Compile in task migration / work-stealing support. When false, tasks are pinned to their home executor and the scheduler can drop the machinery it needs (default true)") orelse true;

    // Create options for backend selection
    var options = b.addOptions();
    options.addOption(?[]const u8, "backend", backend);
    options.addOption(ResolveBeneathMode, "resolve_beneath_mode", resolve_beneath_mode);
    options.addOption(bool, "no_hacks", no_hacks);
    options.addOption(bool, "task_migration", task_migration);

    const zio = b.addModule("zio", .{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .freestanding,
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
        .{ .name = "hello-world", .file = "examples/hello_world.zig" },
        .{ .name = "sleep", .file = "examples/sleep.zig" },
        .{ .name = "tcp-echo-server", .file = "examples/tcp_echo_server.zig" },
        .{ .name = "tcp-echo-server-stdio", .file = "examples/tcp_echo_server_stdio.zig" },
        .{ .name = "tcp-client", .file = "examples/tcp_client.zig" },
        .{ .name = "http-server", .file = "examples/http_server.zig" },
        .{ .name = "http-client", .file = "examples/http_client.zig" },
        .{ .name = "mutex-demo", .file = "examples/mutex_demo.zig" },
        .{ .name = "producer-consumer", .file = "examples/producer_consumer.zig" },
        .{ .name = "parallel-grep", .file = "examples/parallel_grep.zig" },
        .{ .name = "ntp-client", .file = "examples/ntp_client.zig" },
        .{ .name = "signal-demo", .file = "examples/signal_demo.zig" },
        .{ .name = "udp-echo-server", .file = "examples/udp_echo_server.zig" },
        .{ .name = "ping", .file = "examples/ping.zig" },
        .{ .name = "coro-demo", .file = "examples/coro_demo.zig" },
        .{ .name = "ev-demo", .file = "examples/ev_demo.zig" },
    };

    // Create examples step. -Dexample=<name> limits it to a single example
    // (e.g. `zig build examples -Dexample=http-bench`).
    const examples_step = b.step("examples", "Build examples");
    const only_example = b.option([]const u8, "example", "Build/run only this example by name");

    // Create example executables
    for (examples) |example| {
        if (only_example) |name| if (!std.mem.eql(u8, name, example.name)) continue;
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

    // Single-threaded build of hello-world to verify single-threaded support
    if (only_example == null) {
        const hello_world_st = b.addExecutable(.{
            .name = "hello-world-single-threaded",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/hello_world.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
            }),
        });
        hello_world_st.root_module.addImport("zio", zio);
        examples_step.dependOn(&b.addInstallArtifact(hello_world_st, .{}).step);
    }

    // Tests
    const emit_test_bin = b.option(bool, "emit-test-bin", "Build test binary without running") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Filter for test names");

    const lib_unit_tests = b.addTest(.{
        .root_module = zio,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
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
