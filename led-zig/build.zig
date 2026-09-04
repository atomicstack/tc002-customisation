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

    const frame_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frame.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_frame_tests = b.addRunArtifact(frame_tests);
    const test_step = b.step("test", "run frame tests");
    test_step.dependOn(&run_frame_tests.step);
}
