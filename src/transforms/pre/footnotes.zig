const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const DefStore = @import("../../lookup/DefStore.zig");
const FootnoteDefMap = @import("../../lookup/footnotes.zig").DefMap;
const util = @import("../../util/util.zig");

/// Moves all footnote definition nodes to the end of the AST. The footnote
/// definitions are sorted according to when they are first referenced in the
/// AST. Definitions that are not referenced in the AST get dropped.
pub fn transform(
    alloc: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var reference_order_def_map: FootnoteDefMap = .empty;
    defer reference_order_def_map.deinit(alloc);

    try util.nodes.gatherFootnotesReferenceOrder(
        alloc,
        original_node,
        &reference_order_def_map,
    );

    var node = original_node;
    node = try dropFootnotes(alloc, original_node, reference_order_def_map);
    node = try addFootnotesAtEnd(alloc, node, reference_order_def_map);
    return node;
}

/// Remove footnote definitions from AST.
fn dropFootnotes(
    alloc: Allocator,
    node: *ast.Node,
    def_map: FootnoteDefMap,
) !*ast.Node {
    switch (node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                // If we have any footnote definition children, replace the
                // children slice with a copy that skips the definitions.

                var num_to_delete: u32 = 0;
                for (n.children) |child| {
                    if (@as(ast.NodeType, child.*) == .footnote_definition) {
                        num_to_delete += 1;
                    }
                }

                if (num_to_delete > 0) {
                    const new_children = try alloc.alloc(
                        *ast.Node,
                        n.children.len - num_to_delete,
                    );
                    var i: usize = 0;
                    for (n.children) |child| {
                        switch (child.*) {
                            .footnote_definition => |def_n| {
                                // Check if we ever had a reference to this
                                // definition. If not, deallocate it.
                                const stored = def_map.get(
                                    def_n.identifier,
                                ) catch null;
                                if (stored == null) {
                                    child.deinit(alloc);
                                }
                            },
                            else => {
                                new_children[i] = child;
                                i += 1;
                            },
                        }
                    }
                    alloc.free(n.children);
                    n.children = new_children;
                } else {
                    for (0..n.children.len) |i| {
                        n.children[i] = try dropFootnotes(
                            alloc,
                            n.children[i],
                            def_map,
                        );
                    }
                }

                return node;
            },
        },
        .no => return node,
    }
}

fn addFootnotesAtEnd(
    alloc: Allocator,
    node: *ast.Node,
    def_map: FootnoteDefMap,
) !*ast.Node {
    const original_children = node.root.children;
    defer alloc.free(original_children);

    const new_len: usize = original_children.len + def_map.count();
    var new_children = try alloc.alloc(*ast.Node, new_len);
    @memcpy(new_children[0..original_children.len], original_children);

    var i = original_children.len;
    var it = def_map.iterator();
    while (it.next()) |def_node| {
        new_children[i] = def_node;
        i += 1;
    }

    node.root.children = new_children;
    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "footnotes get handled correctly" {
    // Definition order is "foo", "bar", "bim"
    const footnote_def_1 = try testing.allocator.create(ast.Node);
    footnote_def_1.* = .{
        .footnote_definition = .{
            .children = &.{},
            .label = try testing.allocator.dupeZ(u8, "foo"),
            .identifier = try testing.allocator.dupeZ(u8, "foo"),
        },
    };
    const footnote_def_2 = try testing.allocator.create(ast.Node);
    footnote_def_2.* = .{
        .footnote_definition = .{
            .children = &.{},
            .label = try testing.allocator.dupeZ(u8, "bar"),
            .identifier = try testing.allocator.dupeZ(u8, "bar"),
        },
    };
    const footnote_def_3 = try testing.allocator.create(ast.Node);
    footnote_def_3.* = .{
        .footnote_definition = .{
            .children = &.{},
            .label = try testing.allocator.dupeZ(u8, "bim"),
            .identifier = try testing.allocator.dupeZ(u8, "bim"),
        },
    };

    // Reference order is "bim", "bar". No reference to "foo"
    const footnote_ref_1 = try testing.allocator.create(ast.Node);
    footnote_ref_1.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "bim"),
            .identifier = try testing.allocator.dupeZ(u8, "bim"),
        },
    };
    const footnote_ref_2 = try testing.allocator.create(ast.Node);
    footnote_ref_2.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "bar"),
            .identifier = try testing.allocator.dupeZ(u8, "bar"),
        },
    };
    const p_node = try testing.allocator.create(ast.Node);
    p_node.* = .{
        .paragraph = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{ footnote_ref_1, footnote_ref_2 },
            ),
        },
    };

    const root_node = try testing.allocator.create(ast.Node);
    root_node.* = .{
        .root = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{
                    footnote_def_1,
                    footnote_def_2,
                    p_node,
                    footnote_def_3,
                },
            ),
        },
    };

    const transformed_node = try transform(
        testing.allocator,
        root_node,
    );
    defer transformed_node.deinit(testing.allocator);
    try testing.expectEqual(3, transformed_node.root.children.len);

    try testing.expectEqual(
        .paragraph,
        @as(ast.NodeType, transformed_node.root.children[0].*),
    );
    try testing.expectEqual(
        .footnote_definition,
        @as(ast.NodeType, transformed_node.root.children[1].*),
    );
    try testing.expectEqualStrings(
        "bim",
        transformed_node.root.children[1].footnote_definition.label,
    );
    try testing.expectEqual(
        .footnote_definition,
        @as(ast.NodeType, transformed_node.root.children[2].*),
    );
    try testing.expectEqualStrings(
        "bar",
        transformed_node.root.children[2].footnote_definition.label,
    );
}
