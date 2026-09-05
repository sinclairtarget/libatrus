const std = @import("std");
const pkg_zon = @import("build.zig.zon");

const Step = std.Build.Step;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    // Project-specific options
    const allow_log_scopes = b.option(
        bool,
        "allow-log-scopes",
        "Enables fine-grained log scopes",
    );
    const test_case_filter = b.option(
        []const u8,
        "test-filter",
        "Filter for test cases",
    );
    const test_verbose = b.option(
        bool,
        "test-verbose",
        "Enable test output",
    ) orelse false;
    const entities_json_path = b.option(
        []const u8,
        "entities-json-path",
        "Path to JSON file with named character entities table",
    );
    const casefold_txt_path = b.option(
        []const u8,
        "casefold-txt-path",
        "Path to TXT file with unicode case fold mappings",
    );

    // data module
    const data_module = b.createModule(.{
        .root_source_file = b.path("data/root.zig"),
        .target = target,
    });

    // atrus module
    // Using "addModule()" here adds the package to the package module set,
    // making it available to anyone consuming libatrus as a Zig package.
    const atrus_module = b.addModule("atrus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "data", .module = data_module },
        },
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", pkg_zon.version);
    options.addOption(
        bool,
        "allow_log_scopes",
        allow_log_scopes orelse false,
    );
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
        test_verbose,
    );
    const benchmark_cmds = addBenchmarks(b, exe_artifact.artifact, optimize);

    // tools
    const entities_tool = addUpdateEntitiesTool(b, entities_json_path);
    const casefold_tool = addUpdateCaseFoldTool(b, casefold_txt_path);

    // docs
    const docs = installDocs(b, exe_artifact.artifact);

    // -- top-level build steps -----------------------------------------------
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
    install_step.dependOn(static_step);

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

    const document_test_step = b.step("test-document", "Run document tests");
    document_test_step.dependOn(&test_cmds.document.step);

    const c_api_test_step = b.step("test-lib", "Run C API tests");
    c_api_test_step.dependOn(&test_cmds.c_api.step);

    const cli_test_step = b.step("test-cli", "Run CLI tests");
    cli_test_step.dependOn(&test_cmds.cli.step);

    const test_step = b.step(
        "test",
        "Run all tests (unit, MyST spec, document, CLI, C API)",
    );
    test_step.dependOn(&test_cmds.unit.step);
    test_step.dependOn(&test_cmds.spec.step);
    test_step.dependOn(&test_cmds.document.step);
    test_step.dependOn(&test_cmds.cli.step);
    test_step.dependOn(&test_cmds.c_api.step);

    // benchmarks
    const benchmark_step = b.step("benchmark", "Run all benchmarks");
    benchmark_step.dependOn(&benchmark_cmds.memory.step);
    benchmark_step.dependOn(&benchmark_cmds.speed.step);

    // tools
    const generate_entities_step = b.step(
        "update-entities",
        "Update named character entities table",
    );
    generate_entities_step.dependOn(&entities_tool.cmd.step);
    generate_entities_step.dependOn(&entities_tool.update.step);

    const generate_casefold_step = b.step(
        "update-casefold",
        "Update casefold mapping table",
    );
    generate_casefold_step.dependOn(&casefold_tool.cmd.step);
    generate_casefold_step.dependOn(&casefold_tool.update.step);

    // docs
    const docs_step = b.step("docs", "Install documentation");
    docs_step.dependOn(&docs.step);
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

/// What we can install when building as a library.
const LibraryArtifacts = struct {
    static_lib: *Step.InstallArtifact,
    shared_lib: *Step.InstallArtifact,
    header: *Step.InstallFile,
    pkgconfig: *Step.InstallFile,
};

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
        const file = b.addWriteFile("libatrus.pc", b.fmt(
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
        ));
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

/// We have multiple groups of tests:
/// * Unit tests (defined alongside the source code for the library)
/// * Spec tests (test conformance with the MyST spec)
/// * Document tests (test for regressions in converting to different formats)
/// * CLI tests (runs atrus as a subprocess, tests debug CLI functionality)
/// * C API tests (makes sure the C API links and works)
const TestCmds = struct {
    unit: *Step.Run,
    spec: *Step.Run,
    document: *Step.Run,
    cli: *Step.Run,
    c_api: *Step.Run,
};

