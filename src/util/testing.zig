const std = @import("std");

/// Asserts that an optional value is not null, returning the unwrapped type.
pub fn expectNonNull(val: anytype) !OptChild(@TypeOf(val)) {
    return val orelse {
        std.debug.print("val was null\n", .{});
        return error.TestExpectedNonNull;
    };
}

/// Returns child type give an optional type.
fn OptChild(T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        .null => void,
        else => @compileError("expected optional type"),
    };
}
