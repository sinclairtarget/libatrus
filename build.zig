const std = @import("std");

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

    addTests(b, atrus, exe, spec_test_case_filter);
    addBenchmarks(b, optimize);
}

// We have multiple groups of tests:
// * Unit tests (defined along side the source code for the library)
// * Spec tests (test conformance with the MyST spec)
// * CLI tests (runs atrus as a subprocess, functional tests)
fn addTests(
    b: *std.Build, 
    atrus: *std.Build.Module,
    exe: *std.Build.Step.Compile,
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
            .root_source_file = b.path("tests/myst-spec/main.zig"),
            .target = b.graph.host, 
            .imports = &.{
                .{ .name = "atrus", .module = atrus },
            },
        }),
    });
    const run_spec_exe = b.addRunArtifact(spec_exe);
    const spec_cases_path = b.path("tests/myst-spec/myst.tests.json");
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_spec_exe.step);
    test_step.dependOn(&run_cli_tests.step);
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
