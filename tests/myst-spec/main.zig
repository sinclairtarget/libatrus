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
    pub fn func(
        self: Self,
        alloc: Allocator,
        options: struct { verbose: bool = false },
    ) !void {
        var myst_reader: Io.Reader = .fixed(self.case.myst);
        const ast = try atrus.parse(alloc, &myst_reader);

        var actual = Io.Writer.Allocating.init(alloc);
        try atrus.renderJSON(
            ast,
            &actual.writer,
            .{
                .json_options = .{
                    .whitespace = .indent_2,
                },
            },
        );

        var expected = Io.Writer.Allocating.init(alloc);
        var stringify = json.Stringify{
            .writer = &expected.writer,
            .options = .{
                .whitespace = .indent_2,
            },
        };
        try stringify.write(self.case.mdast);

        if (!std.mem.eql(u8, expected.written(), actual.written())) {
            if (options.verbose) {
                std.debug.print("expected:\n{s}\n", .{expected.written()});
                std.debug.print("actual:\n{s}\n", .{actual.written()});
            }
            return error.NotEqual;
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
            if (std.mem.indexOf(u8, case.title, f) == null) {
                continue;
            }
        }

        try tests.append(alloc, .{ .case = case });
    }

    return tests.toOwnedSlice(alloc);
}

pub fn main() !void {
    var arena_impl = ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) {
        return error.NotEnoughArgs;
    }

    const path = args[1];
    var filter: ?[]const u8 = null;
    if (args.len >= 3) {
        filter = args[2];
    }

    const tests = gatherTests(arena, path, filter) catch |err| {
        std.debug.print("failed to gather tests\n", .{});
        return err;
    };

    if (tests.len == 1) {
        const t = tests[0];
        try t.func(arena, .{ .verbose = true });
        return;
    }

    var per_test_arena_impl = ArenaAllocator.init(std.heap.page_allocator);
    defer per_test_arena_impl.deinit();

    var num_succeeded: u32 = 0;
    for (tests, 1..) |t, i| {
        defer _ = per_test_arena_impl.reset(.retain_capacity);
        t.func(per_test_arena_impl.allocator(), .{}) catch |err| {
            std.debug.print(
                "test {d}/{d} (\"{s}\") failed: {any}\n",
                .{
                    i,
                    tests.len,
                    t.case.title,
                    err,
                },
            );

            continue;
        };

        num_succeeded += 1;
    }

    if (num_succeeded < tests.len) {
        std.process.exit(1);
    }
}
