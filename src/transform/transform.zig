//! Functions that take an entire AST and return a modified AST.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const ast = @import("../parse/ast.zig");
const LinkDefMap = @import("../parse/link_defs.zig").LinkDefMap;
const post = @import("post.zig");
const @"inline" = @import("inline.zig");

pub fn postProcess(alloc: Allocator, root: *ast.Node) !*ast.Node {
    return try post.transform(alloc, root);
}

pub fn parseInlines(
    alloc: Allocator,
    scratch_arena: *ArenaAllocator,
    root: *ast.Node,
    link_defs: LinkDefMap,
) !*ast.Node {
    return try @"inline".transform(alloc, scratch_arena, root, link_defs);
}
