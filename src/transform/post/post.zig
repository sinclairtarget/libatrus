//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");

const State = struct {
    container_number: u32 = 1,
};

/// Apply all "post" stage transformations.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var state: State = .{};
    return try transformInternal(alloc, scratch, original_node, &state);
}

fn transformInternal(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
    state: *State,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .root => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try transformInternal(
                        alloc,
                        scratch,
                        n.children[i],
                        state,
                    );
                }
                return try transformRoot(alloc, scratch, original_node);
            },
            .container => |n| { // TODO: Do this in separate transformation.
                // Enumeration for containers
                // Want to do this in pre-order
                if (n.enumerated) {
                    n.enumerator = try std.fmt.allocPrintSentinel(
                        alloc,
                        "{d}",
                        .{state.container_number},
                        0,
                    );
                    state.container_number += 1;
                }

                for (0..n.children.len) |i| {
                    n.children[i] = try transformInternal(
                        alloc,
                        scratch,
                        n.children[i],
                        state,
                    );
                }
                return original_node;
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try transformInternal(
                        alloc,
                        scratch,
                        n.children[i],
                        state,
                    );
                }
                return original_node;
            },
        },
        .no => return original_node,
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
