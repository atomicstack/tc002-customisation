const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0")) @panic("this project pins zig 0.16.0");

    const supervisor_path = b.option([]const u8, "supervisor_path", "path the bootstrap execs") orelse "/tmp/tc002/tc002-supervisor";
    const options = b.addOptions();
    options.addOption([]const u8, "supervisor_path", supervisor_path);

    const device = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
        .os_tag = .linux,
        .abi = .musleabihf,
    });
    // device binaries default to ReleaseSafe; -Doptimize=ReleaseSmall/ReleaseFast for size/speed comparisons
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimize mode for the device binaries") orelse .ReleaseSafe;

    inline for (.{ .{ "tc002d", "src/tc002d_main.zig" }, .{ "tc002-supervisor", "src/supervisor_main.zig" } }) |spec| {
        const exe = b.addExecutable(.{
            .name = spec[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec[1]),
                .target = device,
                .optimize = optimize,
                .link_libc = false,
                .strip = true,
                .single_threaded = true,
            }),
            .linkage = .static,
        });
        exe.root_module.addOptions("build_options", options);
        b.installArtifact(exe);
    }

    const bootstrap = b.addLibrary(.{
        .name = "tc002-bootstrap",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bootstrap_main.zig"),
            .target = device,
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .strip = true,
            .single_threaded = true,
            .pic = true,
        }),
    });
    bootstrap.root_module.addOptions("build_options", options);
    b.installArtifact(bootstrap);

    // host tests of every pure module
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const test_step = b.step("test", "run host unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // elf check of the device bootstrap (host tool reads the built .so)
    const elfcheck = b.addExecutable(.{ .name = "elfcheck", .root_module = b.createModule(.{
        .root_source_file = b.path("src/elfcheck_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_elfcheck = b.addRunArtifact(elfcheck);
    run_elfcheck.addArtifactArg(bootstrap);
    const check_step = b.step("check", "verify the bootstrap elf: arm et_dyn, no dt_needed, has init_array");
    check_step.dependOn(&run_elfcheck.step);
}
