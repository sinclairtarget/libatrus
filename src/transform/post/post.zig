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
    switch (original_node.tag) {
        inline .block, .heading, .paragraph, .emphasis, .strong, .link,
        .blockquote, .myst_directive => |node_type| {
            const n = @field(original_node.payload, @tagName(node_type));
            for (0..n.n_children) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }
            return original_node;
        },
        .root => {
            const n = original_node.payload.root;
            for (0..n.n_children) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }
            return try transformRoot(alloc, scratch, original_node);
        },
        .container => {
            const n = original_node.payload.container;
            for (0..n.n_children) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }

            if (std.mem.eql(u8, "figure", std.mem.span(n.kind))) {
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

    const n = node.payload.container;
    const sliced = n.children[0..n.n_children];
    const caption_child, const index = for (sliced, 0..) |child, i| {
        if (child.tag != .image) {
            break .{child, i};
        }
    } else return node; // nothing to do

    const caption_node = try alloc.create(ast.Node);
    errdefer caption_node.deinit(alloc);

    const owned_children = try alloc.dupe(*ast.Node, &.{caption_child});
    errdefer alloc.free(owned_children);

    caption_node.* = .{
        .tag = .caption,
        .payload = .{
            .caption = .{
                .children = owned_children.ptr,
                .n_children = @intCast(owned_children.len),
            },
        },
    };

    n.children[index] = caption_node;
    return node;
}
