const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

/// Renders the given AST as HTML.
///
/// The given AST node might be the root, but it might not. We support
/// rendering arbitrary subtrees of a complete MyST AST.
pub fn render(node: *ast.Node, out: *Io.Writer) Io.Writer.Error!void {
    _ = try renderNode(node, out);
    try out.flush();
}

/// Renders output, returning true if anything was written.
fn renderNode(node: *ast.Node, out: *Io.Writer) Io.Writer.Error!bool {
    switch (node.*) {
        .root => |n| {
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
        },
        .block => |n| {
            for (n.children) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
        },
        .blockquote => |n| {
            try out.print("<blockquote>\n", .{});
            for (n.children) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
            try out.print("</blockquote>", .{});
        },
        .paragraph => |n| {
            try out.print("<p>", .{});
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            try out.print("<h{d}>", .{n.depth});
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => |n| {
            try printHTMLEscapedContent(out, n.value);
        },
        .emphasis => |n| {
            try out.print("<em>", .{});
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</em>", .{});
        },
        .strong => |n| {
            try out.print("<strong>", .{});
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</strong>", .{});
        },
        .code => |n| {
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
            }

            try out.print("</code></pre>", .{});
        },
        .@"break" => {
            try out.print("<br />\n", .{});
        },
        .thematic_break => {
            try out.print("<hr />", .{});
        },
        .inline_code => |n| {
            try out.print("<code>", .{});
            try printHTMLEscapedContent(out, n.value);
            try out.print("</code>", .{});
        },
        .link => |n| {
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
                _ = try renderNode(child, out);
            }

            try out.print("</a>", .{});
        },
        .image => |n| {
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
            // Rendered verbatim, unescaped!
            try out.print("{s}", .{n.value});
        },
        // Doesn't get rendered
        .definition => return false,
        .container => |n| {
            const kind = n.kind;
            if (std.mem.eql(u8, kind, "figure")) {
                try renderFigure(out, node);
            } else {
                @panic("no HTML rendering implementation for  container kind");
            }
        },
        .caption => |n| {
            _ = try out.write("<figcaption>\n");
            for (n.children) |child| {
                _ = try out.write("  ");
                _ = try renderNode(child, out);
                _ = try out.write("\n");
            }
            _ = try out.write("</figcaption>");
        },
        .myst_role => |n| {
            if (n.children.len == 0) {
                // unknown role
                try out.print("<span class=\"role unhandled\">", .{});

                _ = try out.write("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, n.name);
                _ = try out.write("}</code>");

                try out.print("<code>", .{});
                try printHTMLEscapedContent(out, n.value);
                try out.print("</code>", .{});

                try out.print("</span>", .{});
            } else {
                // implemented role
                for (n.children) |child| {
                    _ = try renderNode(child, out);
                }
            }
        },
        .myst_role_error => |n| {
            try printHTMLEscapedContent(out, n.value);
        },
        .subscript => |n| {
            _ = try out.write("<sub>");

            for (n.children) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</sub>");
        },
        .superscript => |n| {
            _ = try out.write("<sup>");

            for (n.children) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</sup>");
        },
        .abbreviation => |n| {
            _ = try out.write("<abbr");
            const title = n.title;
            if (title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\"", .{});
            }
            _ = try out.write(">");

            for (n.children) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</abbr>");
        },
        .myst_directive => |n| {
            if (n.children.len == 0) {
                // unknown directive
                _ = try out.write("<div class=\"directive unhandled\">\n");

                _ = try out.write("  <p>");
                _ = try out.write("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, n.name);
                _ = try out.write("}</code>");

                const args = n.args;
                if (args.len > 0) {
                    _ = try out.write("<code class=\"args\">");
                    try printHTMLEscapedContent(out, args);
                    _ = try out.write("</code>");
                }

                _ = try out.write("</p>\n");

                _ = try out.write("  <pre><code>");
                try printHTMLEscapedContent(out, n.value);
                _ = try out.write("</code></pre>\n");

                _ = try out.write("</div>");
            } else {
                // implemented directive; this is just a wrapper
                for (n.children) |child| {
                    _ = try renderNode(child, out);
                }
            }
        },
        .myst_directive_error => |n| {
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            _ = try out.write("</div>");
        },
        .admonition => |n| {
            _ = try out.write("<aside class=\"admonition");

            const kind = n.kind;
            if (kind.len > 0) {
                try out.print(" {s}", .{kind});
            }
            _ = try out.write("\">\n");

            // If we don't have a child title, we must render one ourselves.
            // But only if we aren't a simple admonition.
            const have_title = (
                n.children.len == 0
                or @as(ast.NodeType, n.children[0].*) != .admonition_title
            );
            if (have_title and !std.mem.eql(u8, kind, "admonition")) {
                _ = try out.write("  ");
                try renderAdmonitionTitle(out, kind);
                _ = try out.write("\n");
            }

            for (n.children) |child| {
                _ = try out.write("  ");
                _ = try renderNode(child, out);
                _ = try out.write("\n");
            }
            _ = try out.write("</aside>");
        },
        .admonition_title => |n| {
            _ = try out.write("<p class=\"admonition-title\">");
            for (n.children) |child| {
                _ = try renderNode(child, out);
            }
            _ = try out.write("</p>");
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

fn renderFigure(out: *Io.Writer, node: *ast.Node) !void {
    _ = try out.write("<figure class=\"numbered\">\n");

    const n = node.container;
    for (n.children) |child| {
        _ = try renderNode(child, out);
    }
    _ = try out.write("</figure>");
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
            // Myst-spec tests seem to require escaping of double quotes but not
            // single quotes for text content.
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
