//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ast = @import("../../ast.zig");

/// Apply all "post" stage transformations.
///
/// While typically you would call this on the root node of an AST, you can
/// also call this on any subtree of the AST. All node kinds are handled.
///
/// This transformation is idempotent.
pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var node = original_node;

    node = try groupByBlock(alloc, scratch, node);
    node = try enumerateContainers(alloc, scratch, node);

    return node;
}

/// Groups immediate children of the root node under blocks.
///
/// A block break begins a new block.
///
/// If there are block breaks in deeper nodes of the AST, they are left in
/// place.
fn groupByBlock(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
) !*ast.Node {
    _ = scratch;

    if (@as(ast.NodeType, node.*) != .root) {
        // This transformation should only be done on the root node.
        return node;
    }

    const original_children = node.root.children;
    defer alloc.free(original_children);

    var new_children: ArrayList(*ast.Node) = .empty;

    var current_block: ?*ast.Node = null;
    for (original_children) |child| {
        switch (child.*) {
            .block => {
                current_block = child;
            },
            .block_break => |n| {
                if (current_block) |block| {
                    try new_children.append(alloc, block);
                }

                current_block = try createBlockNode(alloc, n.meta);
            },
            else => {
                current_block = current_block orelse
                    try createBlockNode(alloc, "");

                // TODO: Find more efficient way to do this?
                try current_block.?.appendChild(alloc, child);
            },
        }
    }

    // Make sure we always have at least one block even if the root node
    // had no children.
    const last_block = current_block orelse try createBlockNode(alloc, "");
    try new_children.append(alloc, last_block);

    node.root.children = try new_children.toOwnedSlice(alloc);
    return node;
}

fn enumerateContainers(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var counter: u32 = 1;
    return try enumerateContainersInner(
        alloc,
        scratch,
        original_node,
        &counter,
    );
}

fn enumerateContainersInner(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
    counter: *u32,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .container => |n| {
                // Enumeration for containers
                // Want to do this in pre-order
                if (n.enumerated) {
                    n.enumerator = try std.fmt.allocPrintSentinel(
                        alloc,
                        "{d}",
                        .{counter.*},
                        0,
                    );
                    counter.* += 1;
                }

                for (0..n.children.len) |i| {
                    n.children[i] = try enumerateContainersInner(
                        alloc,
                        scratch,
                        n.children[i],
                        counter,
                    );
                }
                return original_node;
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try enumerateContainersInner(
                        alloc,
                        scratch,
                        n.children[i],
                        counter,
                    );
                }
                return original_node;
            },
        },
        .no => return original_node,
    }
}

