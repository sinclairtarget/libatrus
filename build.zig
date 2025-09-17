const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // atrus lib
    const atrus = b.addModule("atrus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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

    addTests(b, atrus);
    addBenchmarks(b, optimize);
}

// We have multiple groups of tests:
// * Unit tests (defined along side the source code for the library)
// * Spec tests (test conformance with the MyST spec)
// * CLI tests (runs atrus as a subprocess, functional tests)
fn addTests(b: *std.Build, atrus: *std.Build.Module) void {
    const mod_tests = b.addTest(.{
        .root_module = atrus,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
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
