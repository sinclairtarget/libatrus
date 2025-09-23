const std = @import("std");

const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option(
        []const u8,
        "version",
        "Application version string",
    ) orelse "0.1.0";
    const spec_test_case_filter = b.option(
        []const u8,
        "case-filter",
        "Filter for MyST spec test cases",
    );

    // atrus lib
    const atrus = b.addModule("atrus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    atrus.addOptions("config", options);

    // atrus cli
    const exe = b.addExecutable(.{
        .name = "atrus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "atrus", .module = atrus },
            },
        }),
    });
    b.installArtifact(exe);

    // zig run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib = addCLibraries(b, atrus, target, optimize);
    addTests(b, atrus, exe, lib, spec_test_case_filter);
    addBenchmarks(b, optimize);
}

fn addCLibraries(
    b: *std.Build,
    atrus: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Step.Compile {
    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "atrus", .module = atrus },
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "atrus",
        .root_module = c_api_module,
    });
    lib.linkLibC();

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
            "share/pkconfig/libatrus.pc",
        );
    };

    b.installArtifact(lib);
    b.getInstallStep().dependOn(&c_header.step);
    b.getInstallStep().dependOn(&pc.step);

    return lib;
}

// We have multiple groups of tests:
// * Unit tests (defined along side the source code for the library)
// * Spec tests (test conformance with the MyST spec)
// * CLI tests (runs atrus as a subprocess, functional tests)
// * C API tests (makes sure the C API links and works)
fn addTests(
    b: *std.Build, 
    atrus: *std.Build.Module,
    exe: *Step.Compile,
    lib: *Step.Compile,
    filter: ?[]const u8,
) void {
    // Unit tests
    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = atrus,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // MyST Spec tests
    const spec_exe = b.addExecutable(.{
        .name = "spec-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/myst_spec/main.zig"),
            .target = b.graph.host, 
            .imports = &.{
                .{ .name = "atrus", .module = atrus },
            },
        }),
    });
    const run_spec_exe = b.addRunArtifact(spec_exe);
    const spec_cases_path = b.path("tests/myst_spec/myst.tests.json");
    run_spec_exe.addFileArg(spec_cases_path);

    if (filter) |f| {
        run_spec_exe.addArg(f);
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
    options.addOptionPath("exec_path", exe.getEmittedBin()); // Adds dependency
    cli_tests.root_module.addOptions("config", options);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // C API tests
    const c_exe = b.addExecutable(.{
        .name = "c-api-tests",
        .root_module = b.createModule(.{
            .link_libc = true,
            .target = b.graph.host, 
        }),
    });
    c_exe.root_module.addCSourceFile(.{
        .file = b.path("tests/c_api/main.c"),
        .flags = &.{"-std=c99"},
    });
    c_exe.root_module.addIncludePath(b.path("include/"));
    c_exe.root_module.linkLibrary(lib);
    const run_c_exe = b.addRunArtifact(c_exe);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_spec_exe.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_c_exe.step);
}

// We have two benchmark executables, one that benchmarks peak memory usage and
// another that benchmarks (wall clock) performance.
fn addBenchmarks(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) void {
    const memory = b.addExecutable(.{
        .name = "benchmark-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/memory/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const memory_cmd = b.addRunArtifact(memory);

    const speed = b.addExecutable(.{
        .name = "benchmark-speed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/speed/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const speed_cmd = b.addRunArtifact(speed);

    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&memory_cmd.step);
    benchmark_step.dependOn(&speed_cmd.step);
}
