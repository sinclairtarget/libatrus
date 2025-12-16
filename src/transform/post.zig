//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../parse/ast.zig");

pub fn transform(gpa: Allocator, node: *ast.Node) !*ast.Node {
    const block = try gpa.create(ast.Node);
    block.* = .{
        .block = .{
            .children = node.root.children,
        },
    };

    var root_children = try gpa.alloc(*ast.Node, 1);
    root_children[0] = block;
    node.root.children = root_children;
    node.root.is_post_processed = true;
    return node;
}