// TODO: Currently some of these tests are just run as regular Zig programs
// using addRunArtifact(). It's not clear to me if this is the best way to do
// things. Some of these test executables will also run even when their inputs
// have not changed (they're not properly cached).
fn addTests(
    b: *std.Build,
    atrus_module: *std.Build.Module,
    atrus_exe: *Step.Compile,
    static_lib: *Step.Compile,
    test_filter: ?[]const u8,
    test_verbose: bool,
) TestCmds {
    // Unit tests
    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = atrus_module,
        .filters = if (test_filter) |f|
            &[_][]const u8{f}
        else
            &.{},
    });
    const unit_tests_cmd = b.addRunArtifact(unit_tests);

    // MyST Spec tests
    const spec_module = b.createModule(.{
        .root_source_file = b.path("tests/myst_spec/main.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "atrus", .module = atrus_module },
        },
    });
    const spec_options = b.addOptions();
    spec_options.addOption(bool, "verbose", test_verbose);
    spec_module.addOptions("config", spec_options);
    const spec_tests_exe = b.addExecutable(.{
        .name = "spec-tests",
        .root_module = spec_module,
    });
    const spec_tests_cmd = b.addRunArtifact(spec_tests_exe);
    const spec_cases_path = b.path("tests/myst_spec/myst-0.0.5.tests.json");
    spec_tests_cmd.addFileArg(spec_cases_path);
    if (test_filter) |f| {
        spec_tests_cmd.addArg(f);
    }

    // Document tests
    const document_module = b.createModule(.{
        .root_source_file = b.path("tests/document/main.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "atrus", .module = atrus_module },
        },
    });
    const document_tests_dir = b.path("tests/document");
    const document_options = b.addOptions();
    document_options.addOption(bool, "verbose", test_verbose);
    document_options.addOptionPath("tests_dirpath", document_tests_dir);
    document_module.addOptions("config", document_options);
    const document_tests_exe = b.addExecutable(.{
        .name = "document-tests",
        .root_module = document_module,
    });
    const document_tests_cmd = b.addRunArtifact(document_tests_exe);

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
    const cli_options = b.addOptions();
    cli_options.addOptionPath("exec_path", atrus_exe.getEmittedBin()); // Adds dep
    cli_tests.root_module.addOptions("config", cli_options);
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
    var c_api_tests_cmd = b.addRunArtifact(c_api_tests_exe);
    _ = c_api_tests_cmd.captureStdErr(); // Hide debug output from libatrus

    return .{
        .unit = unit_tests_cmd,
        .spec = spec_tests_cmd,
        .document = document_tests_cmd,
        .cli = cli_tests_cmd,
        .c_api = c_api_tests_cmd,
    };
}

/// We have two benchmark executables, one that benchmarks peak memory usage
/// and another that benchmarks (wall clock) performance.
const BenchmarkCmds = struct {
    memory: *Step.Run,
    speed: *Step.Run,
};

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

const Tool = struct {
    cmd: *Step.Run,
    update: *Step.UpdateSourceFiles,
};

fn addUpdateEntitiesTool(
    b: *std.Build,
    maybe_json_path: ?[]const u8,
) Tool {
    const exe = b.addExecutable(.{
        .name = "generate-entities",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_entities.zig"),
            .target = b.graph.host,
        }),
    });
    const cmd = b.addRunArtifact(exe);

    if (maybe_json_path) |json_path| {
        cmd.addFileArg(b.path(json_path));
    } else {
        cmd.step.dependOn(&b.addFail("missing input file path").step);
    }

    const output_path = cmd.addOutputFileArg("data/entities.zon");

    const update_src = b.addUpdateSourceFiles();
    update_src.addCopyFileToSource(output_path, "data/entities.zon");

    return .{
        .cmd = cmd,
        .update = update_src,
    };
}

fn addUpdateCaseFoldTool(
    b: *std.Build,
    maybe_case_fold_path: ?[]const u8,
) Tool {
    const exe = b.addExecutable(.{
        .name = "generate-casefold",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_casefold.zig"),
            .target = b.graph.host,
        }),
    });
    const cmd = b.addRunArtifact(exe);

    if (maybe_case_fold_path) |case_fold_path| {
        cmd.addFileArg(b.path(case_fold_path));
    } else {
        cmd.step.dependOn(&b.addFail("missing input file path").step);
    }

    const output_path = cmd.addOutputFileArg("data/case_fold.zon");

    const update_src = b.addUpdateSourceFiles();
    update_src.addCopyFileToSource(output_path, "data/case_fold.zon");

    return .{
        .cmd = cmd,
        .update = update_src,
    };
}

fn installDocs(b: *std.Build, exe: *Step.Compile) *Step.InstallDir {
    return b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
}
