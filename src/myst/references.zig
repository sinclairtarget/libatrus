const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn normalizeIdentifier(alloc: Allocator, s: []const u8) ![]const u8 {
    // TODO: Value must be normalized such that whitespace is collapsed to a
    // single space, initial/final space is trimmed, and case is folded
    return try std.ascii.allocLowerString(alloc, s);
}
