//! Runs all document tests.
//!
//! This is a regular Zig CLI program and not a module containing Zig test
//! declarations.
//!
//! A non-zero exit code is a failure of the test suite.

const std = @import("std");
const config = @import("config");

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
        if (test_case.skip) {
            print(
                "{d}/{d} {s}: skipped\n",
                .{ i, test_cases.len, test_case.name() },
            );
            num_skipped += 1;
            continue;
        }

        defer _ = arena.reset(.retain_capacity);
        test_case.run(arena.allocator(), config.tests_dirpath) catch |err| {
            // show error in red
            std.debug.print(
                "{d}/{d} \x1b[31m{any}: {s}\x1b[0m\n",
                .{ i, test_cases.len, err, test_case.name() },
            );
            num_failed += 1;
            continue;
        };

        // show success in green
        print(
            "{d}/{d} \x1b[32m{s}\x1b[0m\n",
            .{ i, test_cases.len, test_case.name() },
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

fn print(comptime fmt: []const u8, args: anytype) void {
    if (config.verbose) {
        std.debug.print(fmt, args);
    }
}
