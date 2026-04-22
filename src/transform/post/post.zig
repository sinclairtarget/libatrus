//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");

/// Apply all "post" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
) !*ast.Node {
    _ = scratch;

    const block = try alloc.create(ast.Node);
    errdefer block.deinit(alloc);

    block.* = .{
        .tag = .block,
        .payload = .{
            .block = .{
                .children = node.payload.root.children,
                .n_children = node.payload.root.n_children,
            },
        },
    };

    var root_children = try alloc.alloc(*ast.Node, 1);
    root_children[0] = block;
    node.payload.root.children = root_children.ptr;
    node.payload.root.n_children = 1;
    return node;
}
