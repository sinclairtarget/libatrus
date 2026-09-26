//! Runs all snippet tests. These tests involve parsing and rendering the MyST
//! snippets defined in tests.zon.
//!
//! This is a regular Zig CLI program and not a module containing Zig test
//! declarations.
//!
//! A non-zero exit code is a failure of the test suite.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config");

const atrus = @import("atrus");

const TestCase = @import("test.zig").TestCase;
const test_cases: []const TestCase = @import("tests.zon");

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var num_succeeded: u32 = 0;
    var num_failed: u32 = 0;
    var num_skipped: u32 = 0;
    for (test_cases, 1..) |test_case, i| {
        if (test_case.skip_reason) |reason| {
            print(
                "{d}/{d} {s}: skipped (\"{s}\")\n",
                .{ i, test_cases.len, test_case.name, reason },
            );
            num_skipped += 1;
            continue;
        }

        defer _ = arena.reset(.retain_capacity);
        run_test(arena.allocator(), test_case) catch |err| {
            // show error in red
            std.debug.print(
                "{d}/{d} \x1b[31m{any}: {s}\x1b[0m\n",
                .{ i, test_cases.len, err, test_case.name },
            );
            num_failed += 1;
            continue;
        };

        // show success in green
        print(
            "{d}/{d} \x1b[32m{s}\x1b[0m\n",
            .{ i, test_cases.len, test_case.name },
        );
        num_succeeded += 1;
    }

    print(
        "{d} cases succeeded. {d} cases failed. {d} cases skipped.\n",
        .{ num_succeeded, num_failed, num_skipped },
    );
    if (num_failed > 0) {
        std.process.exit(1);
    }
}

fn run_test(alloc: Allocator, case: TestCase) !void {
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
    expectEqualStrings(case.json_pre, outbuf.written()) catch {
        return error.JSONPreNotEqual;
    };
    outbuf.clearRetainingCapacity();

    root_node = try atrus.transform(alloc, root_node, .{});

    // JSON POST
    if (case.json_post) |json_post| {
        try atrus.renderJSON(
            root_node,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        expectEqualStrings(json_post, outbuf.written()) catch {
            return error.JSONPostNotEqual;
        };
        outbuf.clearRetainingCapacity();
    }

    // HTML
    if (case.html) |html| {
        try atrus.renderHTML(
            root_node,
            &outbuf.writer,
            .{ .whitespace = .indent_2 },
        );
        expectEqualStrings(html, outbuf.written()) catch {
            return error.HTMLNotEqual;
        };
        outbuf.clearRetainingCapacity();
    }

    // Typst
    if (case.typst) |typst| {
        try atrus.renderTypst(root_node, &outbuf.writer, .{});
        expectEqualStrings(typst, outbuf.written()) catch {
            return error.TypstNotEqual;
        };
        outbuf.clearRetainingCapacity();
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    if (config.verbose) {
        std.debug.print(fmt, args);
    }
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (std.mem.indexOfDiff(u8, actual, expected)) |diff_index| {
        std.debug.print("expected:\n{s}\n", .{expected});
        std.debug.print("actual:\n{s}\n", .{actual});

        var diff_line_number: usize = 1;
        for (expected[0..diff_index]) |value| {
            if (value == '\n') diff_line_number += 1;
        }

        std.debug.print(
            "First difference occurs on line {d}:\n",
            .{diff_line_number},
        );
        std.debug.print("expected:\n", .{});
        printIndicatorLine(expected, diff_index);
        std.debug.print("actual:\n", .{});
        printIndicatorLine(actual, diff_index);

        return error.StringsNotEqual;
    }
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(
        u8,
        source[0..indicator_index],
        '\n',
    )) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.indexOfScalar(
        u8,
        source[indicator_index..],
        '\n',
    )) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    for (line_begin_index..indicator_index) |_|
        std.debug.print(" ", .{});

    if (indicator_index >= source.len)
        std.debug.print("^ (end of string)\n", .{})
    else
        std.debug.print("^ ('\\x{x:0>2}')\n", .{source[indicator_index]});
}

fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return std.debug.print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    std.debug.print("{s}\n", .{line});
}
