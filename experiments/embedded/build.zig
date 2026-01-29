const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const zio_dep = b.dependency("zio", .{});
    const zio_module = zio_dep.module("zio");

    const firmware = mb.add_firmware(.{
        .name = "blinky",
        .target = mb.ports.rp2xxx.boards.raspberrypi.pico, // Regular Pico, not Pico W
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "zio", .module = zio_module },
        },
    });

    // We call this twice to demonstrate that the default binary output for
    // RP2040 is UF2, but we can also output other formats easily
    mb.install_firmware(firmware, .{ });
    mb.install_firmware(firmware, .{ .format = .elf });
}
