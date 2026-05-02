const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const util = @import("../../util/util.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.*) {
        .myst_role => |n| {
            // Check to see if we have already transformed this node. If so,
            // abort. This ensures the transform is idempotent.
            if (n.children.len > 0) {
                return original_node;
            }

            return try transformBuiltin(
                alloc,
                scratch,
                original_node,
                n.name,
                n.value,
            );
        },
        inline .root, .block, .heading, .paragraph, .emphasis, .strong,
        .link, .blockquote => |n| {
            for (0..n.children.len) |i| {
                n.children[i] = try transform(alloc, scratch, n.children[i]);
            }
            return original_node;
        },
        else => return original_node,
    }
}

/// Implements all built-in MyST roles, e.g. "abbr", "sub", "sup", etc.
fn transformBuiltin(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    name: []const u8,
    value: []const u8,
) !*ast.Node {
    _ = scratch;

    if (std.mem.eql(u8, name, "sub") or std.mem.eql(u8, name, "subscript")) {
        return try transformSubscript(alloc, node, value);
    } else if (
        std.mem.eql(u8, name, "sup") or std.mem.eql(u8, name, "superscript")
    ) {
        return try transformSuperscript(alloc, node, value);
    } else if (std.mem.eql(u8, name, "abbr")) {
        return try transformAbbreviation(alloc, node, value);
    }

    return node;
}

/// Implements {sub} and {subscript}.
fn transformSubscript(
    alloc: Allocator,
    node: *ast.Node,
    value: []const u8,
) !*ast.Node {
    const text_node = try util.nodes.createTextNode(alloc, value);
    errdefer text_node.deinit(alloc);

    const sub_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(sub_node);

    const sub_children = try alloc.dupe(*ast.Node, &.{text_node});
    errdefer alloc.free(sub_children);

    sub_node.* = .{
        .subscript = .{
            .children = sub_children,
        },
    };

    const role_children = try alloc.dupe(*ast.Node, &.{sub_node});

    std.debug.assert(@as(ast.NodeType, node.*) == .myst_role);
    std.debug.assert(node.myst_role.children.len == 0);

    node.myst_role.children = role_children;
    return node;
}

/// Implements {sup} and {superscript}.
fn transformSuperscript(
    alloc: Allocator,
    node: *ast.Node,
    value: []const u8,
) !*ast.Node {
    const text_node = try util.nodes.createTextNode(alloc, value);
    errdefer text_node.deinit(alloc);

    const sup_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(sup_node);

    const sup_children = try alloc.dupe(*ast.Node, &.{text_node});
    errdefer alloc.free(sup_children);

    sup_node.* = .{
        .superscript = .{
            .children = sup_children,
        },
    };

    const role_children = try alloc.dupe(*ast.Node, &.{sup_node});

    std.debug.assert(@as(ast.NodeType, node.*) == .myst_role);
    std.debug.assert(node.myst_role.children.len == 0);

    node.myst_role.children = role_children;
    return node;
}