fn createBlockNode(alloc: Allocator, meta: []const u8) !*ast.Node {
    const new = try alloc.create(ast.Node);
    new.* = .{
        .block = .{
            .children = &.{},
            .meta = try alloc.dupeZ(u8, meta),
        },
    };
    return new;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../../util/util.zig");

test "group by block, no block breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    const p_node_1: *ast.Node = blk: {
        const text_node = try alloc.create(ast.Node);
        text_node.* = .{
            .text = .{
                .value = try alloc.dupeZ(u8, "This is the first paragraph!"),
            },
        };

        const p_node = try alloc.create(ast.Node);
        p_node.* = .{
            .paragraph = .{
                .children = try alloc.dupe(
                    *ast.Node,
                    &[_]*ast.Node{text_node},
                ),
            },
        };

        break :blk p_node;
    };

    const p_node_2: *ast.Node = blk: {
        const text_node = try alloc.create(ast.Node);
        text_node.* = .{
            .text = .{
                .value = try alloc.dupeZ(u8, "This is the second paragraph!"),
            },
        };

        const p_node = try alloc.create(ast.Node);
        p_node.* = .{
            .paragraph = .{
                .children = try alloc.dupe(
                    *ast.Node,
                    &[_]*ast.Node{text_node},
                ),
            },
        };

        break :blk p_node;
    };

    const root_node: *ast.Node = blk: {
        const node = try alloc.create(ast.Node);
        const children = try alloc.dupe(*ast.Node, &[_]*ast.Node{
            p_node_1,
            p_node_2,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    const post_node = try transform(alloc, alloc, root_node);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.root.children.len);

    const block_node = post_node.root.children[0];
    try testing.expectEqual(.block, @as(ast.NodeType, block_node.*));
    try testing.expectEqual(2, block_node.block.children.len);
}

test "group by block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    const p_node_1: *ast.Node = blk: {
        const text_node = try alloc.create(ast.Node);
        text_node.* = .{
            .text = .{
                .value = try alloc.dupeZ(u8, "This is the first paragraph!"),
            },
        };

        const p_node = try alloc.create(ast.Node);
        p_node.* = .{
            .paragraph = .{
                .children = try alloc.dupe(
                    *ast.Node,
                    &[_]*ast.Node{text_node},
                ),
            },
        };

        break :blk p_node;
    };

    const block_break_node = try alloc.create(ast.Node);
    block_break_node.* = .{
        .block_break = .{ .meta = try alloc.dupeZ(u8, "") },
    };

    const p_node_2: *ast.Node = blk: {
        const text_node = try alloc.create(ast.Node);
        text_node.* = .{
            .text = .{
                .value = try alloc.dupeZ(u8, "This is the second paragraph!"),
            },
        };

        const p_node = try alloc.create(ast.Node);
        p_node.* = .{
            .paragraph = .{
                .children = try alloc.dupe(
                    *ast.Node,
                    &[_]*ast.Node{text_node},
                ),
            },
        };

        break :blk p_node;
    };

    const root_node: *ast.Node = blk: {
        const node = try alloc.create(ast.Node);
        const children = try alloc.dupe(*ast.Node, &[_]*ast.Node{
            p_node_1,
            block_break_node,
            p_node_2,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    const post_node = try transform(alloc, alloc, root_node);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(2, post_node.root.children.len);

    const block_node_1 = post_node.root.children[0];
    try testing.expectEqual(.block, @as(ast.NodeType, block_node_1.*));
    try testing.expectEqual(1, block_node_1.block.children.len);

    const block_node_2 = post_node.root.children[1];
    try testing.expectEqual(.block, @as(ast.NodeType, block_node_2.*));
    try testing.expectEqual(1, block_node_2.block.children.len);
}

test "enumerate figures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    const container_node_1 = try alloc.create(ast.Node);
    container_node_1.* = .{
        .container = .{
            .kind = try alloc.dupeZ(u8, "figure"),
            .enumerated = true,
            .children = &.{},
        },
    };

    const container_node_2 = try alloc.create(ast.Node);
    container_node_2.* = .{
        .container = .{
            .kind = try alloc.dupeZ(u8, "figure"),
            .enumerated = false,
            .children = &.{},
        },
    };

    const container_node_3 = try alloc.create(ast.Node);
    container_node_3.* = .{
        .container = .{
            .kind = try alloc.dupeZ(u8, "figure"),
            .enumerated = true,
            .children = &.{},
        },
    };

    const root_node: *ast.Node = blk: {
        const node = try alloc.create(ast.Node);
        const children = try alloc.dupe(*ast.Node, &[_]*ast.Node{
            container_node_1,
            container_node_2,
            container_node_3,
        });
        node.* = .{
            .root = .{ .children = children },
        };
        break :blk node;
    };

    const post_node = try transform(alloc, alloc, root_node);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.root.children.len);

    const block_node = post_node.root.children[0];
    try testing.expectEqual(.block, @as(ast.NodeType, block_node.*));
    try testing.expectEqual(3, block_node.block.children.len);

    const first_node = block_node.block.children[0];
    try testing.expectEqual(.container, @as(ast.NodeType, first_node.*));
    const first_enumerator = try util.testing.expectNonNull(
        first_node.container.enumerator,
    );
    try testing.expectEqualStrings("1", first_enumerator);

    const second_node = block_node.block.children[1];
    try testing.expectEqual(.container, @as(ast.NodeType, second_node.*));
    try testing.expectEqual(null, second_node.container.enumerator);

    const third_node = block_node.block.children[2];
    try testing.expectEqual(.container, @as(ast.NodeType, third_node.*));
    const third_enumerator = try util.testing.expectNonNull(
        third_node.container.enumerator,
    );
    try testing.expectEqualStrings("2", third_enumerator);
}
