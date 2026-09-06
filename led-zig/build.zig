const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
        .os_tag = .linux,
        .abi = .musleabihf,
    });

    const exe = b.addExecutable(.{
        .name = "popsquares",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .strip = true,
        }),
        .linkage = .static,
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "run host tests");
    for ([_][]const u8{
        "src/frame.zig",
        "src/popsquares.zig",
        "src/cli.zig",
        "src/device.zig",
    }) |test_path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_path),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
