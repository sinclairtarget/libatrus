//! Implements the post-process / resolution phase, where the AST is cleaned up
//! and links/references are resolved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const blocks = @import("blocks.zig");
const enumerate = @import("enumerate.zig");

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

    node = try blocks.transform(alloc, node);
    node = try enumerate.transform(alloc, scratch, node);

    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../../util/util.zig");

test "group by block, no block breaks" {
    var alloc = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

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

    const post_node = try transform(alloc, arena.allocator(), root_node);
    defer post_node.deinit(alloc);

    try testing.expectEqual(.root, @as(ast.NodeType, post_node.*));
    try testing.expectEqual(1, post_node.root.children.len);

    const block_node = post_node.root.children[0];
    try testing.expectEqual(.block, @as(ast.NodeType, block_node.*));
    try testing.expectEqual(2, block_node.block.children.len);
}

test "group by block" {
    var alloc = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

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

    const post_node = try transform(alloc, arena.allocator(), root_node);
    defer post_node.deinit(alloc);

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
    var alloc = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

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

    const post_node = try transform(alloc, arena.allocator(), root_node);
    defer post_node.deinit(alloc);

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
