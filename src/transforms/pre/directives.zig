const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Io = std.Io;

const ast = @import("../../ast.zig");
const atrus = @import("../../root.zig");
const myst = @import("../../myst/myst.zig");
const logger = @import("../../logging.zig").logger(.directives);
const util = @import("../../util/util.zig");
const InlineTokenizer = @import("../../lex/InlineTokenizer.zig");
const InlineParser = @import("../../parse/InlineParser.zig");

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
        return try transformAdmonition(
            alloc,
            node,
            name,
            args,
            options,
            value,
        );
    }

    if (std.mem.eql(u8, name, "figure")) {
        return try transformFigure(alloc, scratch, node, args, options, value);
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

    if (std.mem.eql(u8, name, "list-table")) {
        return try transformListTable(
            alloc,
            scratch,
            node,
            args,
            options,
            value,
        );
    }

    return try transformUnknown(alloc, node);
}

fn transformAdmonition(
    alloc: Allocator,
    node: *ast.Node,
    name: []const u8,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
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

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "class")) {
            if (opt.value) |v| {
                admonition_node.admonition.class = try alloc.dupeZ(u8, v);
            }
        }
    }

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, admonition_node);
    return node;
}

/// Implements the {figure} directive.
///
/// * The image URL for a figure is given as the argument to the directive.
/// * Alt text can be specified using an `alt` option.
/// * A label can be given using the `name` option.
/// * The body of the directive is used to create the caption and legend.
fn transformFigure(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    var children: ArrayList(*ast.Node) = .empty;

    if (args.len > 0) {
        const owned_url = try alloc.dupeZ(u8, std.mem.trim(u8, args, " \t"));
        errdefer alloc.free(owned_url);

        const owned_title = try alloc.dupeZ(u8, "");
        errdefer alloc.free(owned_title);

        const owned_alt = for (options) |opt| {
            if (std.mem.eql(u8, opt.name, "alt")) {
                if (opt.value) |v| {
                    break try alloc.dupeZ(u8, v);
                }
            }
        } else try alloc.dupeZ(u8, "");
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

    if (root.root.children.len > 0) {
        const caption_node = try alloc.create(ast.Node);
        errdefer alloc.destroy(caption_node);

        caption_node.* = .{
            .caption = .{
                .children = try alloc.dupe(
                    *ast.Node,
                    &.{root.root.children[0]},
                ),
            },
        };

        try children.append(alloc, caption_node);

        if (root.root.children.len > 1) {
            const legend_node = try alloc.create(ast.Node);
            errdefer alloc.destroy(legend_node);

            legend_node.* = .{
                .legend = .{
                    .children = try alloc.dupe(
                        *ast.Node,
                        root.root.children[1..],
                    ),
                },
            };

            try children.append(alloc, legend_node);
        }
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

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "name")) {
            if (opt.value) |v| {
                container_node.container.label = try alloc.dupeZ(u8, v);
                const normalized = try myst.references.normalizeIdentifier(
                    scratch,
                    v,
                );
                container_node.container.identifier = try alloc.dupeZ(
                    u8,
                    normalized,
                );
                container_node.container.enumerated = true;
            }
        }
    }

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

