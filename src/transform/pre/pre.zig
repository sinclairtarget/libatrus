const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const roles = @import("roles.zig");
const directives = @import("directives.zig");

/// Apply all "pre" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var node = try roles.transform(alloc, scratch, original_node);
    node = try directives.transform(alloc, scratch, original_node);
    return node;
}
