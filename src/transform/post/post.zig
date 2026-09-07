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
    var node = original_node;

    node = try groupByBlock(alloc, scratch, node);
    node = try enumerateContainers(alloc, scratch, node);

    return node;
}

/// Groups all children of the root under a single block node.
fn groupByBlock(
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

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;
const util = @import("../../util/util.zig");

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

    const post_node = try transform(
        alloc,
        alloc,
        root_node,
    );

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
