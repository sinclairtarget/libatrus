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
    switch (original_node.tag) {
        .myst_directive => {
            const n = original_node.payload.myst_directive;

            // Check to see if we have already transformed this node. If so,
            // abort. This ensures the transform is idempotent.
            if (n.n_children > 0) {
                return original_node;
            }

            return try transformBuiltin(
                alloc,
                scratch,
                original_node,
                std.mem.span(n.name),
                std.mem.span(n.args),
                std.mem.span(n.value),
            );
        },
        inline .root, .block, .heading, .paragraph, .emphasis, .strong,
        .link, .blockquote => |node_type| {
            const n = @field(original_node.payload, @tagName(node_type));
            for (0..n.n_children) |i| {
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
                .tag = .admonition_title,
                .payload = .{
                    .admonition_title = .{
                        .children = title_children.ptr,
                        .n_children = @intCast(title_children.len),
                    },
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
                .tag = .paragraph,
                .payload = .{
                    .paragraph = .{
                        .children = p_children.ptr,
                        .n_children = @intCast(p_children.len),
                    },
                },
            };

            try children.append(alloc, p_node);
        }
    }

    // Parse directive contents as nested MyST Markdown document!
    var reader = Io.Reader.fixed(value);
    const root = try atrus.parse(alloc, &reader, .{.parse_level = .pre});
    defer {
        alloc.free(
            root.payload.root.children[0..root.payload.root.n_children],
        );
        alloc.destroy(root); // we don't need the root node
    }

    for (root.payload.root.children[0..root.payload.root.n_children]) |child| {
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
        .tag = .admonition,
        .payload = .{
            .admonition = .{
                .children = owned_children.ptr,
                .n_children = @intCast(owned_children.len),
                .kind = owned_kind,
            },
        },
    };

    const directive_children = try alloc.dupe(*ast.Node, &.{admonition_node});

    std.debug.assert(node.tag == .myst_directive);
    std.debug.assert(node.payload.myst_directive.n_children == 0);

    node.payload.myst_directive.children = directive_children.ptr;
    node.payload.myst_directive.n_children = @intCast(directive_children.len);

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
            .tag = .image,
            .payload = .{
                .image = .{
                    .url = owned_url,
                    .title = owned_title,
                    .alt = owned_alt,
                },
            },
        };

        try children.append(alloc, img_node);
    }

    // Parse directive contents as nested MyST Markdown document!
    var reader = Io.Reader.fixed(value);
    const root = try atrus.parse(alloc, &reader, .{.parse_level = .pre});
    defer {
        alloc.free(
            root.payload.root.children[0..root.payload.root.n_children],
        );
        alloc.destroy(root); // we don't need the root node
    }

    for (root.payload.root.children[0..root.payload.root.n_children]) |child| {
        try children.append(alloc, child);
    }

    const owned_kind = try alloc.dupeZ(u8, "figure");
    errdefer alloc.free(owned_kind);

    const container_node = try alloc.create(ast.Node);
    errdefer alloc.destroy(container_node);

    const owned_children = try children.toOwnedSlice(alloc);
    errdefer alloc.free(owned_children);

    container_node.* = .{
        .tag = .container,
        .payload = .{
            .container = .{
                .children = owned_children.ptr,
                .n_children = @intCast(owned_children.len),
                .kind = owned_kind,
            },
        },
    };

    const directive_children = try alloc.dupe(*ast.Node, &.{container_node});

    std.debug.assert(node.tag == .myst_directive);
    std.debug.assert(node.payload.myst_directive.n_children == 0);

    node.payload.myst_directive.children = directive_children.ptr;
    node.payload.myst_directive.n_children = @intCast(directive_children.len);

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
        .tag = .myst_directive,
        .payload = .{
            .myst_directive = .{
                .name = try testing.allocator.dupeZ(u8, name),
                .args = try testing.allocator.dupeZ(u8, args),
                .value = try testing.allocator.dupeZ(u8, value),
                .children = &.{},
                .n_children = 0,
            },
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

    try testing.expectEqual(ast.NodeType.myst_directive, node.tag);
    try testing.expectEqual(1, node.payload.myst_directive.n_children);

    const admonition_node = node.payload.myst_directive.children[0];
    try testing.expectEqual(ast.NodeType.admonition, admonition_node.tag);
    try testing.expectEqual(2, admonition_node.payload.admonition.n_children);

    const title_node = admonition_node.payload.admonition.children[0];
    try testing.expectEqual(ast.NodeType.admonition_title, title_node.tag);
    try testing.expectEqual(1, title_node.payload.admonition_title.n_children);

    const text_node = title_node.payload.admonition_title.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "This is a title",
        std.mem.span(text_node.payload.text.value),
    );

    const p_node = admonition_node.payload.admonition.children[1];
    try testing.expectEqual(ast.NodeType.paragraph, p_node.tag);
    try testing.expectEqual(1, p_node.payload.paragraph.n_children);

    const text_node_2 = p_node.payload.paragraph.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node_2.tag);
    try testing.expectEqualStrings(
        "This is a body",
        std.mem.span(text_node_2.payload.text.value),
    );
}

test "simple warning" {
    const node = try handleDirective(
        "warning",
        "This is a body",
        "",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(ast.NodeType.myst_directive, node.tag);
    try testing.expectEqual(1, node.payload.myst_directive.n_children);

    const admonition_node = node.payload.myst_directive.children[0];
    try testing.expectEqual(ast.NodeType.admonition, admonition_node.tag);
    try testing.expectEqualStrings(
        "warning",
        std.mem.span(node.payload.admonition.kind),
    );
    try testing.expectEqual(1, admonition_node.payload.admonition.n_children);

    const p_node = admonition_node.payload.admonition.children[0];
    try testing.expectEqual(ast.NodeType.paragraph, p_node.tag);
    try testing.expectEqual(1, p_node.payload.paragraph.n_children);

    const text_node_2 = p_node.payload.paragraph.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node_2.tag);
    try testing.expectEqualStrings(
        "This is a body",
        std.mem.span(text_node_2.payload.text.value),
    );
}

test "simple figure" {
    const node = try handleDirective(
        "figure",
        "http://foo.com/cat.jpg",
        "This is a picture of my cat!",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(ast.NodeType.myst_directive, node.tag);
    try testing.expectEqual(1, node.payload.myst_directive.n_children);

    const container_node = node.payload.myst_directive.children[0];
    try testing.expectEqual(ast.NodeType.container, container_node.tag);
    try testing.expectEqualStrings(
        "figure",
        std.mem.span(container_node.payload.container.kind),
    );
    try testing.expectEqual(2, container_node.payload.container.n_children);

    const img_node = container_node.payload.container.children[0];
    try testing.expectEqual(ast.NodeType.image, img_node.tag);
    try testing.expectEqualStrings(
        "http://foo.com/cat.jpg",
        std.mem.span(img_node.payload.image.url),
    );

    const p_node = container_node.payload.container.children[1];
    try testing.expectEqual(ast.NodeType.paragraph, p_node.tag);
    try testing.expectEqual(1, p_node.payload.paragraph.n_children);

    const text_node = p_node.payload.paragraph.children[0];
    try testing.expectEqual(ast.NodeType.text, text_node.tag);
    try testing.expectEqualStrings(
        "This is a picture of my cat!",
        std.mem.span(text_node.payload.text.value),
    );
}
