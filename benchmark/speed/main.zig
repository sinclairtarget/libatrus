const std = @import("std");

pub fn main() !void {
    std.debug.print("{s}\n", .{"Hello, world! This is speed benchmark."});
}
