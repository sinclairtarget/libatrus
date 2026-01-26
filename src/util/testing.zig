const std = @import("std");

pub fn expectNonNull(T: type, val: ?T) !T {
    return val orelse {
        std.debug.print("val was null\n", .{});
        return error.TestExpectedNonNull;
    };
}
