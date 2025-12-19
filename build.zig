const std = @import("std");

const Step = std.Build.Step;

const LibraryArtifacts = struct {
    static_lib: *Step.InstallArtifact,
    shared_lib: *Step.InstallArtifact,
    header: *Step.InstallFile,
    pkgconfig: *Step.InstallFile,
};

/// We have multiple groups of tests:
/// * Unit tests (defined along side the source code for the library)
/// * Spec tests (test conformance with the MyST spec)
/// * CLI tests (runs atrus as a subprocess, functional tests)
/// * C API tests (makes sure the C API links and works)
const TestCmds = struct {
    unit: *Step.Run,
    spec: *Step.Run,
    cli: *Step.Run,
    c_api: *Step.Run,
};

/// We have two benchmark executables, one that benchmarks peak memory usage and
/// another that benchmarks (wall clock) performance.
const BenchmarkCmds = struct {
    memory: *Step.Run,
    speed: *Step.Run,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option(
        []const u8,
        "version",
        "Application version string",
    ) orelse "0.1.0";
    const test_case_filter = b.option(
        []const u8,
        "test-filter",
        "Filter for test cases",
    );

    // atrus module
    const atrus_module = b.addModule("atrus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    atrus_module.addOptions("config", options);

    // atrus cli
    const exe_artifact = installExecutable(b, atrus_module, target, optimize);

    // libatrus
    const lib_artifacts = installLibrary(b, atrus_module, target, optimize);

    // tests and benchmarks
    const test_cmds = addTests(
        b,
        atrus_module,
        exe_artifact.artifact,
        lib_artifacts.shared_lib.artifact,
        test_case_filter,
    );
    const benchmark_cmds = addBenchmarks(b, exe_artifact.artifact, optimize);

    // -- top-level build steps ------------------------------------------------
    // exe
    const exe_step = b.step("exe", "Install Atrus CLI executable only");
    exe_step.dependOn(&exe_artifact.step);

    // static lib
    const static_step = b.step("static", "Install static library only");
    static_step.dependOn(&lib_artifacts.static_lib.step);
    static_step.dependOn(&lib_artifacts.header.step);
    static_step.dependOn(&lib_artifacts.pkgconfig.step);

    // dynamic lib
    const shared_step = b.step("shared", "Install shared library only");
    shared_step.dependOn(&lib_artifacts.shared_lib.step);
    shared_step.dependOn(&lib_artifacts.header.step);
    shared_step.dependOn(&lib_artifacts.pkgconfig.step);

    // install (default)
    const install_step = b.getInstallStep();
    install_step.dependOn(shared_step);

    // run
    const run_cmd = b.addRunArtifact(exe_artifact.artifact);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Atrus CLI");
    run_step.dependOn(&run_cmd.step);

    // tests
    const unit_test_step = b.step("test-unit", "Run unit tests");
    unit_test_step.dependOn(&test_cmds.unit.step);

    const spec_test_step = b.step("test-spec", "Run MyST spec tests");
    spec_test_step.dependOn(&test_cmds.spec.step);

    const test_step = b.step(
        "test",
        "Run all tests (unit, MyST spec, CLI, C API)",
    );
    test_step.dependOn(&test_cmds.unit.step);
    test_step.dependOn(&test_cmds.spec.step);
    test_step.dependOn(&test_cmds.cli.step);
    test_step.dependOn(&test_cmds.c_api.step);

    // benchmarks
    const benchmark_step = b.step("benchmark", "Run all benchmarks");
    benchmark_step.dependOn(&benchmark_cmds.memory.step);
    benchmark_step.dependOn(&benchmark_cmds.speed.step);
}

fn installExecutable(
    b: *std.Build,
    atrus_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Step.InstallArtifact {
    const exe = b.addExecutable(.{
        .name = "atrus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "atrus", .module = atrus_module },
            },
        }),
    });
    return b.addInstallArtifact(exe, .{});
}

