//! HTML renderer.
//!
//! Some stylistic choices we stick to:
//! * Self-closing tags are always rendered with a closing forward-slash after
//!   a space, e.g. `<br />` or `<hr />`.

const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

pub const Options = struct {
    whitespace: enum {
        indent_none,
        indent_2,
        indent_4,
    } = .indent_none,
};

const FormattingState = struct {
    depth: u8,
    begin_line: bool,

    const start: FormattingState = .{ .depth = 0, .begin_line = true };
};

/// Renders the given AST as HTML.
///
/// The given AST node might be the root, but it might not. We support
/// rendering arbitrary subtrees of a complete MyST AST.
pub fn render(
    node: *ast.Node,
    out: *Io.Writer,
    options: Options,
) Io.Writer.Error!void {
    if (try renderNode(node, out, options, .start)) {
        _ = try out.print("\n", .{}); // add trailing newline
    }
    try out.flush();
}

/// Renders output, returning true if anything was written (directly or by a
/// further child node).
///
/// Node is always rendered without a trailing newline.
fn renderNode(
    node: *ast.Node,
    out: *Io.Writer,
    options: Options,
    f: FormattingState,
) Io.Writer.Error!bool {
    if (!willRenderAnything(node)) {
        return false;
    }

    switch (node.*) {
        // --- Blocks ---
        inline .root, .block => |n| {
            var rendered_anything = false;
            for (n.children, 0..) |child, i| {
                const rendered = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = true,
                    },
                );
                rendered_anything = rendered_anything or rendered;
                if (rendered_anything and (i < n.children.len - 1 and
                    willRenderAnything(n.children[i + 1])))
                {
                    try out.print("\n", .{});
                }
            }
        },
        .blockquote => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<blockquote>\n", .{});
            for (n.children) |child| {
                if (try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                )) {
                    try out.print("\n", .{});
                }
            }
            try printIndent(out, options, f.depth);
            try out.print("</blockquote>", .{});
        },
        .paragraph => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<p>", .{});
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<h{d}>", .{n.depth});
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }
            try printIndent(out, options, f.depth);
            try out.print("</h{d}>", .{n.depth});
        },
        .thematic_break => {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<hr />", .{});
        },
        .code => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            const lang = n.lang;
            if (lang.len > 0) {
                try out.print("<pre><code class=\"language-{s}\">", .{lang});
            } else {
                try out.print("<pre><code>", .{});
            }

            const value = n.value;
            try printHTMLEscapedContent(out, value);
            if (value.len > 0) {
                try out.print("\n", .{});
                try printIndent(out, options, f.depth);
            }

            try out.print("</code></pre>", .{});
        },
        .container => |n| {
            const kind = n.kind;
            if (std.mem.eql(u8, kind, "figure")) {
                try renderFigure(node, out, options, f);
            } else {
                @panic("no HTML rendering implementation for container kind");
            }
        },
        .caption => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<figcaption>\n");
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</figcaption>");
        },
        .list => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            if (n.ordered) {
                if (n.start != 1) {
                    try out.print("<ol start=\"{d}\">\n", .{n.start});
                } else {
                    _ = try out.writeAll("<ol>\n");
                }
            } else {
                _ = try out.writeAll("<ul>\n");
            }

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                );
                _ = try out.writeAll("\n");
            }

            try printIndent(out, options, f.depth);
            if (n.ordered) {
                _ = try out.writeAll("</ol>");
            } else {
                _ = try out.writeAll("</ul>");
            }
        },
        .list_item => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            if (n.children.len > 0) {
                _ = try out.writeAll("<li>");

                // In the MyST 0.0.5 spec tests, "spread" is set
                // inconsistently. So we don't consult it here.
                const render_tight: bool = blk: {
                    if (n.children.len == 1 and
                        @as(ast.NodeType, n.children[0].*) == .text)
                    {
                        break :blk true;
                    }

                    break :blk false;
                };

                if (render_tight) {
                    for (n.children) |child| {
                        _ = try renderNode(
                            child,
                            out,
                            options,
                            .{
                                .depth = f.depth,
                                .begin_line = false,
                            },
                        );
                    }
                } else {
                    if (@as(ast.NodeType, n.children[0].*) == .text) {
                        // If the first child does not have an opening tag, put
                        // it on the same line as the <li>.
                        _ = try renderNode(
                            n.children[0],
                            out,
                            options,
                            .{
                                .depth = f.depth,
                                .begin_line = false,
                            },
                        );
                    } else {
                        _ = try out.writeAll("\n");
                        _ = try renderNode(
                            n.children[0],
                            out,
                            options,
                            .{
                                .depth = f.depth + 1,
                                .begin_line = true,
                            },
                        );
                    }
                    _ = try out.writeAll("\n");

                    var rendered = true;
                    for (n.children[1..], 1..) |child, i| {
                        rendered = try renderNode(
                            child,
                            out,
                            options,
                            .{
                                .depth = f.depth + 1,
                                .begin_line = true,
                            },
                        );

                        // Add newline as long as this isn't a last text child
                        if (rendered and (i < n.children.len - 1 or
                            @as(ast.NodeType, child.*) != .text))
                        {
                            _ = try out.writeAll("\n");
                        }
                    }
                    if (rendered) {
                        try printIndent(out, options, f.depth);
                    }
                }
                _ = try out.writeAll("</li>");
            } else {
                _ = try out.writeAll("<li></li>");
            }
        },
        .myst_directive => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            if (n.children.len == 0) {
                // unknown directive
                _ = try out.writeAll("<div class=\"directive unhandled\">\n");

                try printIndent(out, options, f.depth);
                _ = try out.writeAll("<p>");
                _ = try out.writeAll("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, n.name);
                _ = try out.writeAll("}</code>");

                const args = n.args;
                if (args.len > 0) {
                    _ = try out.writeAll("<code class=\"args\">");
                    try printHTMLEscapedContent(out, args);
                    _ = try out.writeAll("</code>");
                }

                _ = try out.writeAll("</p>\n");

                try printIndent(out, options, f.depth);
                _ = try out.writeAll("<pre><code>");
                try printHTMLEscapedContent(out, n.value);
                _ = try out.writeAll("</code></pre>\n");

                try printIndent(out, options, f.depth);
                _ = try out.writeAll("</div>");
            } else {
                // implemented directive; this is just a wrapper
                for (n.children) |child| {
                    _ = try renderNode(
                        child,
                        out,
                        options,
                        .{
                            .depth = f.depth,
                            .begin_line = true,
                        },
                    );
                }
            }
        },
        .myst_directive_error => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<div>");
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</div>");
        },
        .admonition => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<aside class=\"admonition");

            const kind = n.kind;
            if (kind.len > 0) {
                try out.print(" {s}", .{kind});
            }
            _ = try out.writeAll("\">\n");

            // If we don't have a child title, we must render one ourselves.
            // But only if we aren't a simple admonition.
            const missing_title = (n.children.len == 0 or
                @as(ast.NodeType, n.children[0].*) != .admonition_title);
            if (missing_title and !std.mem.eql(u8, kind, "admonition")) {
                try printIndent(out, options, f.depth + 1);
                try renderAdmonitionTitle(out, kind);
                _ = try out.writeAll("\n");
            }

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</aside>");
        },
        .admonition_title => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<p class=\"admonition-title\">");
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }
            _ = try out.writeAll("</p>");
        },
        // --- Inlines ---
        .text => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try printHTMLEscapedContent(out, n.value);
        },
        .emphasis => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<em>", .{});
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }
            try out.print("</em>", .{});
        },
        .strong => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<strong>", .{});
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }
            try out.print("</strong>", .{});
        },
        .@"break" => {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            // Break is always followed by a newline
            try out.print("<br />\n", .{});
        },
        .inline_code => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<code>", .{});
            try printHTMLEscapedContent(out, n.value);
            try out.print("</code>", .{});
        },
        .link => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<a href=\"", .{});
            try printHTMLEscapedAttrValue(out, n.url);
            try out.print("\"", .{});

            const title = n.title;
            if (title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\"", .{});
            }

            try out.print(">", .{});

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }

            try out.print("</a>", .{});
        },
        .image => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<img src=\"", .{});
            try printHTMLEscapedAttrValue(out, n.url);
            try out.print("\" ", .{});

            try out.print("alt=\"", .{});
            try printHTMLEscapedAttrValue(out, n.alt);
            try out.print("\" ", .{});

            const title = n.title;
            if (title.len > 0) {
                try out.print("title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\" ", .{});
            }

            try out.print("/>", .{});
        },
        .html => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            // Rendered verbatim, unescaped!
            try out.print("{s}", .{n.value});
        },
        .definition => {}, // Doesn't get rendered
        .myst_role => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            if (n.children.len == 0) {
                // unknown role
                try out.print("<span class=\"role unhandled\">", .{});

                _ = try out.writeAll("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, n.name);
                _ = try out.writeAll("}</code>");

                try out.print("<code>", .{});
                try printHTMLEscapedContent(out, n.value);
                try out.print("</code>", .{});

                try out.print("</span>", .{});
            } else {
                // implemented role
                for (n.children) |child| {
                    _ = try renderNode(
                        child,
                        out,
                        options,
                        .{
                            .depth = f.depth,
                            .begin_line = false,
                        },
                    );
                }
            }
        },
        .myst_role_error => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try printHTMLEscapedContent(out, n.value);
        },
        .subscript => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<sub>");

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }

            _ = try out.writeAll("</sub>");
        },
        .superscript => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<sup>");

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }

            _ = try out.writeAll("</sup>");
        },
        .abbreviation => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<abbr");
            const title = n.title;
            if (title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\"", .{});
            }
            _ = try out.writeAll(">");

            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                );
            }

            _ = try out.writeAll("</abbr>");
        },
    }

    return true;
}