/// Implements the {list-table} directive.
///
/// This directive parses the contents of the directive block as MyST,
/// expecting it to contain a uniform two-level bullet list. ("Uniform" meaning
/// that each second-level list contains the same number of elements.)
fn transformListTable(
    alloc: Allocator,
    scratch: Allocator,
    node: *ast.Node,
    args: []const u8,
    options: []const ast.MySTDirective.Option,
    value: []const u8,
) !*ast.Node {
    // Parse directive contents as nested MyST Markdown document!
    var reader = Io.Reader.fixed(value);
    const root_node = try atrus.parse(
        alloc,
        &reader,
        .{ .parse_level = .pre },
    );

    if (root_node.root.children.len == 0) {
        defer root_node.deinit(alloc);
        defer node.deinit(alloc);
        return try createErrorNode(
            alloc,
            "required body not provided for directive: list-table",
        );
    }

    const table_dimensions = checkListDimensions(root_node) orelse {
        defer root_node.deinit(alloc);
        defer node.deinit(alloc);
        return try createErrorNode(
            alloc,
            "list not uniform for directive: list-table",
        );
    };

    // create caption
    const caption_node = try createCaptionNode(alloc, scratch, args);

    // create table
    var table_align: ?[]const u8 = null;
    var header_rows: std.DynamicBitSet = try .initEmpty(
        scratch,
        table_dimensions.rows,
    );
    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "align")) {
            if (opt.value) |v| {
                table_align = v;
            }
        }

        if (std.mem.eql(u8, opt.name, "header-rows")) {
            if (opt.value) |v| {
                const rows = try myst.option_values.parseCommaSeparatedRanges(
                    scratch,
                    v,
                ) orelse &.{};
                for (rows) |r| {
                    const zero_indexed = r - 1;
                    if (zero_indexed < header_rows.capacity())
                        header_rows.set(zero_indexed);
                }
            }
        }
    }

    const table_rows = try alloc.alloc(*ast.Node, table_dimensions.rows);
    const list_node = root_node.root.children[0];
    for (list_node.list.children, 0..) |list_item_node, row_i| {
        const sublist_node = list_item_node.list_item.children[0];
        table_rows[row_i] = try createTableRow(
            alloc,
            sublist_node,
            header_rows.isSet(row_i),
        );
    }

    const table_node = try alloc.create(ast.Node);
    table_node.* = .{
        .table = .{
            .@"align" = if (table_align) |a| try alloc.dupeZ(u8, a) else null,
            .children = table_rows,
        },
    };
    defer {
        freeUniformList(alloc, list_node);
        alloc.free(root_node.root.children);
        alloc.destroy(root_node);
    }

    // create container
    const container_node = try alloc.create(ast.Node);
    container_node.* = .{
        .container = .{
            .kind = try alloc.dupeZ(u8, "table"),
            .children = try alloc.dupe(*ast.Node, &.{
                caption_node,
                table_node,
            }),
        },
    };

    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "name")) {
            if (opt.value) |v| {
                container_node.container.label = try alloc.dupeZ(u8, v);
                const normalized = try myst.references.normalizeIdentifier(
                    scratch,
                    v,
                );
                container_node.container.identifier = try alloc.dupeZ(
                    u8,
                    normalized,
                );
                container_node.container.enumerated = true;
            }
        }

        if (std.mem.eql(u8, opt.name, "class")) {
            if (opt.value) |v| {
                container_node.container.class = try alloc.dupeZ(u8, v);
            }
        }
    }

    std.debug.assert(node.myst_directive.children.len == 0);
    try node.appendChild(alloc, container_node);

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

fn createErrorNode(alloc: Allocator, msg: []const u8) !*ast.Node {
    const owned_msg = try alloc.dupeZ(u8, msg);
    errdefer alloc.free(owned_msg);

    const owned_children = try alloc.dupe(*ast.Node, &.{});
    errdefer alloc.free(owned_children);

    const error_node = try alloc.create(ast.Node);
    error_node.* = .{
        .myst_directive_error = .{
            .children = owned_children,
            .message = owned_msg,
        },
    };
    return error_node;
}

const TableDimensions = struct { rows: usize, cols: usize };

/// Checks that the given AST contains a uniform list (and nothing else).
///
/// If the list is valid and uniform, returns the dimensions of the table it
/// will create. Otherwise returns null.
fn checkListDimensions(root_node: *ast.Node) ?TableDimensions {
    if (root_node.root.children.len != 1)
        return null;

    const list_node = root_node.root.children[0];
    if (@as(ast.NodeType, list_node.*) != .list)
        return null;

    const rows = list_node.list.children.len;
    var cols: ?usize = null;
    for (list_node.list.children) |list_item_node| {
        if (list_item_node.list_item.children.len != 1)
            return null;

        const sub_list_node = list_item_node.list_item.children[0];
        if (@as(ast.NodeType, sub_list_node.*) != .list)
            return null;

        cols = cols orelse sub_list_node.list.children.len;
        if (sub_list_node.list.children.len != cols)
            return null;
    }

    const dimensions: TableDimensions = .{
        .rows = rows,
        .cols = cols orelse return null,
    };
    return dimensions;
}

/// Creates a row of table cells from the children of the given list.
///
/// DOES NOT MAKE COPIES of any nodes in the input list.
fn createTableRow(
    alloc: Allocator,
    list_node: *ast.Node,
    is_header: bool,
) !*ast.Node {
    const n_cols = list_node.list.children.len;
    const cells = try alloc.alloc(*ast.Node, n_cols);
    for (list_node.list.children, 0..) |list_item_node, col_i| {
        const cell_children = try alloc.dupe(
            *ast.Node,
            list_item_node.list_item.children,
        );

        const cell_node = try alloc.create(ast.Node);
        cell_node.* = .{
            .table_cell = .{
                .header = is_header,
                .children = cell_children,
            },
        };
        cells[col_i] = cell_node;
    }

    const row = try alloc.create(ast.Node);
    row.* = .{
        .table_row = .{
            .children = cells,
        },
    };
    return row;
}