fn installLibrary(
    b: *std.Build,
    atrus_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) LibraryArtifacts {
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "atrus", .module = atrus_module },
        },
    });

    const static_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "atrus",
        .root_module = c_api_module,
    });
    static_lib.linkLibC();

    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "atrus",
        .root_module = c_api_module,
    });

    const c_header = b.addInstallFileWithDir(
        b.path("include/atrus.h"),
        .header,
        "atrus.h",
    );

    // pkgconfig
    const pc: *Step.InstallFile = pc: {
        const file = b.addWriteFile(
            "libatrus.pc",
            b.fmt(
                \\prefix={s}
                \\includedir=${{prefix}}/include
                \\libdir=${{prefix}}/lib
                \\
                \\Name: libatrus
                \\URL: https://github.com/sinclairtarget/libatrus
                \\Description: A MyST parser/document engine
                \\Version: 0.1.0
                \\Cflags: -I${{includedir}}
                \\Libs: -L${{libdir}} -latrus
                \\
                ,
                .{b.install_prefix},
            )
        );
        break :pc b.addInstallFileWithDir(
            file.getDirectory().path(b, "libatrus.pc"),
            .prefix,
            "share/pkgconfig/libatrus.pc",
        );
    };

    return .{
        .static_lib = b.addInstallArtifact(static_lib, .{}),
        .shared_lib = b.addInstallArtifact(shared_lib, .{}),
        .header = c_header,
        .pkgconfig = pc,
    };
}

fn addTests(
    b: *std.Build,
    atrus_module: *std.Build.Module,
    atrus_exe: *Step.Compile,
    static_lib: *Step.Compile,
    test_filter: ?[]const u8,
) TestCmds {
    // Unit tests
    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = atrus_module,
        .filters = if (test_filter) |f|
            &[_][]const u8 { f }
        else
            &.{},
    });
    const unit_tests_cmd = b.addRunArtifact(unit_tests);

    // MyST Spec tests
    const spec_tests_exe = b.addExecutable(.{
        .name = "spec-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/myst_spec/main.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "atrus", .module = atrus_module },
            },
        }),
    });
    const spec_tests_cmd = b.addRunArtifact(spec_tests_exe);
    const spec_cases_path = b.path("tests/myst_spec/myst.tests.json");
    spec_tests_cmd.addFileArg(spec_cases_path);
    if (test_filter) |f| {
        spec_tests_cmd.addArg(f);
    }

    // Functional CLI tests.
    // We pass the path to the atrus executable into the tests as a config
    // option.
    const cli_tests = b.addTest(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/root.zig"),
            .target = b.graph.host,
        }),
    });
    const options = b.addOptions();
    options.addOptionPath("exec_path", atrus_exe.getEmittedBin()); // Adds dep
    cli_tests.root_module.addOptions("config", options);
    const cli_tests_cmd = b.addRunArtifact(cli_tests);

    // C API tests
    const c_api_tests_exe = b.addExecutable(.{
        .name = "c-api-tests",
        .root_module = b.createModule(.{
            .link_libc = true,
            .target = b.graph.host,
        }),
    });
    c_api_tests_exe.root_module.addCSourceFile(.{
        .file = b.path("tests/c_api/main.c"),
        .flags = &.{"-std=c99"},
    });
    c_api_tests_exe.root_module.addIncludePath(b.path("include/"));
    c_api_tests_exe.root_module.linkLibrary(static_lib);
    const c_api_tests_cmd = b.addRunArtifact(c_api_tests_exe);

    return .{
        .unit = unit_tests_cmd,
        .spec = spec_tests_cmd,
        .cli = cli_tests_cmd,
        .c_api = c_api_tests_cmd,
    };
}

fn addBenchmarks(
    b: *std.Build,
    atrus_exe: *Step.Compile,
    optimize: std.builtin.OptimizeMode,
) BenchmarkCmds {
    const memory_exe = b.addExecutable(.{
        .name = "benchmark-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/memory/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const options = b.addOptions();
    options.addOptionPath("exec_path", atrus_exe.getEmittedBin()); // Adds dep
    memory_exe.root_module.addOptions("config", options);
    const memory_cmd = b.addRunArtifact(memory_exe);

    const speed_exe = b.addExecutable(.{
        .name = "benchmark-speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/speed/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    speed_exe.root_module.addOptions("config", options);
    const speed_cmd = b.addRunArtifact(speed_exe);

    return .{
        .memory = memory_cmd,
        .speed = speed_cmd,
    };
}
