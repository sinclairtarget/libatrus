//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");

pub fn postProcess(gpa: Allocator, root: *ast.Node) !*ast.Node {
    return try processRoot(gpa, root);
}

fn processRoot(gpa: Allocator, node: *ast.Node) !*ast.Node {
    const block = try gpa.create(ast.Node);
    block.* = .{
        .block = .{
            .children = node.root.children,
        },
    };

    node.root.children = try gpa.alloc(*ast.Node, 1);
    node.root.children[0] = block;
    return node;
}
