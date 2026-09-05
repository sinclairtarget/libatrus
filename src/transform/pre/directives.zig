const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../../ast.zig");
const atrus = @import("../../root.zig");
const myst = @import("../../myst/myst.zig");
const logger = @import("../../logging.zig").logger(.directives);
const util = @import("../../util/util.zig");

pub fn transform(
    alloc: Allocator,
    scratch: Allocator,
    original_node: *ast.Node,
) !*ast.Node {
    switch (original_node.allowedChildren()) {
        .yes => |branch_node| switch (branch_node) {
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

    if (std.mem.eql(u8, name, "code") or std.mem.eql(u8, name, "code-block")) {
        return try transformCode(alloc, scratch, node, args, options, value);
    }

    if (std.mem.eql(u8, name, "math")) {
        return try transformMath(alloc, scratch, node, options, value);
    }

    if (std.mem.eql(u8, name, "image")) {
        return try transformImage(alloc, node, args, options);
    }

    return try transformUnknown(alloc, node);
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

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, admonition_node);
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

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, container_node);
    return node;
}

fn transformCode(
    alloc: Allocator,
    scratch: Allocator,
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
        } else if (std.mem.eql(u8, opt.name, "number-lines") or
            std.mem.eql(u8, opt.name, "lineno-start"))
        {
            code_node.code.show_line_numbers = true;
            if (opt.value) |v| {
                if (myst.option_values.parseNumber(v)) |num| {
                    if (num > 1) {
                        code_node.code.starting_line_number = @intCast(num);
                    }
                } else |_| {
                    logger.warn(
                        "Invalid value for option \"number-lines\": {s}",
                        .{v},
                    );
                }
            }
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
        } else if (std.mem.eql(u8, opt.name, "class")) {
            if (opt.value) |v| {
                code_node.code.class = try alloc.dupeZ(u8, v);
            }
        } else if (std.mem.eql(u8, opt.name, "name")) {
            if (opt.value) |v| {
                code_node.code.label = try alloc.dupeZ(u8, v);
                const normalized = try myst.references.normalizeIdentifier(
                    scratch,
                    v,
                );
                code_node.code.identifier = try alloc.dupeZ(u8, normalized);
            }
        } else {
            logger.warn("Unknown code option \"{s}\"", .{opt.name});
        }
    }

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, code_node);
    return node;
}

/// Implements the {math} directive.
fn transformMath(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    const owned_value = try alloc.dupeZ(u8, value);
    errdefer alloc.free(owned_value);

    const math_node = try alloc.create(ast.Node);
    errdefer math_node.deinit(alloc);
    math_node.* = .{
        .math = .{
            .value = owned_value,
        },
    };

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "label")) {
            if (opt.value) |v| {
                math_node.math.label = try alloc.dupeZ(u8, v);
                const normalized = try myst.references.normalizeIdentifier(
                    scratch,
                    v,
                );
                math_node.math.identifier = try alloc.dupeZ(u8, normalized);
            }
        } else {
            logger.warn(
                "Unknown code option \"{s}\" on math node",
                .{opt.name},
            );
        }
    }

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, math_node);
    return node;
}

/// Implements the {image} directive.
fn transformImage(
    alloc: Allocator,
    node: *ast.Node,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
) !*ast.Node {
    const owned_url = try alloc.dupeZ(u8, args);
    errdefer alloc.free(owned_url);

    const image_node = try alloc.create(ast.Node);
    errdefer image_node.deinit(alloc);
    image_node.* = .{
        .image = .{
            .url = owned_url,
            .alt = "",
            .title = "",
        },
    };

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "alt")) {
            if (opt.value) |v| {
                image_node.image.alt = try alloc.dupeZ(u8, v);
            }
        } else if (std.mem.eql(u8, opt.name, "align")) {
            if (opt.value) |v| {
                image_node.image.@"align" = try alloc.dupeZ(u8, v);
            }
        } else if (std.mem.eql(u8, opt.name, "width")) {
            if (opt.value) |v| {
                image_node.image.width = try alloc.dupeZ(u8, v);
            }
        } else if (std.mem.eql(u8, opt.name, "class")) {
            if (opt.value) |v| {
                image_node.image.class = try alloc.dupeZ(u8, v);
            }
        }
    }

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, image_node);
    return node;
}

/// For directives we don't recognize, we have to partially "de-parse" the node
/// to conform with the MyST spec. The spec says that options should not be
/// parsed for directives we don't recognize.
///
/// Doing this here seems better than having to check a list of directive names
/// we support in the leaf block parser. The parser right now has the nice
/// property that it parses directives on a purely syntactic basis and leaves
/// interpreting the directive based on the directive name to subsequent
/// transforms.
fn transformUnknown(alloc: Allocator, node: *ast.Node) !*ast.Node {
    std.debug.assert(node.myst_directive.children.len == 0);

    var buf = Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    for (node.myst_directive.options) |opt| {
        _ = try buf.writer.print(":{s}:", .{opt.name});
        if (opt.value) |v| {
            _ = try buf.writer.print(" {s}", .{v});
        }
        _ = try buf.writer.write("\n");

        opt.deinit(alloc);
    }

    if (node.myst_directive.options.len > 0) {
        _ = try buf.writer.write("\n");
    }

    _ = try buf.writer.write(node.myst_directive.value);

    alloc.free(node.myst_directive.options);
    alloc.free(node.myst_directive.value);
    defer alloc.destroy(node);

    const replacement_value = try alloc.dupeZ(u8, buf.written());
    errdefer alloc.free(replacement_value);

    const replacement_node = try alloc.create(ast.Node);
    replacement_node.* = .{
        .myst_directive = .{
            .children = &.{},
            .name = node.myst_directive.name,
            .args = node.myst_directive.args,
            .options = &.{},
            .value = replacement_value,
        },
    };
    return replacement_node;
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

test "unknown directive with options" {
    const node = try handleDirective(
        "foobar",
        "",
        &.{
            .{ .name = "bim", .value = "zam" },
        },
        "squiggle",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(0, node.myst_directive.children.len);

    try testing.expectEqualStrings("foobar", node.myst_directive.name);
    try testing.expectEqual(0, node.myst_directive.options.len);
    try testing.expectEqualStrings(
        ":bim: zam\n\nsquiggle",
        node.myst_directive.value,
    );
}
