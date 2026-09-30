//! Runs all snippet tests. These tests involve parsing and rendering the MyST
//! snippets defined in tests.zon.
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
            reporter.skip(test_case.name, reason);
            continue;
        }

        defer _ = per_test_arena.reset(.retain_capacity);
        runTest(
            per_test_arena.allocator(),
            test_case,
            print_detailed_error,
        ) catch |err| {
            reporter.fail(test_case.name, err);
            continue;
        };

        reporter.succeed(test_case.name, .{});
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
            if (std.ascii.indexOfIgnoreCase(case.name, f) == null) {
                continue;
            }
        }

        try tests.append(alloc, case);
    }

    return try tests.toOwnedSlice(alloc);
}

fn runTest(
    alloc: Allocator,
    case: TestCase,
    print_detailed_error: bool,
) !void {
    var reader = Io.Reader.fixed(case.mystmd);
    var root_node = try atrus.parse(
        alloc,
        &reader,
        .{ .parse_level = .pre },
    );

    var outbuf = Io.Writer.Allocating.init(alloc);

    // JSON PRE
    try atrus.renderJSON(
        root_node,
        &outbuf.writer,
        .{ .whitespace = .indent_2 },
    );
    if (!std.mem.eql(u8, case.json_pre, outbuf.written())) {
        if (print_detailed_error) {
            test_helper.printStringDiff(case.json_pre, outbuf.written());
        }
        return error.JSONPreNotEqual;
    }
    outbuf.clearRetainingCapacity();

    root_node = try atrus.transform(alloc, root_node, .{});

    // JSON POST
    if (case.json_post) |json_post| {
        try atrus.renderJSON(
            root_node,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        if (!std.mem.eql(u8, json_post, outbuf.written())) {
            if (print_detailed_error) {
                test_helper.printStringDiff(json_post, outbuf.written());
            }
            return error.JSONPostNotEqual;
        }
        outbuf.clearRetainingCapacity();
    }

    // HTML
    if (case.html) |html| {
        try atrus.renderHTML(
            root_node,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        if (!std.mem.eql(u8, html, outbuf.written())) {
            if (print_detailed_error) {
                test_helper.printStringDiff(html, outbuf.written());
            }
            return error.HTMLNotEqual;
        }
        outbuf.clearRetainingCapacity();
    }

    // Typst
    if (case.typst) |typst| {
        try atrus.renderTypst(root_node, &outbuf.writer, .{});
        if (!std.mem.eql(u8, typst, outbuf.written())) {
            if (print_detailed_error) {
                test_helper.printStringDiff(typst, outbuf.written());
            }
            return error.TypstNotEqual;
        }
        outbuf.clearRetainingCapacity();
    }
}
