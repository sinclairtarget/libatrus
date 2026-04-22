const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const roles = @import("roles.zig");

/// Apply all "pre" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    const node = try roles.transform(alloc, scratch, original_node);
    return node;
}
