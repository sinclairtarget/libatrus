const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");

const Self = @This();

pub fn parse(self: *Self, gpa: Allocator, root: *ast.Node) !*ast.Node {
    _ = self;
    _ = gpa;
    return root;
}
