const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const spec = @import("spec.zig");

const Test = struct {
    case: spec.TestCase,

    pub fn func(self: @This()) !void {
        _ = self;
        return error.NotImplemented;
    }
};

fn gatherTests(alloc: Allocator) ![]Test {
    const cases = try spec.readTestCases(
        alloc, 
        "tests/myst-spec/myst.tests.json",
    );

    var tests: ArrayList(Test) = .empty;
    for (cases) |case| {
        try tests.append(alloc, .{
            .case = case,
        });
    }

    return tests.toOwnedSlice(alloc);
}

// This single Zig test checks all the test cases defined in the MyST spec. I
// haven't been able to work out an easy way to have a separate test for each
// test case. That's okay; we just need to report the number of tests that
// failed and succeeded ourselves.
test {
    var arena_impl = ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();

    const tests = gatherTests(arena_impl.allocator()) catch |err| {
        std.debug.print("failed to gather tests\n", .{});
        return err;
    };

    var num_succeeded: u32 = 0;
    for (tests, 1..) |t, i| {
        t.func() catch |err| {
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

    try std.testing.expectEqual(tests.len, num_succeeded);
}
