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
    const strip = b.option(bool, "strip", "strip the device binaries (false keeps symbols for memory audits)") orelse true;

    inline for (.{ .{ "tc002d", "src/tc002d_main.zig" }, .{ "tc002-supervisor", "src/supervisor_main.zig" }, .{ "tc002-netd", "src/netd_main.zig" }, .{ "tc002-ntfy", "src/ntfy_main.zig" }, .{ "tc002-memdump", "src/memdump_main.zig" } }) |spec| {
        const exe = b.addExecutable(.{
            .name = spec[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec[1]),
                .target = device,
                .optimize = optimize,
                .link_libc = false,
                .strip = strip,
                .single_threaded = true,
            }),
            .linkage = .static,
        });
        exe.root_module.addOptions("build_options", options);
        b.installArtifact(exe);
    }

    // a diagnostic rather than part of the runtime: built on request, not installed
    const ipcprobe = b.addExecutable(.{
        .name = "tc002-ipcprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipcprobe_main.zig"),
            .target = device,
            .optimize = optimize,
            .link_libc = false,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = .static,
    });
    const probe_step = b.step("ipcprobe", "build tc002-ipcprobe: the largest datagram the device's ipc socket carries");
    probe_step.dependOn(&b.addInstallArtifact(ipcprobe, .{}).step);

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

    // the panel console's renderer: the same scene modules the device runs, cross-compiled to
    // wasm so the browser preview draws the device's own pixels instead of a javascript port that
    // has to be re-synchronised by hand. `zig build wasm` refreshes the copy the console fetches.
    const wasm = b.addExecutable(.{
        .name = "tc002-panel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
            .link_libc = false,
            .strip = true,
            .single_threaded = true,
        }),
    });
    wasm.entry = .disabled; // a library of exports, not a program
    wasm.rdynamic = true; // keep every `export fn` in the module's export table
    const wasm_step = b.step("wasm", "build the console renderer and refresh panel-v2/tc002-panel.wasm");
    const wasm_copy = b.addUpdateSourceFiles();
    wasm_copy.addCopyFileToSource(wasm.getEmittedBin(), "../panel-v2/tc002-panel.wasm");
    wasm_step.dependOn(&wasm_copy.step);

    // the `/scenes` catalogue as a file, for clients that cannot ask a device for it (the mock
    // device serves it verbatim). generated from the same comptime tables the runtime serves.
    const scenes_tool = b.addExecutable(.{ .name = "scenes-json", .root_module = b.createModule(.{
        .root_source_file = b.path("src/scenes_json_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const run_scenes = b.addRunArtifact(scenes_tool);
    const scenes_json = run_scenes.addOutputFileArg("scenes.json");
    const scenes_copy = b.addUpdateSourceFiles();
    scenes_copy.addCopyFileToSource(scenes_json, "../panel-v2/scenes.json");
    const scenes_step = b.step("scenes", "write the /scenes catalogue to panel-v2/scenes.json");
    scenes_step.dependOn(&scenes_copy.step);

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

    // host bootstrap test: the same source built as a host dylib, dlopened by a small host tool.
    // one variant execs test/fake-supervisor.sh (expects exit 0), one a missing path (expects exit 1).
    const dlopen_host = b.addExecutable(.{ .name = "dlopen-host", .root_module = b.createModule(.{
        .root_source_file = b.path("src/dlopen_host_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    const bootstrap_test_step = b.step("test-bootstrap", "dlopen the host-built bootstrap and verify it execs the supervisor path");
    const variants = [_]struct { name: []const u8, path: []const u8, code: u8 }{
        .{ .name = "tc002-bootstrap-host-ok", .path = b.pathFromRoot("test/fake-supervisor.sh"), .code = 0 },
        .{ .name = "tc002-bootstrap-host-missing", .path = "/nonexistent/tc002-supervisor", .code = 1 },
    };
    for (variants) |v| {
        const host_options = b.addOptions();
        host_options.addOption([]const u8, "supervisor_path", v.path);
        const lib = b.addLibrary(.{
            .name = v.name,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bootstrap_main.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .link_libc = true,
            }),
        });
        lib.root_module.addOptions("build_options", host_options);
        const run = b.addRunArtifact(dlopen_host);
        run.addArtifactArg(lib);
        run.setEnvironmentVariable("TC002_TEST_ENV", "passed-through");
        run.expectExitCode(v.code);
        if (v.code == 1) run.expectStdErrEqual("tc002-bootstrap: exec of supervisor failed\n");
        bootstrap_test_step.dependOn(&run.step);
    }
}
