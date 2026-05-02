//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");

/// Apply all "post" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.*) {
        inline .block, .heading, .paragraph, .emphasis, .strong, .link,
        .blockquote, .myst_directive => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }
            return original_node;
        },
        .root => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }
            return try transformRoot(alloc, scratch, original_node);
        },
        .container => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }

            if (std.mem.eql(u8, "figure", n.kind)) {
                return try transformFigure(alloc, scratch, original_node);
            }

            return original_node;
        },
        else => return original_node,
    }
}

/// Groups all children of the root under a single block node.
fn transformRoot(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
) !*ast.Node {
    _ = scratch;

    const block = try alloc.create(ast.Node);
    errdefer block.deinit(alloc);

    block.* = .{
        .block = .{
            .children = node.root.children,
        },
    };

    var root_children = try alloc.alloc(*ast.Node, 1);
    root_children[0] = block;
    node.root.children = root_children;
    return node;
}

/// Applies a caption to figures.
///
/// Takes the first non-image child of the figure, if one exists, and wraps it
/// in a caption node.
fn transformFigure(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
) !*ast.Node {
    _ = scratch;

    const n = node.container;
    const caption_child, const index = for (n.children, 0..) |child, i| {
        if (@as(ast.NodeType, child.*) != .image) {
            break .{child, i};
        }
    } else return node; // nothing to do

    const caption_node = try alloc.create(ast.Node);
    errdefer caption_node.deinit(alloc);

    const owned_children = try alloc.dupe(*ast.Node, &.{caption_child});
    errdefer alloc.free(owned_children);

    caption_node.* = .{
        .caption = .{
            .children = owned_children,
        },
    };

    n.children[index] = caption_node;
    return node;
}
