const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get libxev dependency
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    // Create the zio library
    const zio_lib = b.addLibrary(.{
        .name = "zio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zio.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    zio_lib.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(zio_lib);

    // Create zio module for imports
    const zio = b.addModule("zio", .{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
    });
    zio.addImport("xev", xev.module("xev"));

    // Examples configuration
    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "sleep", .file = "examples/sleep.zig" },
        .{ .name = "tcp-echo-server", .file = "examples/tcp_echo_server.zig" },
        .{ .name = "tcp-client", .file = "examples/tcp_client.zig" },
        .{ .name = "tls-demo", .file = "examples/tls_demo.zig" },
        .{ .name = "mutex-demo", .file = "examples/mutex_demo.zig" },
        .{ .name = "producer-consumer", .file = "examples/producer_consumer.zig" },
        .{ .name = "mini-redis", .file = "examples/mini_redis.zig" },
        //.{ .name = "udp-echo", .file = "examples/udp_echo.zig" },
    };

    // Create executables
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

        b.installArtifact(exe);
    }

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zio.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    lib_unit_tests.root_module.addImport("xev", xev.module("xev"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Build tests without running them (useful for cross-compilation)
    const build_tests_step = b.step("build-tests", "Build unit tests without running");
    build_tests_step.dependOn(&b.addInstallArtifact(lib_unit_tests, .{}).step);
}
