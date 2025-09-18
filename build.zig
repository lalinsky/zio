const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the zio library
    const zio_lib = b.addStaticLibrary(.{
        .name = "zio",
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libuv
    zio_lib.linkSystemLibrary("uv");
    zio_lib.linkLibC();

    b.installArtifact(zio_lib);

    // Create zio module for imports
    const zio = b.addModule("zio", .{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create example executable
    const example = b.addExecutable(.{
        .name = "zio-example",
        .root_source_file = b.path("examples/sleep_demo.zig"),
        .target = target,
        .optimize = optimize,
    });

    example.root_module.addImport("zio", zio);
    example.linkSystemLibrary("uv");
    example.linkLibC();

    b.installArtifact(example);

    // Create run step for example
    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_example.addArgs(args);
    }

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_example.step);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zio.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib_unit_tests.linkSystemLibrary("uv");
    lib_unit_tests.linkLibC();

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}