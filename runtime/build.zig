const std = @import("std");
const builtin = @import("builtin");

/// the vendored berry interpreter: one source list, used by every target that embeds it.
/// be_filelib.c is deliberately absent -- there is no filesystem, and vendor/berry/port/be_port.c
/// refuses the four entry points the rest of the tree references unconditionally.
const berry_sources = [_][]const u8{
    "src/be_api.c",       "src/be_baselib.c",       "src/be_bytecode.c",  "src/be_byteslib.c",
    "src/be_class.c",     "src/be_code.c",          "src/be_debug.c",     "src/be_debuglib.c",
    "src/be_exec.c",      "src/be_func.c",          "src/be_gc.c",        "src/be_gclib.c",
    "src/be_globallib.c", "src/be_introspectlib.c", "src/be_jsonlib.c",   "src/be_lexer.c",
    "src/be_libs.c",      "src/be_list.c",          "src/be_listlib.c",   "src/be_map.c",
    "src/be_maplib.c",    "src/be_mathlib.c",       "src/be_mem.c",       "src/be_module.c",
    "src/be_object.c",    "src/be_oslib.c",         "src/be_parser.c",    "src/be_rangelib.c",
    "src/be_repl.c",      "src/be_solidifylib.c",   "src/be_strictlib.c", "src/be_string.c",
    "src/be_strlib.c",    "src/be_syslib.c",        "src/be_timelib.c",   "src/be_undefinedlib.c",
    "src/be_var.c",       "src/be_vector.c",        "src/be_vm.c",
    "port/be_port.c",     "port/be_modtab.c",
};

/// add berry's headers and sources to a module. the module must link libc: berry's error model is
/// setjmp/longjmp and it formats reals with snprintf, and this runtime has neither otherwise.
fn addBerry(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor/berry/src"));
    m.addIncludePath(b.path("vendor/berry/port"));
    m.addIncludePath(b.path("vendor/berry/generate"));
    m.addCSourceFiles(.{
        .root = b.path("vendor/berry"),
        .files = &berry_sources,
        .flags = &.{ "-std=c99", "-Os", "-Wall", "-Wextra" },
    });
}


