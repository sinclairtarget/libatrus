//! Runs all the test cases provided with the MyST spec.
//!
//! Since we load the test cases from a JSON file rather than defining them in
//! our Zig source, this is just a regular Zig CLI program and not a module
//! containing Zig test declarations. We consider a non-zero exit code a
//! failure of the test suite.
//!
//! The MyST spec tests verify that the "pre" AST output by libatrus is
//! correct. We also make some attempt to match on rendered HTML too.

const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Io = std.Io;

const atrus = @import("atrus");
const test_helper = @import("test_helper");

const TestCase = @import("test.zig").TestCase;

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main(init: std.process.Init) !void {
    const scratch = init.arena.allocator();

    const args = try init.minimal.args.toSlice(scratch);
    if (args.len < 2) {
        return error.NotEnoughArgs;
    }

    const path = args[1];
    const verbose, const filter = test_helper.extractTestArgs(args[2..]);

    const test_cases_to_run = gatherTests(
        init.io,
        scratch,
        path,
        filter,
    ) catch |err| {
        std.debug.print("failed to gather tests\n", .{});
        return err;
    };
    const print_detailed_error: bool = verbose and test_cases_to_run.len == 1;

    var map = AutoHashMap(anyerror, u16).init(scratch);
    defer map.deinit();

    var per_test_arena = ArenaAllocator.init(init.gpa);
    defer per_test_arena.deinit();

    var reporter: test_helper.Reporter = .init(test_cases_to_run.len, verbose);
    for (test_cases_to_run) |test_case| {
        defer _ = per_test_arena.reset(.retain_capacity);
        runTest(
            per_test_arena.allocator(),
            test_case,
            print_detailed_error,
        ) catch |err| {
            reporter.fail(test_case.title, err);

            const existing_count = map.get(err);
            if (existing_count) |ec| {
                try map.put(err, ec + 1);
            } else {
                try map.put(err, 1);
            }

            continue;
        };

        // show success in green
        const extra: ?[]const u8 = if (test_case.skip_html_reason) |reason|
            try std.fmt.allocPrint(
                scratch,
                " (skipped html, reason: \"{s}\")",
                .{reason},
            )
        else
            null;
        reporter.succeed(test_case.title, .{ .extra = extra });
    }

    reporter.summarize();
    if (reporter.num_failed > 0) {
        if (verbose) {
            var it = map.iterator();
            while (it.next()) |entry| {
                std.debug.print(
                    "{any}: {d}\n",
                    .{ entry.key_ptr.*, entry.value_ptr.* },
                );
            }
        }

        std.process.exit(1);
    }
}

fn gatherTests(
    io: Io,
    alloc: Allocator,
    path: []const u8,
    filter: ?[]const u8,
) ![]TestCase {
    const cases = try readTestCases(io, alloc, path);

    var tests: ArrayList(TestCase) = .empty;
    for (cases) |case| {
        if (filter) |f| {
            if (std.ascii.indexOfIgnoreCase(case.title, f) == null) {
                continue;
            }
        }

        try tests.append(alloc, case);
    }

    return tests.toOwnedSlice(alloc);
}

// Run test case.
//
// We parse the myst, rendering the AST as JSON to a buffer. Then we parse
// that AST as a dynamic JSON value and compare it to the dynamic JSON
// value for the AST we loaded from the spec test cases.
//
// If there is an expected HTML rendering we test that too.
fn runTest(
    alloc: Allocator,
    test_case: TestCase,
    print_detailed_error: bool,
) !void {
    var buf = Io.Writer.Allocating.init(alloc);
    var stringify = json.Stringify{
        .writer = &buf.writer,
        .options = .{
            .whitespace = .indent_2,
        },
    };
    try stringify.write(test_case.mdast);
    const expected = buf.written();

    var reader = Io.Reader.fixed(test_case.myst);
    const ast = try atrus.parse(
        alloc,
        &reader,
        .{ .parse_level = .pre }, // testing only the "pre" AST
    );

    var outbuf = Io.Writer.Allocating.init(alloc);
    try atrus.renderJSON(
        ast,
        &outbuf.writer,
        .{ .whitespace = .indent_2 },
    );
    const actual = outbuf.written();

    if (!std.mem.eql(u8, expected, actual)) {
        if (print_detailed_error) {
            std.debug.print("myst:\n{s}\n", .{test_case.myst});
            test_helper.printStringDiff(expected, actual);
        }
        return error.NotEqual;
    }

    // html
    reader = Io.Reader.fixed(test_case.myst);
    const post_ast = try atrus.parse(
        alloc,
        &reader,
        .{ .parse_level = .post },
    );
    if (test_case.html != null and test_case.skip_html_reason == null) {
        const expected_html = test_case.html.?;
        outbuf = Io.Writer.Allocating.init(alloc);
        try atrus.renderHTML(
            post_ast,
            &outbuf.writer,
            .{
                .whitespace = if (test_case.html_indented)
                    .indent_2
                else
                    .indent_none,
            },
        );
        if (outbuf.written().len > 0)
            _ = try outbuf.writer.writeAll("\n");

        const actual_html = outbuf.written();
        if (!std.mem.eql(u8, expected_html, actual_html)) {
            if (print_detailed_error) {
                std.debug.print("myst:\n{s}\n", .{test_case.myst});
                test_helper.printStringDiff(expected_html, actual_html);
            }
            return error.HTMLNotEqual;
        }
    }
}

fn readTestCases(
    io: Io,
    alloc: Allocator,
    path: []const u8,
) ![]const TestCase {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [64]u8 = undefined;
    var reader_impl = file.reader(io, &buffer);
    const reader = &reader_impl.interface;

    var json_reader = json.Reader.init(alloc, reader);
    defer json_reader.deinit();

    const parsed = try json.parseFromTokenSourceLeaky(
        []const TestCase,
        alloc,
        &json_reader,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    );
    return parsed;
}
