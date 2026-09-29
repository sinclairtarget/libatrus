const std = @import("std");

/// Reports test case success/failure to stderr.
pub const Reporter = struct {
    allow_output: bool,
    num_cases: usize,
    case_i: usize,
    num_succeeded: u32,
    num_failed: u32,
    num_skipped: u32,

    pub fn init(num_cases: usize, allow_output: bool) Reporter {
        return .{
            .allow_output = allow_output,
            .num_cases = num_cases,
            .case_i = 1, // 1-indexed
            .num_succeeded = 0,
            .num_failed = 0,
            .num_skipped = 0,
        };
    }

    pub fn succeed(self: *Reporter, test_name: []const u8) void {
        self.print(
            // Print in green
            "{d}/{d} \x1b[32m{s}\x1b[0m\n",
            .{ self.case_i, self.num_cases, test_name },
        );
        self.case_i += 1;
        self.num_succeeded += 1;
    }

    pub fn fail(self: *Reporter, test_name: []const u8, err: anytype) void {
        self.print(
            // Print in red
            "{d}/{d} \x1b[31m{s}: {any}\x1b[0m\n",
            .{ self.case_i, self.num_cases, test_name, err },
        );
        self.case_i += 1;
        self.num_failed += 1;
    }

    pub fn skip(
        self: *Reporter,
        test_name: []const u8,
        reason: []const u8,
    ) void {
        self.print(
            "{d}/{d} {s}: skipped (\"{s}\")\n",
            .{ self.case_i, self.num_cases, test_name, reason },
        );
        self.case_i += 1;
        self.num_skipped += 1;
    }

    pub fn summarize(self: Reporter) void {
        self.print(
            "{d} cases succeeded. {d} cases failed. {d} cases skipped.\n",
            .{ self.num_succeeded, self.num_failed, self.num_skipped },
        );
    }

    fn print(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.allow_output) {
            std.debug.print(fmt, args);
        }
    }
};

/// Prints the difference between two strings to stderr.
///
/// Largely cribbed from std.testing.
pub fn printStringDiff(expected: []const u8, actual: []const u8) void {
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
