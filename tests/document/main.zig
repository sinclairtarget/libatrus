//! Runs all document tests.
//!
//! This is a regular Zig CLI program and not a module containing Zig test
//! declarations.
//!
//! A non-zero exit code is a failure of the test suite.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const atrus = @import("atrus");
const config = @import("config");
const test_helper = @import("test_helper");

const TestCase = @import("test.zig").TestCase;
const all_test_cases: []const TestCase = @import("tests.zon");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    const verbose, const filter = test_helper.extractTestArgs(args[1..]);

    const test_cases_to_run = try gatherTests(alloc, filter);
    const print_detailed_error: bool = verbose and test_cases_to_run.len == 1;

    var per_test_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer per_test_arena.deinit();

    var reporter: test_helper.Reporter = .init(test_cases_to_run.len, verbose);
    for (test_cases_to_run) |test_case| {
        if (test_case.skip_reason) |reason| {
            reporter.skip(test_case.name(), reason);
            continue;
        }

        defer _ = per_test_arena.reset(.retain_capacity);
        runTest(
            per_test_arena.allocator(),
            test_case,
            config.tests_dirpath,
            print_detailed_error,
        ) catch |err| {
            reporter.fail(test_case.name(), err);
            continue;
        };

        reporter.succeed(test_case.name(), .{});
    }

    reporter.summarize();

    if (reporter.num_failed > 0) {
        std.process.exit(1);
    }
}

fn gatherTests(alloc: Allocator, filter: ?[]const u8) ![]TestCase {
    var tests: ArrayList(TestCase) = .empty;
    for (all_test_cases) |case| {
        if (filter) |f| {
            if (std.ascii.indexOfIgnoreCase(case.name(), f) == null) {
                continue;
            }
        }

        try tests.append(alloc, case);
    }

    return try tests.toOwnedSlice(alloc);
}

fn runTest(
    alloc: Allocator,
    test_case: TestCase,
    rootdir: []const u8,
    print_detailed_error: bool,
) !void {
    const mystmd = try slurpFile(
        alloc,
        rootdir,
        test_case.mystmd_path,
        print_detailed_error,
    );

    var reader = Io.Reader.fixed(mystmd);
    var root_node = try atrus.parse(
        alloc,
        &reader,
        .{ .parse_level = .pre },
    );

    // Check JSON PRE
    var outbuf = Io.Writer.Allocating.init(alloc);
    try atrus.renderJSON(
        root_node,
        &outbuf.writer,
        .{ .whitespace = .indent_2 },
    );
    _ = try outbuf.writer.writeAll("\n");

    const expected_json_pre = try slurpFile(
        alloc,
        rootdir,
        test_case.json_pre_path,
        print_detailed_error,
    );
    if (!std.mem.eql(u8, expected_json_pre, outbuf.written())) {
        if (print_detailed_error) {
            test_helper.printStringDiff(expected_json_pre, outbuf.written());
        }
        return error.JSONPreNotEqual;
    }

    outbuf.clearRetainingCapacity();

    // Check JSON POST
    root_node = try atrus.transform(alloc, root_node, .{});

    try atrus.renderJSON(
        root_node,
        &outbuf.writer,
        .{ .whitespace = .indent_2 },
    );
    _ = try outbuf.writer.writeAll("\n");

    const expected_json_post = try slurpFile(
        alloc,
        rootdir,
        test_case.json_post_path,
        print_detailed_error,
    );
    if (!std.mem.eql(u8, expected_json_post, outbuf.written())) {
        if (print_detailed_error) {
            test_helper.printStringDiff(expected_json_post, outbuf.written());
        }
        return error.JSONPostNotEqual;
    }

    outbuf.clearRetainingCapacity();

    // Check HTML
    try atrus.renderHTML(
        root_node,
        &outbuf.writer,
        .{ .whitespace = .indent_2 },
    );
    _ = try outbuf.writer.writeAll("\n");

    const expected_html = try slurpFile(
        alloc,
        rootdir,
        test_case.html_path,
        print_detailed_error,
    );
    if (!std.mem.eql(u8, expected_html, outbuf.written())) {
        if (print_detailed_error) {
            test_helper.printStringDiff(expected_html, outbuf.written());
        }
        return error.HTMLNotEqual;
    }

    outbuf.clearRetainingCapacity();

    if (test_case.typst_path) |_| {
        return error.NotYetImplemented;
    }
}

fn slurpFile(
    alloc: Allocator,
    rootdir: []const u8,
    path: []const u8,
    print_detailed_error: bool,
) ![]const u8 {
    const adjusted_path = try std.fs.path.join(alloc, &.{ rootdir, path });

    var buffer: [128]u8 = undefined;

    var file = std.fs.cwd().openFile(adjusted_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (print_detailed_error) {
                    std.debug.print(
                        "Missing file: \"{s}\"\n",
                        .{adjusted_path},
                    );
                }
                return err;
            },
            else => return err,
        }
    };
    defer file.close();

    var reader_impl = file.reader(&buffer);
    const reader = &reader_impl.interface;
    const bytes = try reader.allocRemaining(alloc, .unlimited);
    return bytes;
}