/// what this build is, for a device to report back.
///
/// `git describe --always --dirty`, resolved once when the build graph is made. it is deliberately
/// **not** a timestamp: a value that changed every build would invalidate the options module and
/// rebuild all six binaries on every `zig build`, and the question this answers is "which source is
/// running", which a clock cannot tell you anyway.
///
/// `-dirty` is the honest part. these binaries are usually built from a worktree with uncommitted
/// changes, and a bare hash would then claim a provenance the tree does not have. two builds of the
/// same dirty tree share an id, which is the limit of what a commit hash can say; when that matters,
/// commit.
///
/// no git, no repository, or a git that fails: "unknown". a build id is a convenience and must
/// never be the reason a build does not happen.
fn buildId(b: *std.Build) []const u8 {
    const argv = [_][]const u8{ "git", "-C", b.pathFromRoot("."), "describe", "--always", "--dirty", "--abbrev=12" };
    var code: u8 = 0;
    // `runAllowFail` rather than `run`: `run` aborts the build when the command fails, and a
    // missing git is not a reason to refuse to compile a clock
    const out = b.runAllowFail(&argv, &code, .ignore) catch return "unknown";
    if (code != 0) return "unknown";
    const text = std.mem.trim(u8, out, " \t\r\n");
    if (text.len == 0) return "unknown";
    // no cap here on purpose: `messages.build_id_max` is the one that decides how much of this
    // reaches a device, and a second number here could only ever disagree with it
    return b.dupe(text);
}

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0")) @panic("this project pins zig 0.16.0");

    // where the runtime's binaries live **at runtime**: `/tmp/tc002` for the pushed install,
    // `/res/bin` for a flashed one. this is not cosmetic. the bootstrap execs the supervisor with
    // only `--from-bootstrap`, and the supervisor spawns five children by absolute path, so a
    // flashed runtime never sees a command-line argument in its life -- every path it uses is the
    // one compiled in here. built with the default and put on /res, the binaries would not find
    // each other.
    const bin_dir = b.option([]const u8, "bin_dir", "directory the binaries live in at runtime (/tmp/tc002; /res/bin for a flashed image)") orelse "/tmp/tc002";
    // whether this build brings wifi up itself at boot. a flashed install must -- the loader we
    // replace is what used to do it -- and a /tmp install must not, because bringing it up again
    // restarts wpa_supplicant and adb is over that link.
    const netup = b.option(bool, "netup", "bring wifi up from bin_dir at boot (a flashed image must; a /tmp install must not)") orelse false;
    const supervisor_path = b.option([]const u8, "supervisor_path", "path the bootstrap execs (<bin_dir>/tc002-supervisor)") orelse b.fmt("{s}/tc002-supervisor", .{bin_dir});
    const options = b.addOptions();
    options.addOption([]const u8, "supervisor_path", supervisor_path);
    options.addOption([]const u8, "bin_dir", bin_dir);
    options.addOption([]const u8, "netup_dir", if (netup) bin_dir else "");
    options.addOption([]const u8, "build_id", buildId(b));

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

    // a diagnostic rather than part of the runtime: what one message between two processes costs
    const ipcbench = b.addExecutable(.{
        .name = "tc002-ipcbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipcbench_main.zig"),
            .target = device,
            .optimize = optimize,
            .link_libc = false,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = .static,
    });
    // the speaker. the one binary in this runtime that is **dynamically linked against the
    // device's own glibc**, because it dlopens the vendor's `libmi_ao.so` to hand pcm to the
    // audio-out. the control-plane ioctls were recovered and work statically, but the data plane
    // marshals samples through a buffer the library allocates itself, and reverse-engineering that
    // against a driver that wedges on a wrong guess is a worse trade than this dependency. see
    // vendor/mi_ao/README.md.
    const audio_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
        .glibc_version = .{ .major = 2, .minor = 30, .patch = 0 },
    });
    const audiod = b.addExecutable(.{
        .name = "tc002-audiod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audiod_main.zig"),
            .target = audio_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .single_threaded = true,
        }),
    });
    audiod.root_module.linkSystemLibrary("dl", .{});
    audiod.root_module.addOptions("build_options", options);
    b.installArtifact(audiod);

    // a diagnostic: walks the audio control plane and prints what each ioctl returned
    const soundprobe = b.addExecutable(.{
        .name = "tc002-soundprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/soundprobe_main.zig"),
            .target = device,
            .optimize = optimize,
            .link_libc = false,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = .static,
    });
    const soundprobe_step = b.step("soundprobe", "build tc002-soundprobe: open the audio devices and report each ioctl");
    soundprobe_step.dependOn(&b.addInstallArtifact(soundprobe, .{}).step);

    const bench_step = b.step("ipcbench", "build tc002-ipcbench: round-trip latency and frame throughput over the ipc socket");
    bench_step.dependOn(&b.addInstallArtifact(ipcbench, .{}).step);

    // the script interpreter, in a process of its own. the only binary here that links libc:
    // berry's error model is setjmp/longjmp and it formats reals with snprintf.
    const berryd = b.addExecutable(.{
        .name = "tc002-berryd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/berryd_main.zig"),
            .target = device,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = .static,
    });
    addBerry(b, berryd.root_module);
    berryd.root_module.addOptions("build_options", options);
    b.installArtifact(berryd);

    // a diagnostic rather than part of the runtime: proves the vendored interpreter links for the
    // device, and is what its size on this target is measured from.
    const berry_check = b.addExecutable(.{
        .name = "tc002-berry-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/berry_check_main.zig"),
            .target = device,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .single_threaded = true,
        }),
        .linkage = .static,
    });
    addBerry(b, berry_check.root_module);
    const berry_check_step = b.step("berry-check", "build tc002-berry-check: the vendored interpreter, linked for the device");
    berry_check_step.dependOn(&b.addInstallArtifact(berry_check, .{}).step);

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

    // the vendored interpreter, exercised on the host: .be fixtures through the same c the device
    // runs. kept out of `zig build test` on purpose -- the aggregator's tests are pure zig and must
    // not start needing a c toolchain.
    const berry_fixtures = b.addExecutable(.{ .name = "berry-fixtures", .root_module = b.createModule(.{
        .root_source_file = b.path("src/berry_fixtures_main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    }) });
    addBerry(b, berry_fixtures.root_module);
    const run_fixtures = b.addRunArtifact(berry_fixtures);
    run_fixtures.addDirectoryArg(b.path("test/berry"));
    const berry_test_step = b.step("test-berry", "run the .be fixtures through the vendored interpreter on the host");
    berry_test_step.dependOn(&run_fixtures.step);

    // the scripts in scripts/berry are shipped for people to put on a device, so they get the same
    // interpreter and one thing more: a burst of the events the device really produces, fired at
    // whatever each script registered. a script that compiles but raises on the first button press
    // is the failure a user meets first, and it is invisible to a plain load.
    const run_scripts = b.addRunArtifact(berry_fixtures);
    run_scripts.addDirectoryArg(b.path("scripts/berry"));
    run_scripts.addArg("--exercise");
    const scripts_step = b.step("check-scripts", "run the shipped berry scripts and fire real events at them");
    scripts_step.dependOn(&run_scripts.step);

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