/// Render an HTML admonition title based on the given admonition kind.
///
/// Unclear why the implementation of admonitions wouldn't just insert the
/// title into the tree at transform time instead of leaving the HTML renderer
/// to have this responsibility. But the MyST spec tests require that the title
/// is not in the AST but is in the HTML.
fn renderAdmonitionTitle(out: *Io.Writer, kind: []const u8) !void {
    const title = blk: {
        if (std.mem.eql(u8, kind, "attention")) {
            break :blk "Attention";
        } else if (std.mem.eql(u8, kind, "caution")) {
            break :blk "Caution";
        } else if (std.mem.eql(u8, kind, "danger")) {
            break :blk "Danger";
        } else if (std.mem.eql(u8, kind, "error")) {
            break :blk "Error";
        } else if (std.mem.eql(u8, kind, "hint")) {
            break :blk "Hint";
        } else if (std.mem.eql(u8, kind, "important")) {
            break :blk "Important";
        } else if (std.mem.eql(u8, kind, "note")) {
            break :blk "Note";
        } else if (std.mem.eql(u8, kind, "seealso")) {
            break :blk "See Also";
        } else if (std.mem.eql(u8, kind, "tip")) {
            break :blk "Tip";
        } else if (std.mem.eql(u8, kind, "warning")) {
            break :blk "Warning";
        } else {
            @panic("unknown admonition kind");
        }
    };
    try out.print("<p class=\"admonition-title\">{s}</p>", .{title});
}

