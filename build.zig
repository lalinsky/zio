const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get libxev dependency
    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    // Create the zio library
    const zio_lib = b.addStaticLibrary(.{
        .name = "zio",
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
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
    const examples = [_]struct { name: []const u8, file: []const u8, step: []const u8, desc: []const u8 }{
        .{ .name = "zio-example", .file = "examples/sleep_demo.zig", .step = "run", .desc = "Run the sleep demo" },
        .{ .name = "tcp-echo-server", .file = "examples/tcp_echo_server.zig", .step = "run-server", .desc = "Run the TCP echo server" },
        .{ .name = "tcp-client", .file = "examples/tcp_client.zig", .step = "run-client", .desc = "Run the TCP client demo" },
        .{ .name = "udp-echo", .file = "examples/udp_echo.zig", .step = "run-udp", .desc = "Run the UDP echo demo" },
    };

    // Create executables and run steps
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.file),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zio", zio);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step(example.step, example.desc);
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("xev", xev.module("xev"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
