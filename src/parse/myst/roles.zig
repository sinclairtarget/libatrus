const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../../ast.zig");
const util = @import("../../util/util.zig");

pub fn isValidName(name: []const u8) bool {
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => {
                return false;
            },
        }
    }

    return true;
}

/// Implements all built-in MyST roles, e.g. "abbr", "sub", "sup", etc.
pub fn handleBuiltin(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    name: []const u8,
    value: []const u8,
) !*ast.Node {
    _ = scratch;

    if (std.mem.eql(u8, name, "sub") or std.mem.eql(u8, name, "subscript")) {
        return try handleSubscript(alloc, node, value);
    }

    return node;
}

/// Implements {sub} and {subscript}.
fn handleSubscript(
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
        .tag = .subscript,
        .payload = .{
            .subscript = .{
                .children = sub_children.ptr,
                .n_children = @intCast(sub_children.len),
            },
        },
    };

    const role_children = try alloc.dupe(*ast.Node, &.{sub_node});

    std.debug.assert(node.tag == .myst_role);
    std.debug.assert(node.payload.myst_role.n_children == 0);

    node.payload.myst_role.children = role_children.ptr;
    node.payload.myst_role.n_children = @intCast(role_children.len);

    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn parseBuiltin(name: []const u8, value: []const u8) !*ast.Node {
    const role_node = try testing.allocator.create(ast.Node);
    role_node.* = .{
        .tag = .myst_role,
        .payload = .{
            .myst_role = .{
                .name = try testing.allocator.dupeZ(u8, name),
                .value = try testing.allocator.dupeZ(u8, value),
                .children = &.{},
                .n_children = 0,
            },
        },
    };

    return try handleBuiltin(
        testing.allocator,
        testing.allocator,
        role_node,
        name,
        value,
    );
}

test "subscript short name" {
    const node = try parseBuiltin("sub", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(ast.NodeType.myst_role, node.tag);
    try testing.expectEqualStrings(
        "sub",
        std.mem.span(node.payload.myst_role.name),
    );
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(node.payload.myst_role.value),
    );

    try testing.expectEqual(1, node.payload.myst_role.n_children);

    const subscript_node = node.payload.myst_role.children[0];
    try testing.expectEqual(ast.NodeType.subscript, subscript_node.tag);

    try testing.expectEqual(1, subscript_node.payload.subscript.n_children);

    const text_node = subscript_node.payload.subscript.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(text_node.payload.text.value),
    );
}

test "subscript long name" {
    const node = try parseBuiltin("subscript", "foo");
    defer node.deinit(testing.allocator);

    try testing.expectEqual(ast.NodeType.myst_role, node.tag);
    try testing.expectEqualStrings(
        "subscript",
        std.mem.span(node.payload.myst_role.name),
    );
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(node.payload.myst_role.value),
    );

    try testing.expectEqual(1, node.payload.myst_role.n_children);

    const subscript_node = node.payload.myst_role.children[0];
    try testing.expectEqual(ast.NodeType.subscript, subscript_node.tag);

    try testing.expectEqual(1, subscript_node.payload.subscript.n_children);

    const text_node = subscript_node.payload.subscript.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "foo",
        std.mem.span(text_node.payload.text.value),
    );
}