fn renderFigure(
    node: *ast.Node,
    out: *Io.Writer,
    options: Options,
    f: FormattingState,
) !void {
    if (f.begin_line) {
        try printIndent(out, options, f.depth);
    }
    _ = try out.writeAll("<figure class=\"numbered\">\n");

    const n = node.container;
    for (n.children) |child| {
        _ = try renderNode(
            child,
            out,
            options,
            .{
                .depth = f.depth,
                .begin_line = false,
            },
        );
    }
    _ = try out.writeAll("</figure>");
}

fn willRenderAnything(node: *const ast.Node) bool {
    return switch (node.*) {
        .definition => false,
        inline .root, .block => |n| for (n.children) |child| {
            if (willRenderAnything(child)) {
                break true;
            }
        } else false,
        else => true,
    };
}

/// HTML-escape output to appear as text content.
fn printHTMLEscapedContent(
    out: *Io.Writer,
    s: []const u8,
) Io.Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '&' => try out.print("&amp;", .{}),
            '<' => try out.print("&lt;", .{}),
            '>' => try out.print("&gt;", .{}),
            // Myst-spec tests seem to require escaping of double quotes but
            // not single quotes for text content.
            '"' => try out.print("&quot;", .{}),
            else => try out.writeByte(c),
        }
    }
}

/// HTML-escape output to appear as an attribute value.
fn printHTMLEscapedAttrValue(
    out: *Io.Writer,
    s: []const u8,
) Io.Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '&' => try out.print("&amp;", .{}),
            '"' => try out.print("&quot;", .{}),
            '\'' => try out.print("&#39;", .{}),
            else => try out.writeByte(c),
        }
    }
}

fn printIndent(out: *Io.Writer, options: Options, depth: u8) !void {
    const whitespace = switch (options.whitespace) {
        .indent_none => "",
        .indent_2 => "  ",
        .indent_4 => "    ",
    };

    for (0..depth) |_| {
        try out.writeAll(whitespace);
    }
}

// ----------------------------------------------------------------------------
// Unit Tests
// ----------------------------------------------------------------------------
const testing = std.testing;

