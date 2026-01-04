//! Runs all the test cases provided with the MyST spec.
//!
//! Since we load the test cases from a JSON file rather than defining them in
//! our Zig source, this is just a regular Zig CLI program and not a module
//! containing Zig test declarations. We consider a non-zero exit code a failure
//! of the test suite.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Io = std.Io;

const atrus = @import("atrus");
const spec = @import("spec.zig");

const Test = struct {
    case: spec.TestCase,

    const Self = @This();

    // Run test case.
    //
    // We parse the myst, rendering the AST as JSON to a buffer. Then we parse
    // that AST as a dynamic JSON value and compare it to the dynamic JSON value
    // for the AST we loaded from the spec test cases.
    //
    // If there is an expected HTML rendering we test that too.
    pub fn func(
        self: Self,
        alloc: Allocator,
        options: struct { verbose: bool = false },
    ) !void {
        var buf = Io.Writer.Allocating.init(alloc);
        var stringify = json.Stringify{
            .writer = &buf.writer,
            .options = .{
                .whitespace = .indent_2,
            },
        };
        try stringify.write(self.case.mdast);
        const expected = buf.written();

        const ast = try atrus.parse(
            alloc,
            self.case.myst,
            .{ .parse_level = .pre },
        );
        const actual = try atrus.renderJSONString(
            alloc,
            ast,
            .{ .whitespace = .indent_2 },
        );

        if (!std.mem.eql(u8, expected, actual)) {
            if (options.verbose) {
                std.debug.print("expected json:\n{s}\n", .{expected});
                std.debug.print("actual json:\n{s}\n", .{actual});
            }
            return error.NotEqual;
        }

        // html
        const post_ast = try atrus.parse(
            alloc,
            self.case.myst,
            .{ .parse_level = .post },
        );
        if (self.case.html) |expected_html| {
            const actual_html = try atrus.renderHTMLString(alloc, post_ast);
            if (!std.mem.eql(u8, expected_html, actual_html)) {
                if (options.verbose) {
                    std.debug.print("expected html:\n{s}\n", .{expected_html});
                    std.debug.print("actual html:\n{s}\n", .{actual_html});
                }
                return error.HTMLNotEqual;
            }
        }
    }
};

fn gatherTests(
    alloc: Allocator,
    path: []const u8,
    filter: ?[]const u8,
) ![]Test {
    const cases = try spec.readTestCases(alloc, path);

    var tests: ArrayList(Test) = .empty;
    for (cases) |case| {
        if (filter) |f| {
            if (std.ascii.indexOfIgnoreCase(case.title, f) == null) {
                continue;
            }
        }

        try tests.append(alloc, .{ .case = case });
    }

    return tests.toOwnedSlice(alloc);
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        _ = debug_allocator.detectLeaks();
        _ = debug_allocator.deinit();
    }
    const gpa = debug_allocator.allocator();

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const args = try std.process.argsAlloc(scratch);
    if (args.len < 2) {
        return error.NotEnoughArgs;
    }

    const path = args[1];
    var filter: ?[]const u8 = null;
    if (args.len >= 3) {
        filter = args[2];
    }

    const tests = gatherTests(scratch, path, filter) catch |err| {
        std.debug.print("failed to gather tests\n", .{});
        return err;
    };

    if (tests.len == 1) {
        const t = tests[0];
        try t.func(scratch, .{ .verbose = true });
        return;
    }

    var map = AutoHashMap(anyerror, u16).init(scratch);
    defer map.deinit();

    var per_test_arena = ArenaAllocator.init(gpa);
    defer per_test_arena.deinit();

    var num_succeeded: u32 = 0;
    var num_failed: u32 = 0;
    for (tests, 1..) |t, i| {
        defer _ = per_test_arena.reset(.retain_capacity);
        t.func(per_test_arena.allocator(), .{}) catch |err| {
            std.debug.print(
                "{d}/{d} \x1b[31m{any}: {s}\x1b[0m\n",
                .{ i, tests.len, err, t.case.title },
            );

            const existing_count = map.get(err);
            if (existing_count) |ec| {
                try map.put(err, ec + 1);
            } else {
                try map.put(err, 1);
            }

            num_failed += 1;
            continue;
        };

        std.debug.print(
            "{d}/{d} \x1b[32m{s}\x1b[0m\n",
            .{ i, tests.len, t.case.title },
        );
        num_succeeded += 1;
    }

    std.debug.print(
        "{d} cases succeeded. {d} cases failed.\n",
        .{ num_succeeded, num_failed },
    );
    if (num_failed > 0) {
        var it = map.iterator();
        while (it.next()) |entry| {
            std.debug.print(
                "{any}: {d}\n",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
        }

        std.process.exit(1);
    }
}
