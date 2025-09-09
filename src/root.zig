//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const version = "0.0.1";

pub fn parse(s: []u8) []u8 {
    return s;
}

// pub fn add(a: i32, b: i32) i32 {
//     return a + b;
// }
// 
// test "basic add functionality" {
//     try std.testing.expect(add(3, 7) == 10);
// }
// 
// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }
// 
// test "fuzz example" {
//     const Context = struct {
//         fn testOne(context: @This(), input: []const u8) anyerror!void {
//             _ = context;
//             // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//             try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
//         }
//     };
//     try std.testing.fuzz(Context{}, Context.testOne, .{});
// }
