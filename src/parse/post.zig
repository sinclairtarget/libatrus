const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");

pub fn postProcess(alloc: Allocator, root: *ast.Node) !*ast.Node {
    _ = alloc;
    return root;
}
