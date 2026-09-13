const std = @import("std");
const Allocator = std.mem.Allocator;
const BufMap = std.BufMap;

const ast = @import("../../ast.zig");
const footnotes = @import("../../lookup/footnotes.zig");
const util = @import("../../util/util.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var node = original_node;

    node = try enumerateContainers(alloc, node);
    node = try enumerateFootnotes(alloc, scratch, node);

    return node;
}

fn enumerateContainers(
    alloc: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    var counter: u32 = 1;
    return try enumerateContainersInner(
        alloc,
        original_node,
        &counter,
    );
}

fn enumerateContainersInner(
    alloc: Allocator,
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

/// Assigns numbers to footnote references and definitions.
fn enumerateFootnotes(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
) Allocator.Error!*ast.Node {
    var reference_order_def_map: footnotes.DefMap = .empty;

    // Build map of definitions in reference order
    try util.nodes.gatherFootnotesReferenceOrder(
        scratch,
        node,
        &reference_order_def_map,
    );

    // Turn map into map of identifier to number
    const number_lookup = try footnotes.number(
        scratch,
        reference_order_def_map,
    );

    return try enumerateFootnotesInner(
        alloc,
        scratch,
        node,
        number_lookup,
    );
}

fn enumerateFootnotesInner(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    number_lookup: BufMap,
) !*ast.Node {
    switch (node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .footnote_definition => |n| {
                if (number_lookup.get(n.identifier)) |number| {
                    n.enumerator = try alloc.dupeZ(u8, number);
                }
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try enumerateFootnotesInner(
                        alloc,
                        scratch,
                        n.children[i],
                        number_lookup,
                    );
                }
            },
        },
        .no => |leaf_node| switch (leaf_node) {
            .footnote_reference => |n| {
                if (number_lookup.get(n.identifier)) |number| {
                    n.enumerator = try alloc.dupeZ(u8, number);
                }
            },
            else => {},
        },
    }

    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

test "enumerate footnotes" {
    const footnote_ref_1 = try testing.allocator.create(ast.Node);
    footnote_ref_1.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "foo"),
            .identifier = try testing.allocator.dupeZ(u8, "foo"),
        },
    };
    const footnote_ref_2 = try testing.allocator.create(ast.Node);
    footnote_ref_2.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "1"),
            .identifier = try testing.allocator.dupeZ(u8, "1"),
        },
    };
    const footnote_ref_3 = try testing.allocator.create(ast.Node);
    footnote_ref_3.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "4"),
            .identifier = try testing.allocator.dupeZ(u8, "4"),
        },
    };
    const footnote_ref_4 = try testing.allocator.create(ast.Node);
    footnote_ref_4.* = .{
        .footnote_reference = .{
            .label = try testing.allocator.dupeZ(u8, "bar"),
            .identifier = try testing.allocator.dupeZ(u8, "bar"),
        },
    };
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
            .label = try testing.allocator.dupeZ(u8, "1"),
            .identifier = try testing.allocator.dupeZ(u8, "1"),
        },
    };
    const footnote_def_3 = try testing.allocator.create(ast.Node);
    footnote_def_3.* = .{
        .footnote_definition = .{
            .children = &.{},
            .label = try testing.allocator.dupeZ(u8, "4"),
            .identifier = try testing.allocator.dupeZ(u8, "4"),
        },
    };
    const footnote_def_4 = try testing.allocator.create(ast.Node);
    footnote_def_4.* = .{
        .footnote_definition = .{
            .children = &.{},
            .label = try testing.allocator.dupeZ(u8, "bar"),
            .identifier = try testing.allocator.dupeZ(u8, "bar"),
        },
    };

    const root_node = try testing.allocator.create(ast.Node);
    root_node.* = .{
        .root = .{
            .children = try testing.allocator.dupe(
                *ast.Node,
                &.{
                    footnote_ref_1,
                    footnote_ref_2,
                    footnote_ref_3,
                    footnote_ref_4,
                    footnote_def_1,
                    footnote_def_2,
                    footnote_def_3,
                    footnote_def_4,
                },
            ),
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const transformed_node = try transform(
        testing.allocator,
        arena.allocator(),
        root_node,
    );
    defer transformed_node.deinit(testing.allocator);

    try testing.expectEqual(.root, @as(ast.NodeType, transformed_node.*));
    try testing.expectEqual(8, transformed_node.root.children.len);

    const expected_numbering = [_][]const u8{ "2", "1", "4", "5" };
    for (
        transformed_node.root.children[0..4],
        expected_numbering,
    ) |child_node, expected_number| {
        try testing.expectEqual(
            .footnote_reference,
            @as(ast.NodeType, child_node.*),
        );

        const enumerator = try util.testing.expectNonNull(
            child_node.footnote_reference.enumerator,
        );
        try testing.expectEqualStrings(expected_number, enumerator);
    }

    for (
        transformed_node.root.children[4..],
        expected_numbering,
    ) |child_node, expected_number| {
        try testing.expectEqual(
            .footnote_definition,
            @as(ast.NodeType, child_node.*),
        );

        const enumerator = try util.testing.expectNonNull(
            child_node.footnote_definition.enumerator,
        );
        try testing.expectEqualStrings(expected_number, enumerator);
    }
}
