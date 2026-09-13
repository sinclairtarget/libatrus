const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../ast.zig");
const FootnoteDefMap = @import("../lookup/footnotes.zig").DefMap;

/// Creates a text node with the given text value.
///
/// The value is copied and owned by the returned node.
pub fn createTextNode(alloc: Allocator, value: []const u8) !*ast.Node {
    const copy = try alloc.dupeZ(u8, value);
    errdefer alloc.free(copy);

    const node = try alloc.create(ast.Node);
    node.* = .{
        .text = .{
            .value = copy,
        },
    };
    return node;
}

/// Builds a map of all footnote definitions in the AST.
///
/// Definitions are inserted in the order they appear in the AST.
pub fn gatherFootnotes(
    alloc: Allocator,
    node: *ast.Node,
    def_map: *FootnoteDefMap,
) !void {
    switch (node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .footnote_definition => {
                // TODO: Handle errors
                def_map.add(alloc, node) catch {};

                // footnote definitions can't nest, so no need to look at
                // children
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    try gatherFootnotes(
                        alloc,
                        n.children[i],
                        def_map,
                    );
                }
            },
        },
        .no => {},
    }
}

/// Builds a map of all footnote definitions referenced in the AST.
///
/// Definitions are inserted in the order they are referenced by footnote
/// references.
pub fn gatherFootnotesReferenceOrder(
    alloc: Allocator,
    node: *ast.Node,
    def_map_reference_order: *FootnoteDefMap,
) !void {
    // We need to gather all the definitions first
    var def_map: FootnoteDefMap = .empty;
    defer def_map.deinit(alloc);
    try gatherFootnotes(alloc, node, &def_map);

    try gatherFootnotesReferenceOrderInner(
        alloc,
        node,
        def_map,
        def_map_reference_order,
    );
}

fn gatherFootnotesReferenceOrderInner(
    alloc: Allocator,
    node: *ast.Node,
    def_map: FootnoteDefMap,
    def_map_reference_order: *FootnoteDefMap,
) !void {
    // Now we create an identical map, but inserting in reference order
    switch (node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
            .footnote_definition => {}, // can't contain footnote reference
            inline else => |n| {
                for (0..n.children.len) |i| {
                    try gatherFootnotesReferenceOrderInner(
                        alloc,
                        n.children[i],
                        def_map,
                        def_map_reference_order,
                    );
                }
            },
        },
        .no => |leaf_node| switch (leaf_node) {
            .footnote_reference => |n| {
                // Use the definition-order def map to look up the definition
                // for this reference.
                //
                // Then insert that definition into the new map we're building
                // which is in reference order instead of definition order.
                const definition = def_map.get(
                    n.identifier,
                ) catch null; // TODO: Handle errors
                if (definition) |def_node| {
                    // TODO: Handle errors
                    def_map_reference_order.add(alloc, def_node) catch {};
                }
            },
            else => {},
        },
    }
}
