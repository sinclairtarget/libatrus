const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../../ast.zig");
const atrus = @import("../../root.zig");
const myst = @import("../../myst/myst.zig");
const logger = @import("../../logging.zig").logger;
const util = @import("../../util/util.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |leaf_node| switch (leaf_node) {
            .myst_directive => |n| {
                // Check to see if we have already transformed this node. If
                // so, abort. This ensures the transform is idempotent.
                if (n.children.len > 0) {
                    return original_node;
                }

                return try transformBuiltin(
                    alloc,
                    scratch,
                    original_node,
                    n.name,
                    n.args,
                    n.options,
                    n.value,
                );
            },
            inline else => |n| {
                for (0..n.children.len) |i| {
                    n.children[i] = try transform(
                        alloc,
                        scratch,
                        n.children[i],
                    );
                }
                return original_node;
            },
        },
        .no => return original_node, // Nothing to do.
    }
}

/// Implements all built-in MyST directives, e.g. "admonition", "figure", etc.
fn transformBuiltin(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    name: []const u8,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    _ = scratch;

    if (std.mem.eql(u8, name, "admonition") or
        std.mem.eql(u8, name, "attention") or
        std.mem.eql(u8, name, "caution") or
        std.mem.eql(u8, name, "danger") or
        std.mem.eql(u8, name, "error") or
        std.mem.eql(u8, name, "hint") or
        std.mem.eql(u8, name, "important") or
        std.mem.eql(u8, name, "note") or
        std.mem.eql(u8, name, "seealso") or
        std.mem.eql(u8, name, "tip") or
        std.mem.eql(u8, name, "warning"))
    {
        return try transformAdmonition(alloc, node, name, args, value);
    }

    if (std.mem.eql(u8, name, "figure")) {
        return try transformFigure(alloc, node, args, value);
    }

    if (std.mem.eql(u8, name, "code")) {
        return try transformCode(alloc, node, args, options, value);
    }

    if (std.mem.eql(u8, name, "deprecated-unsafe-html")) {
        return try transformUnsafeHTML(alloc, node, value);
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
    const root = try atrus.parse(alloc, &reader, .{ .parse_level = .pre });
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

    try setDirectiveChild(alloc, node, admonition_node);
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
    const root = try atrus.parse(alloc, &reader, .{ .parse_level = .pre });
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

    try setDirectiveChild(alloc, node, container_node);
    return node;
}

fn transformCode(
    alloc: Allocator,
    node: *ast.Node,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    const owned_lang = try alloc.dupeZ(u8, args);
    errdefer alloc.free(owned_lang);

    const owned_value = try alloc.dupeZ(u8, value);
    errdefer alloc.free(owned_value);

    const code_node = try alloc.create(ast.Node);
    errdefer code_node.deinit(alloc);
    code_node.* = .{
        .code = .{
            .lang = owned_lang,
            .value = owned_value,
        },
    };

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "linenos")) {
            code_node.code.show_line_numbers = true;
        } else if (std.mem.eql(u8, opt.name, "filename")) {
            if (opt.value) |v| {
                code_node.code.filename = try alloc.dupeZ(u8, v);
            }
        } else if (std.mem.eql(u8, opt.name, "emphasize-lines")) {
            if (opt.value) |v| {
                const lines = try myst.option_values.parseCommaSeparatedRanges(
                    alloc,
                    v,
                );
                code_node.code.emphasize_lines = lines;
            }
        } else {
            logger.warn("Unknown code option \"{s}\"", .{opt.name});
        }
    }

    try setDirectiveChild(alloc, node, code_node);
    return node;
}

/// Allows inserting an HTML node into the AST with content from a raw HTML
/// string.
///
/// TODO: Remove.
fn transformUnsafeHTML(
    alloc: Allocator,
    node: *ast.Node,
    value: []const u8,
) !*ast.Node {
    const owned_value = try alloc.dupeZ(u8, value);
    errdefer alloc.free(owned_value);

    const html_node = try alloc.create(ast.Node);
    html_node.* = .{
        .html = .{
            .value = owned_value,
        },
    };

    try setDirectiveChild(alloc, node, html_node);
    return node;
}

fn setDirectiveChild(
    alloc: Allocator,
    directive_node: *ast.Node,
    new_child_node: *ast.Node,
) !void {
    std.debug.assert(directive_node.myst_directive.children.len == 0);
    const directive_children = try alloc.dupe(*ast.Node, &.{new_child_node});
    directive_node.myst_directive.children = directive_children;
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn handleDirective(
    name: []const u8,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    // We need to create a node on the heap so that we can later deinit() it
    // and any children that might have been added to it.
    const owned_options = try testing.allocator.alloc(
        ast.MySTDirective.Option,
        options.len,
    );
    for (options, 0..) |opt, i| {
        owned_options[i] = .{
            .name = try testing.allocator.dupeZ(u8, opt.name),
            .value = if (opt.value) |v|
                try testing.allocator.dupeZ(u8, v)
            else
                null,
        };
    }

    const directive_node = try testing.allocator.create(ast.Node);
    directive_node.* = .{
        .myst_directive = .{
            .name = try testing.allocator.dupeZ(u8, name),
            .args = try testing.allocator.dupeZ(u8, args),
            .options = owned_options,
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
        options,
        value,
    );
}

test "simple admonition" {
    const node = try handleDirective(
        "admonition",
        "This is a title",
        &.{},
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
        &.{},
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
        &.{},
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

test "simple code block" {
    const node = try handleDirective(
        "code",
        "python",
        &.{},
        "def foo():\n    pass",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const code_node = node.myst_directive.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings("python", code_node.code.lang);
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );

    try testing.expectEqual(false, code_node.code.show_line_numbers);
}

test "code block with options" {
    const node = try handleDirective(
        "code",
        "python",
        &.{
            .{ .name = "linenos" },
            .{ .name = "filename", .value = "foobar.zig" },
            .{ .name = "emphasize-lines", .value = "1, 3-5, 7" },
        },
        "def foo():\n    pass",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const code_node = node.myst_directive.children[0];
    try testing.expectEqual(.code, @as(ast.NodeType, code_node.*));
    try testing.expectEqualStrings("python", code_node.code.lang);
    try testing.expectEqualStrings(
        "def foo():\n    pass",
        code_node.code.value,
    );

    try testing.expectEqual(true, code_node.code.show_line_numbers);
    try testing.expectEqualStrings("foobar.zig", code_node.code.filename.?);
    try testing.expectEqualSlices(
        u16,
        &.{ 1, 3, 4, 5, 7 },
        code_node.code.emphasize_lines.?,
    );
}