/// Given a role value like "FOO (Foolish Ostrich Ogling)", returns an
/// abbreviation node with "Foolish Ostrich Ogling" as the title and "FOO" as
/// the value of a child text node.
///
/// The title is always the text between the last open parenthesis and the last
/// close parenthesis in the role value. If parentheses are mismatched then no
/// title is computed and the whole role value is used as for the child text
/// node.
fn transformAbbreviation(
    alloc: Allocator,
    node: *ast.Node,
    value: []const u8,
) !*ast.Node {
    // Search from back to get last occurence
    const open_i = std.mem.lastIndexOfScalar(u8, value, '(') orelse 0;
    const close_i = open_i + (
        std.mem.indexOfScalar(u8, value[open_i..], ')') orelse 0
    );

    const abbr_title = blk: {
        if (open_i == 0) {
            // No open paren or open bracket is first char; means no title
            break :blk "";
        }

        if (close_i <= open_i) {
            // No close paren after open paren; means no title
            break :blk "";
        }

        if (close_i < value.len - 1) {
            // Close paren not last char; means no title
            break :blk "";
        }

        break :blk std.mem.trim(u8, value[open_i + 1..close_i], " \t");
    };

    const abbr_value = blk: {
        if (abbr_title.len == 0) {
            // No title, so value is just entire string
            break :blk value;
        }

        break :blk std.mem.trim(u8, value[0..open_i], " \t");
    };

    const text_node = try util.nodes.createTextNode(alloc, abbr_value);
    errdefer text_node.deinit(alloc);

    const abbr_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(abbr_node);

    const abbr_children = try alloc.dupe(*ast.Node, &.{text_node});
    errdefer alloc.free(abbr_children);

    const owned_abbr_title = try alloc.dupeZ(u8, abbr_title);
    errdefer alloc.free(owned_abbr_title);

    abbr_node.* = .{
        .abbreviation = .{
            .children = abbr_children,
            .title = owned_abbr_title,
        },
    };

    const role_children = try alloc.dupe(*ast.Node, &.{abbr_node});

    std.debug.assert(@as(ast.NodeType, node.*) == .myst_role);
    std.debug.assert(node.myst_role.children.len == 0);

    node.myst_role.children = role_children;
    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn handleRole(name: []const u8, value: []const u8) !*ast.Node {
    const role_node = try testing.allocator.create(ast.Node);
    role_node.* = .{
        .myst_role = .{
            .name = try testing.allocator.dupeZ(u8, name),
            .value = try testing.allocator.dupeZ(u8, value),
            .children = &.{},
        },
    };

    return try transformBuiltin(
        testing.allocator,
        testing.allocator,
        role_node,
        name,
        value,
    );
}

test "subscript short name" {
    const node = try handleRole("sub", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "sub",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "foo",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const subscript_node = node.myst_role.children[0];
    try testing.expectEqual(.subscript, @as(ast.NodeType, subscript_node.*));

    try testing.expectEqual(1, subscript_node.subscript.children.len);

    const text_node = subscript_node.subscript.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "foo",
        text_node.text.value,
    );
}

test "subscript long name" {
    const node = try handleRole("subscript", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "subscript",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "foo",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const subscript_node = node.myst_role.children[0];
    try testing.expectEqual(.subscript, @as(ast.NodeType, subscript_node.*));

    try testing.expectEqual(1, subscript_node.subscript.children.len);

    const text_node = subscript_node.subscript.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "foo",
        text_node.text.value,
    );
}

test "superscript short name" {
    const node = try handleRole("sup", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "sup",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "foo",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const superscript_node = node.myst_role.children[0];
    try testing.expectEqual(.superscript, @as(ast.NodeType, superscript_node.*));

    try testing.expectEqual(1, superscript_node.superscript.children.len);

    const text_node = superscript_node.superscript.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "foo",
        text_node.text.value,
    );
}

test "superscript long name" {
    const node = try handleRole("superscript", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "superscript",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "foo",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const superscript_node = node.myst_role.children[0];
    try testing.expectEqual(.superscript, @as(ast.NodeType, superscript_node.*));

    try testing.expectEqual(1, superscript_node.superscript.children.len);

    const text_node = superscript_node.superscript.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "foo",
        text_node.text.value,
    );
}

test "abbr" {
    const node = try handleRole("abbr", "MyST (Markedly Structured Text)");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "abbr",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "MyST (Markedly Structured Text)",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const abbr_node = node.myst_role.children[0];
    try testing.expectEqual(.abbreviation, @as(ast.NodeType, abbr_node.*));
    try testing.expectEqualStrings(
        "Markedly Structured Text",
        abbr_node.abbreviation.title,
    );

    try testing.expectEqual(1, abbr_node.abbreviation.children.len);

    const text_node = abbr_node.abbreviation.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "MyST",
        text_node.text.value,
    );
}

test "bad abbr" {
    const node = try handleRole("abbr", "MyST (Markedly Structured Text");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "abbr",
        node.myst_role.name,
    );
    try testing.expectEqualStrings(
        "MyST (Markedly Structured Text",
        node.myst_role.value,
    );

    try testing.expectEqual(1, node.myst_role.children.len);

    const abbr_node = node.myst_role.children[0];
    try testing.expectEqual(.abbreviation, @as(ast.NodeType, abbr_node.*));
    try testing.expectEqualStrings(
        "",
        abbr_node.abbreviation.title,
    );

    try testing.expectEqual(1, abbr_node.abbreviation.children.len);

    const text_node = abbr_node.abbreviation.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "MyST (Markedly Structured Text",
        text_node.text.value,
    );
}

test "role transform is idempotent" {
    const node = try handleRole("abbr", "MyST (Markedly Structured Text)");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_role, @as(ast.NodeType, node.*));

    const retransformed_node = try transform(
        testing.allocator,
        testing.allocator,
        node,
    );

    try testing.expectEqual(.myst_role, @as(ast.NodeType, retransformed_node.*));

    try testing.expectEqual(
        node.myst_role.children.len,
        retransformed_node.myst_role.children.len,
    );
    try testing.expectEqualStrings(
        node.myst_role.name,
        retransformed_node.myst_role.name,
    );
    try testing.expectEqualStrings(
        node.myst_role.value,
        retransformed_node.myst_role.value,
    );
}