/// Frees all the nodes in the uniform list except the leaf content nodes.
fn freeUniformList(alloc: Allocator, list_node: *ast.Node) void {
    // TODO: Can we write non-recursive destroy() or deinit() methods on
    // ast.Node so that we don't have to know what to free here?

    for (list_node.list.children) |list_item_node| {
        const sublist_node = list_item_node.list_item.children[0];
        for (sublist_node.list.children) |sublist_item_node| {
            // We don't free any of the children, since they're now part of a
            // table.
            alloc.free(sublist_item_node.list_item.children);
            alloc.destroy(sublist_item_node);
        }

        alloc.free(sublist_node.list.children);
        alloc.destroy(sublist_node);
        alloc.free(list_item_node.list_item.children);
        alloc.destroy(list_item_node);
    }

    alloc.free(list_node.list.children);
    alloc.destroy(list_node);
}

// TODO: Move somewhere more sensible than here
fn createCaptionNode(
    alloc: Allocator,
    scratch: Allocator,
    caption_value: []const u8,
) !*ast.Node {
    var tokenizer = InlineTokenizer.init(caption_value);
    var parser = InlineParser.init(&tokenizer, .empty);
    const inline_nodes = try parser.parse(alloc, scratch);

    const p_node = try alloc.create(ast.Node);
    p_node.* = .{
        .paragraph = .{ .children = inline_nodes },
    };

    const caption_node = try alloc.create(ast.Node);
    caption_node.* = .{
        .caption = .{ .children = try alloc.dupe(*ast.Node, &.{p_node}) },
    };
    return caption_node;
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

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    return try transformBuiltin(
        testing.allocator,
        arena.allocator(),
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

    const caption_node = container_node.container.children[1];
    try testing.expectEqual(.caption, @as(ast.NodeType, caption_node.*));
    try testing.expectEqual(1, caption_node.caption.children.len);

    const p_node = caption_node.caption.children[0];
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

fn expectTableRow(row_node: *ast.Node, values: anytype) !void {
    try testing.expectEqual(.table_row, @as(ast.NodeType, row_node.*));
    try testing.expectEqual(values.len, row_node.table_row.children.len);

    inline for (values, 0..) |v, i| {
        const cell_node = row_node.table_row.children[i];
        try testing.expectEqual(.table_cell, @as(ast.NodeType, cell_node.*));
        try testing.expectEqual(1, cell_node.table_cell.children.len);

        const txt_node = cell_node.table_cell.children[0];
        try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
        try testing.expectEqualStrings(v, txt_node.text.value);
    }
}

test "list table uniform" {
    const node = try handleDirective("list-table", "My table", &.{},
        \\* - Name
        \\  - Weight (lbs.)
        \\* - John
        \\  - 189
        \\* - Sarah
        \\  - 153
        \\
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive, @as(ast.NodeType, node.*));
    try testing.expectEqual(1, node.myst_directive.children.len);

    const container_node = node.myst_directive.children[0];
    try testing.expectEqual(.container, @as(ast.NodeType, container_node.*));
    try testing.expectEqualStrings("table", container_node.container.kind);
    try testing.expectEqual(2, container_node.container.children.len);

    const caption_node = container_node.container.children[0];
    try testing.expectEqual(.caption, @as(ast.NodeType, caption_node.*));
    try testing.expectEqual(1, caption_node.caption.children.len);

    const p_node = caption_node.caption.children[0];
    try testing.expectEqual(.paragraph, @as(ast.NodeType, p_node.*));
    try testing.expectEqual(1, p_node.paragraph.children.len);

    const txt_node = p_node.paragraph.children[0];
    try testing.expectEqual(.text, @as(ast.NodeType, txt_node.*));
    try testing.expectEqualStrings("My table", txt_node.text.value);

    const table_node = container_node.container.children[1];
    try testing.expectEqual(.table, @as(ast.NodeType, table_node.*));
    try testing.expectEqual(3, table_node.table.children.len);

    try expectTableRow(
        table_node.table.children[0],
        .{ "Name", "Weight (lbs.)" },
    );
    try expectTableRow(
        table_node.table.children[1],
        .{ "John", "189" },
    );
    try expectTableRow(
        table_node.table.children[2],
        .{ "Sarah", "153" },
    );
}

test "empty list table" {
    const node = try handleDirective(
        "list-table",
        "My table",
        &.{},
        "",
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive_error, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "required body not provided for directive: list-table",
        node.myst_directive_error.message,
    );
}

test "invalid list table" {
    const node = try handleDirective("list-table", "My table", &.{},
        \\* - Name
        \\  - Weight (lbs.)
        \\* - John
        \\  - 189
        \\* - Sarah
        \\  - 153
        \\  - Spaghetti
        \\
    );
    defer node.deinit(testing.allocator);

    try testing.expectEqual(.myst_directive_error, @as(ast.NodeType, node.*));
    try testing.expectEqualStrings(
        "list not uniform for directive: list-table",
        node.myst_directive_error.message,
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