fn renderAndCompare(
    root: *ast.Node,
    options: Options,
    expected: []const u8,
) !void {
    var buf = Io.Writer.Allocating.init(testing.allocator);
    try render(root, &buf.writer, options);
    const result = try buf.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "emtpy ast" {
    var root_node: ast.Node = .{
        .root = .{ .children = &.{} },
    };
    try renderAndCompare(&root_node, .{}, "");

    var block_node: ast.Node = .{
        .block = .{ .children = &.{} },
    };
    var children = [_]*ast.Node{&block_node};
    root_node = .{
        .root = .{ .children = &children },
    };
    try renderAndCompare(&root_node, .{}, "");
}

test "render without indentation" {
    var text_node: ast.Node = .{
        .text = .{ .value = "This should be indented two levels." },
    };
    var p_node: ast.Node = blk: {
        var children = [_]*ast.Node{&text_node};
        break :blk .{
            .paragraph = .{ .children = &children },
        };
    };
    var inner_bq_node: ast.Node = blk: {
        var children = [_]*ast.Node{&p_node};
        break :blk .{
            .blockquote = .{ .children = &children },
        };
    };
    var outer_bq_node: ast.Node = blk: {
        var children = [_]*ast.Node{&inner_bq_node};
        break :blk .{
            .blockquote = .{ .children = &children },
        };
    };
    var root_node: ast.Node = blk: {
        var children = [_]*ast.Node{&outer_bq_node};
        break :blk .{
            .root = .{ .children = &children },
        };
    };

    const expected =
        \\<blockquote>
        \\<blockquote>
        \\<p>This should be indented two levels.</p>
        \\</blockquote>
        \\</blockquote>
        \\
    ;

    try renderAndCompare(&root_node, .{}, expected);
}

test "render with indentation" {
    var text_node: ast.Node = .{
        .text = .{ .value = "This should be indented two levels." },
    };
    var p_node: ast.Node = blk: {
        var children = [_]*ast.Node{&text_node};
        break :blk .{
            .paragraph = .{ .children = &children },
        };
    };
    var inner_bq_node: ast.Node = blk: {
        var children = [_]*ast.Node{&p_node};
        break :blk .{
            .blockquote = .{ .children = &children },
        };
    };
    var outer_bq_node: ast.Node = blk: {
        var children = [_]*ast.Node{&inner_bq_node};
        break :blk .{
            .blockquote = .{ .children = &children },
        };
    };
    var root_node: ast.Node = blk: {
        var children = [_]*ast.Node{&outer_bq_node};
        break :blk .{
            .root = .{ .children = &children },
        };
    };

    const expected =
        \\<blockquote>
        \\  <blockquote>
        \\    <p>This should be indented two levels.</p>
        \\  </blockquote>
        \\</blockquote>
        \\
    ;

    try renderAndCompare(&root_node, .{ .whitespace = .indent_2 }, expected);
}

test "render list with indentation" {
    var milk_text_node: ast.Node = .{
        .text = .{ .value = "Milk" },
    };
    var milk_li_node: ast.Node = blk: {
        var children = [_]*ast.Node{&milk_text_node};
        break :blk .{
            .list_item = .{ .children = &children, .spread = false },
        };
    };
    var juice_text_node: ast.Node = .{
        .text = .{ .value = "Juice" },
    };
    var juice_li_node: ast.Node = blk: {
        var children = [_]*ast.Node{&juice_text_node};
        break :blk .{
            .list_item = .{ .children = &children, .spread = false },
        };
    };
    var liquids_ul_node: ast.Node = blk: {
        var children = [_]*ast.Node{ &milk_li_node, &juice_li_node };
        break :blk .{
            .list = .{
                .children = &children,
                .spread = false,
                .ordered = false,
            },
        };
    };
    var liquids_text_node: ast.Node = .{
        .text = .{ .value = "Liquids" },
    };
    var liquids_li_node: ast.Node = blk: {
        var children = [_]*ast.Node{ &liquids_text_node, &liquids_ul_node };
        break :blk .{
            .list_item = .{ .children = &children, .spread = false },
        };
    };
    var eggs_text_node: ast.Node = .{
        .text = .{ .value = "Eggs" },
    };
    var eggs_li_node: ast.Node = blk: {
        var children = [_]*ast.Node{&eggs_text_node};
        break :blk .{
            .list_item = .{ .children = &children, .spread = false },
        };
    };
    var shopping_list_ul_node: ast.Node = blk: {
        var children = [_]*ast.Node{ &liquids_li_node, &eggs_li_node };
        break :blk .{
            .list = .{
                .children = &children,
                .spread = false,
                .ordered = false,
            },
        };
    };
    var root_node: ast.Node = blk: {
        var children = [_]*ast.Node{&shopping_list_ul_node};
        break :blk .{
            .root = .{ .children = &children },
        };
    };

    const expected =
        \\<ul>
        \\  <li>Liquids
        \\    <ul>
        \\      <li>Milk</li>
        \\      <li>Juice</li>
        \\    </ul>
        \\  </li>
        \\  <li>Eggs</li>
        \\</ul>
        \\
    ;

    try renderAndCompare(&root_node, .{ .whitespace = .indent_2 }, expected);
}
