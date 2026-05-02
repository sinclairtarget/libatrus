const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../../ast.zig");
const atrus = @import("../../root.zig");
const util = @import("../../util/util.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.*) {
        .myst_directive => |n| {
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
                n.args,
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

/// Implements all built-in MyST directives, e.g. "admonition", "figure", etc.
fn transformBuiltin(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    name: []const u8,
    args: []const u8,
    value: []const u8,
) !*ast.Node {
    _ = scratch;

    if (
        std.mem.eql(u8, name, "admonition")
        or std.mem.eql(u8, name, "attention")
        or std.mem.eql(u8, name, "caution")
        or std.mem.eql(u8, name, "danger")
        or std.mem.eql(u8, name, "error")
        or std.mem.eql(u8, name, "hint")
        or std.mem.eql(u8, name, "important")
        or std.mem.eql(u8, name, "note")
        or std.mem.eql(u8, name, "seealso")
        or std.mem.eql(u8, name, "tip")
        or std.mem.eql(u8, name, "warning")
    ) {
        return try transformAdmonition(alloc, node, name, args, value);
    }

    if (std.mem.eql(u8, name, "figure")) {
        return try transformFigure(alloc, node, args, value);
    }

    return node;
}

fn transformAdmonition(
    alloc: Allocator,
    node: *ast.Node,
    name: []const u8,
    args: []const u8,
    value: []const u8,
) !*ast.Node {
    var children: ArrayList(*ast.Node) = .empty;

    if (args.len > 0) {
        // Handle args
        const text_node = try util.nodes.createTextNode(
            alloc,
            std.mem.trim(u8, args, " \t"),
        );
        errdefer text_node.deinit(alloc);

        if (value.len > 0) {
            // Args are used as title when there is a value
            const title_node = try alloc.create(ast.Node);
            errdefer alloc.destroy(title_node);

            const title_children = try alloc.dupe(*ast.Node, &.{text_node});
            errdefer alloc.free(title_children);

            title_node.* = .{
                .admonition_title = .{
                    .children = title_children,
                },
            };

            try children.append(alloc, title_node);
        } else {
            // Args are used as body otherwise
            const p_node = try alloc.create(ast.Node);
            errdefer alloc.destroy(p_node);

            const p_children = try alloc.dupe(*ast.Node, &.{text_node});
            errdefer alloc.free(p_children);

            p_node.* = .{
                .paragraph = .{
                    .children = p_children,
                },
            };

            try children.append(alloc, p_node);
        }
    }

    // Parse directive contents as nested MyST Markdown document!
    var reader = Io.Reader.fixed(value);
    const root = try atrus.parse(alloc, &reader, .{.parse_level = .pre});
    defer {
        alloc.free(root.root.children);
        alloc.destroy(root); // we don't need the root node
    }

    for (root.root.children) |child| {
        try children.append(alloc, child);
    }

    const owned_kind = blk: {
        if (!std.mem.eql(u8, name, "admonition")) {
            break :blk try alloc.dupeZ(u8, name);
        }

        break :blk try alloc.dupeZ(u8, "");
    };
    errdefer alloc.free(owned_kind);

    const admonition_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(admonition_node);

    const owned_children = try children.toOwnedSlice(alloc);
    errdefer alloc.free(owned_children);

    admonition_node.* = .{
        .admonition = .{
            .children = owned_children,
            .kind = owned_kind,
        },
    };

    const directive_children = try alloc.dupe(*ast.Node, &.{admonition_node});

    std.debug.assert(@as(ast.NodeType, node.*) == .myst_directive);
    std.debug.assert(node.myst_directive.children.len == 0);

    node.myst_directive.children = directive_children;
    return node;
}

fn transformFigure(
    alloc: Allocator,
    node: *ast.Node,
    args: []const u8,
    value: []const u8,
) !*ast.Node {
    var children: ArrayList(*ast.Node) = .empty;

    if (args.len > 0) {
        const owned_url = try alloc.dupeZ(u8, std.mem.trim(u8, args, " \t"));
        errdefer alloc.free(owned_url);

        const owned_title = try alloc.dupeZ(u8, "");
        errdefer alloc.free(owned_title);

        const owned_alt = try alloc.dupeZ(u8, "");
        errdefer alloc.free(owned_alt);

        const img_node = try alloc.create(ast.Node);
        errdefer alloc.destroy(img_node);

        img_node.* = .{
            .image = .{
                .url = owned_url,
                .title = owned_title,
                .alt = owned_alt,
            },
        };

        try children.append(alloc, img_node);
    }

    // Parse directive contents as nested MyST Markdown document!
    var reader = Io.Reader.fixed(value);
    const root = try atrus.parse(alloc, &reader, .{.parse_level = .pre});
    defer {
        alloc.free(root.root.children);
        alloc.destroy(root); // we don't need the root node
    }

    for (root.root.children) |child| {
        try children.append(alloc, child);
    }

    const owned_kind = try alloc.dupeZ(u8, "figure");
    errdefer alloc.free(owned_kind);

    const container_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(container_node);

    const owned_children = try children.toOwnedSlice(alloc);
    errdefer alloc.free(owned_children);

    container_node.* = .{
        .container = .{
            .children = owned_children,
            .kind = owned_kind,
        },
    };

    const directive_children = try alloc.dupe(*ast.Node, &.{container_node});

    std.debug.assert(@as(ast.NodeType, node.*) == .myst_directive);
    std.debug.assert(node.myst_directive.children.len == 0);

    node.myst_directive.children = directive_children;

    return node;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn handleDirective(
    name: []const u8,
    args: []const u8,
    value: []const u8,
) !*ast.Node {
    const directive_node = try testing.allocator.create(ast.Node);
    directive_node.* = .{
        .myst_directive = .{
            .name = try testing.allocator.dupeZ(u8, name),
            .args = try testing.allocator.dupeZ(u8, args),
            .value = try testing.allocator.dupeZ(u8, value),
            .children = &.{},
        },
    };

    return try transformBuiltin(
        testing.allocator,
        testing.allocator,
        directive_node,
        name,
        args,
        value,
    );
}

test "simple admonition" {
    const node = try handleDirective(
        "admonition",
        "This is a title",
        "This is a body",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const admonition_node = node.myst_directive.children[0];
    try testing.expectEqual(.admonition, @as(ast.NodeType, admonition_node.*));
    try testing.expectEqual(2, admonition_node.admonition.children.len);

    const title_node = admonition_node.admonition.children[0];
    try testing.expectEqual(.admonition_title, @as(ast.NodeType, title_node.*));
    try testing.expectEqual(1, title_node.admonition_title.children.len);

    const text_node = title_node.admonition_title.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "This is a title",
        text_node.text.value,
    );

    const p_node = admonition_node.admonition.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    try testing.expectEqual(1, p_node.paragraph.children.len);

    const text_node_2 = p_node.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node_2.*));
    try testing.expectEqualStrings(
        "This is a body",
        text_node_2.text.value,
    );
}

test "simple warning" {
    const node = try handleDirective(
        "warning",
        "This is a body",
        "",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const admonition_node = node.myst_directive.children[0];
    try testing.expectEqual(.admonition, @as(ast.NodeType, admonition_node.*));
    try testing.expectEqualStrings(
        "warning",
        admonition_node.admonition.kind,
    );
    try testing.expectEqual(1, admonition_node.admonition.children.len);

    const p_node = admonition_node.admonition.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    try testing.expectEqual(1, p_node.paragraph.children.len);

    const text_node_2 = p_node.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node_2.*));
    try testing.expectEqualStrings(
        "This is a body",
        text_node_2.text.value,
    );
}

test "simple figure" {
    const node = try handleDirective(
        "figure",
        "http://foo.com/cat.jpg",
        "This is a picture of my cat!",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const container_node = node.myst_directive.children[0];
    try testing.expectEqual(.container, @as(ast.NodeType, container_node.*));
    try testing.expectEqualStrings(
        "figure",
        container_node.container.kind,
    );
    try testing.expectEqual(2, container_node.container.children.len);

    const img_node = container_node.container.children[0];
    try testing.expectEqual(.image, @as(ast.NodeType, img_node.*));
    try testing.expectEqualStrings(
        "http://foo.com/cat.jpg",
        img_node.image.url,
    );

    const p_node = container_node.container.children[1];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    try testing.expectEqual(1, p_node.paragraph.children.len);

    const text_node = p_node.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, text_node.*));
    try testing.expectEqualStrings(
        "This is a picture of my cat!",
        text_node.text.value,
    );
}
