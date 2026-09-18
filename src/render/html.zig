//! HTML renderer.
//!
//! Some stylistic choices we stick to:
//! * Self-closing tags are always rendered with a closing forward-slash after
//!   a space, e.g. `<br />` or `<hr />`.

const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

const WhitespaceChoice = enum {
    indent_none,
    indent_2,
    indent_4,
};

pub const Options = struct {
    whitespace: WhitespaceChoice = .indent_none,
};

const InternalOptions = struct {
    whitespace: WhitespaceChoice = .indent_none,
    blacklist: []const ast.NodeType,
};

const FormattingState = struct {
    depth: u8,
    begin_line: bool,

    const start: FormattingState = .{ .depth = 0, .begin_line = true };
};

const RenderState = struct {
    // Used to ensure we render div elements for only the second and subsequent
    // blocks in the AST.
    have_seen_block: bool = false,
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
    var render_state: RenderState = .{};

    var rendered_anything = try renderNode(
        node,
        out,
        .{
            .whitespace = options.whitespace,
            .blacklist = &.{.footnote_definition},
        },
        .start,
        &render_state,
    );
    if (rendered_anything) {
        _ = try out.print("\n", .{}); // add trailing newline
    }

    if (@as(ast.NodeType, node.*) == .root) {
        // Only render footnotes if we are rendering a full tree.
        rendered_anything = try renderFootnotes(
            node,
            out,
            .{
                .whitespace = options.whitespace,
                .blacklist = &.{},
            },
            .start,
            &render_state,
        );
        if (rendered_anything) {
            _ = try out.print("\n", .{});
        }
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
    options: InternalOptions,
    f: FormattingState,
    r: *RenderState,
) Io.Writer.Error!bool {
    if (!willRenderAnything(node, options, r)) {
        return false;
    }

    switch (node.*) {
        // --- Blocks ---
        .root => |n| {
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
                    r,
                );
                rendered_anything = rendered_anything or rendered;
                if (rendered_anything and (i < n.children.len - 1 and
                    willRenderAnything(n.children[i + 1], options, r)))
                {
                    try out.print("\n", .{});
                }
            }
        },
        .block => |n| {
            // The first block in the AST doesn't get rendered, only its
            // children do.
            if (r.have_seen_block) {
                if (f.begin_line) {
                    try printIndent(out, options, f.depth);
                }

                try out.writeAll("<div class=\"block\"");
                if (n.meta.len > 0) {
                    try out.writeAll(" data-block=\"");
                    try printHTMLEscapedAttrValue(out, n.meta);
                    try out.writeAll("\"");
                }
                try out.writeAll(">\n");

                for (n.children) |child| {
                    if (try renderNode(
                        child,
                        out,
                        options,
                        .{
                            .depth = f.depth + 1,
                            .begin_line = true,
                        },
                        r,
                    )) {
                        try out.print("\n", .{});
                    }
                }
                try printIndent(out, options, f.depth);
                try out.print("</div>", .{});
            } else {
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
                        r,
                    );
                    rendered_anything = rendered_anything or rendered;
                    if (rendered_anything and (i < n.children.len - 1 and
                        willRenderAnything(n.children[i + 1], options, r)))
                    {
                        try out.print("\n", .{});
                    }
                }
            }

            r.have_seen_block = true;
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
                    r,
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
                    r,
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
                    r,
                );
            }
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

            _ = try out.writeAll("<pre><code");

            if (n.identifier) |identifier| {
                try out.print(" id=\"{s}\"", .{identifier});
            }

            if (n.lang.len > 0) {
                try out.print(" class=\"language-{s}", .{n.lang});
                if (n.class) |class| {
                    try out.print(" {s}", .{class});
                }
                _ = try out.writeAll("\"");
            } else if (n.class) |class| {
                try out.print(" class=\"{s}\"", .{class});
            }

            _ = try out.writeAll(">");

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
            if (std.mem.eql(u8, kind, "figure") or
                std.mem.eql(u8, kind, "table"))
            {
                try renderFigure(node, out, options, f, r);
            } else {
                @panic("no HTML rendering implementation for container kind");
            }
        },
        .caption => try renderCaption(node, out, options, f, r, null),
        .legend => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<div class=\"legend\">\n");
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                    r,
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</div>");
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
                    r,
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
                            r,
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
                            r,
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
                            r,
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
                            r,
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

                try printIndent(out, options, f.depth + 1);
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

                try printIndent(out, options, f.depth + 1);
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
                        r,
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
                    r,
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
            _ = try out.writeAll("<aside class=\"");
            if (n.class) |class| {
                try printHTMLEscapedAttrValue(out, class);
                _ = try out.writeAll(" ");
            }

            _ = try out.writeAll("admonition");

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
                    r,
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
                    r,
                );
            }
            _ = try out.writeAll("</p>");
        },
        .comment => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<!--");
            _ = try printEscapedComment(out, n.value);
            _ = try out.writeAll("-->");
        },
        .footnote_definition => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }

            _ = try out.writeAll("<li id=\"m-fn-");
            try printHTMLEscapedAttrValue(out, n.identifier);
            _ = try out.writeAll("\">\n");

            var rendered_back_link = false;
            for (n.children, 0..) |child, i| {
                if (i == n.children.len - 1 and
                    @as(ast.NodeType, child.*) == .paragraph)
                {
                    try printIndent(out, options, f.depth + 1);
                    _ = try out.writeAll("<p>");
                    for (child.paragraph.children) |grandchild| {
                        _ = try renderNode(
                            grandchild,
                            out,
                            options,
                            .{
                                .depth = f.depth + 1,
                                .begin_line = false,
                            },
                            r,
                        );
                    }

                    _ = try out.writeAll(" <a href=\"#m-fnref-");
                    try printHTMLEscapedAttrValue(out, n.identifier);
                    _ = try out.writeAll(
                        "\" data-footnote-backref " ++
                            "class=\"data-footnote-backref\" " ++
                            "aria-label=\"Back to content\">↩</a>",
                    );
                    _ = try out.writeAll("</p>");

                    rendered_back_link = true;
                } else {
                    _ = try renderNode(
                        child,
                        out,
                        options,
                        .{
                            .depth = f.depth + 1,
                            .begin_line = true,
                        },
                        r,
                    );
                }
                _ = try out.writeAll("\n");
            }

            if (!rendered_back_link) {
                try printIndent(out, options, f.depth + 1);
                _ = try out.writeAll("<a href=\"#m-fnref-");
                try printHTMLEscapedAttrValue(out, n.identifier);
                _ = try out.writeAll(
                    "\" data-footnote-backref " ++
                        "class=\"data-footnote-backref\" " ++
                        "aria-label=\"Back to content\">↩</a>",
                );
                _ = try out.writeAll("\n");
            }

            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</li>");
        },
        .table => try renderTable(node, out, options, f, r),
        .table_row => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            _ = try out.writeAll("<tr>\n");
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 1,
                        .begin_line = true,
                    },
                    r,
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth);
            _ = try out.writeAll("</tr>");
        },
        .table_cell => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            const tag = if (n.header) "th" else "td";
            try out.print("<{s}>", .{tag});
            for (n.children) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth,
                        .begin_line = false,
                    },
                    r,
                );
            }
            try out.print("</{s}>", .{tag});
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
                    r,
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
                    r,
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
                    r,
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

            if (n.@"align" != null or n.class != null) {
                _ = try out.writeAll("class=\"");
                if (n.@"align") |a| {
                    _ = try out.writeAll("align-");
                    try printHTMLEscapedAttrValue(out, a);

                    if (n.class) |_| {
                        _ = try out.writeAll(" ");
                    }
                }

                if (n.class) |class| {
                    try printHTMLEscapedAttrValue(out, class);
                }
                _ = try out.writeAll("\" ");
            }

            const title = n.title;
            if (title.len > 0) {
                try out.print("title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\" ", .{});
            }

            if (n.width) |width| {
                _ = try out.writeAll("width=\"");
                try printHTMLEscapedAttrValue(out, width);
                _ = try out.writeAll("\" ");
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
                        r,
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
                    r,
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
                    r,
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
                    r,
                );
            }

            _ = try out.writeAll("</abbr>");
        },
        .inline_math => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }
            try out.print("<span class=\"math-inline\">", .{});
            try printHTMLEscapedContent(out, n.value);
            try out.print("</span>", .{});
        },
        .math => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }

            _ = try out.writeAll("<div");

            if (n.identifier) |identifier| {
                // TODO: Escape attr value!
                try out.print(" id=\"{s}\"", .{identifier});
            }

            _ = try out.writeAll(" class=\"math-display\">");
            try printHTMLEscapedContent(out, n.value);
            _ = try out.writeAll("</div>");
        },
        .block_break => {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }

            _ = try out.writeAll("<div></div>");
        },
        .definition => {}, // Doesn't get rendered
        .footnote_reference => |n| {
            if (f.begin_line) {
                try printIndent(out, options, f.depth);
            }

            _ = try out.writeAll("<sup><a href=\"#m-fn-");
            try printHTMLEscapedAttrValue(out, n.identifier);
            _ = try out.writeAll("\" id=\"m-fnref-");
            try printHTMLEscapedAttrValue(out, n.identifier);
            _ = try out.writeAll(
                "\" data-footnote-ref aria-describedby=\"footnote-label\">",
            );
            try printHTMLEscapedContent(out, n.enumerator orelse n.identifier);
            try out.writeAll("</a></sup>");
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
    options: InternalOptions,
    f: FormattingState,
    r: *RenderState,
) !void {
    if (f.begin_line) {
        try printIndent(out, options, f.depth);
    }

    const n = node.container;
    _ = try out.writeAll("<figure ");
    if (n.identifier) |identifier| {
        _ = try out.writeAll("id=\"");
        try printHTMLEscapedAttrValue(out, identifier);
        _ = try out.writeAll("\" ");
    }

    const needs_class = n.enumerator != null or n.class != null;
    if (needs_class) {
        _ = try out.writeAll("class=\"");

        if (n.enumerator) |_| {
            _ = try out.writeAll("numbered");

            if (n.class) |_| {
                _ = try out.writeAll(" ");
            }
        }

        if (n.class) |class| {
            try printHTMLEscapedAttrValue(out, class);
        }

        _ = try out.writeAll("\"");
    }

    _ = try out.writeAll(">\n");

    for (n.children) |child| {
        switch (child.*) {
            .caption => try renderCaption(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 1,
                    .begin_line = true,
                },
                r,
                n,
            ),
            else => _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 1,
                    .begin_line = true,
                },
                r,
            ),
        }
        _ = try out.writeAll("\n");
    }

    try printIndent(out, options, f.depth);
    _ = try out.writeAll("</figure>");
}

fn renderCaption(
    node: *ast.Node,
    out: *Io.Writer,
    options: InternalOptions,
    f: FormattingState,
    r: *RenderState,
    container: ?ast.Container,
) !void {
    if (f.begin_line) {
        try printIndent(out, options, f.depth);
    }

    const n = node.caption;
    _ = try out.writeAll("<figcaption>\n");

    const shouldRenderEnumerated = container != null and
        container.?.enumerator != null and
        n.children.len > 0 and
        @as(ast.NodeType, n.children[0].*) == .paragraph;

    if (shouldRenderEnumerated) {
        try printIndent(out, options, f.depth + 1);

        _ = try out.writeAll("<p><span class=\"caption-number\">");
        try out.print("{s} ", .{containerKindName(container.?.kind)});
        try printHTMLEscapedContent(out, container.?.enumerator.?);
        _ = try out.writeAll("</span>");

        const paragraph = n.children[0].paragraph;
        for (paragraph.children) |child| {
            _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth,
                    .begin_line = false,
                },
                r,
            );
        }
        _ = try out.writeAll("</p>");
        _ = try out.writeAll("\n");

        for (n.children[1..]) |child| {
            _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 1,
                    .begin_line = true,
                },
                r,
            );
            _ = try out.writeAll("\n");
        }
    } else {
        for (n.children) |child| {
            _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 1,
                    .begin_line = true,
                },
                r,
            );
            _ = try out.writeAll("\n");
        }
    }

    try printIndent(out, options, f.depth);
    _ = try out.writeAll("</figcaption>");
}

fn renderTable(
    node: *ast.Node,
    out: *Io.Writer,
    options: InternalOptions,
    f: FormattingState,
    r: *RenderState,
) !void {
    const table = node.table;

    try printIndent(out, options, f.depth);
    _ = try out.writeAll("<table");
    if (table.@"align") |a| {
        _ = try out.writeAll(" align=\"");
        try printHTMLEscapedAttrValue(out, a);
        _ = try out.writeAll("\"");
    }
    _ = try out.writeAll(">\n");

    // TODO: Implement header-rows option
    if (table.children.len > 0) {
        try printIndent(out, options, f.depth + 1);
        _ = try out.writeAll("<thead>\n");
        for (table.children[0..1]) |child| {
            _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 2,
                    .begin_line = true,
                },
                r,
            );
            _ = try out.writeAll("\n");
        }
        try printIndent(out, options, f.depth + 1);
        _ = try out.writeAll("</thead>\n");

        if (table.children.len > 1) {
            try printIndent(out, options, f.depth + 1);
            _ = try out.writeAll("<tbody>\n");
            for (table.children[1..]) |child| {
                _ = try renderNode(
                    child,
                    out,
                    options,
                    .{
                        .depth = f.depth + 2,
                        .begin_line = true,
                    },
                    r,
                );
                _ = try out.writeAll("\n");
            }
            try printIndent(out, options, f.depth + 1);
            _ = try out.writeAll("</tbody>\n");
        }
    }

    try printIndent(out, options, f.depth);
    _ = try out.writeAll("</table>");
}

fn renderFootnotes(
    node: *ast.Node,
    out: *Io.Writer,
    options: InternalOptions,
    f: FormattingState,
    r: *RenderState,
) !bool {
    var num_footnotes: u32 = 0;
    for (node.root.children) |child| {
        if (@as(ast.NodeType, child.*) == .footnote_definition) {
            num_footnotes += 1;
        }
    }

    if (num_footnotes == 0) {
        return false;
    }

    _ = try out.writeAll("<section data-footnotes class=\"footnotes\">\n");

    try printIndent(out, options, f.depth + 1);
    _ = try out.writeAll(
        "<h2 id=\"footnote-label\" class=\"sr-only\">Footnotes</h2>\n",
    );

    try printIndent(out, options, f.depth + 1);
    _ = try out.writeAll("<ol>\n");

    for (node.root.children) |child| {
        if (@as(ast.NodeType, child.*) == .footnote_definition) {
            _ = try renderNode(
                child,
                out,
                options,
                .{
                    .depth = f.depth + 2,
                    .begin_line = true,
                },
                r,
            );
            _ = try out.writeAll("\n");
        }
    }

    try printIndent(out, options, f.depth + 1);
    _ = try out.writeAll("</ol>\n");
    _ = try out.writeAll("</section>");

    return true;
}

fn willRenderAnything(
    node: *const ast.Node,
    options: InternalOptions,
    r: *RenderState,
) bool {
    for (options.blacklist) |blacklisted_type| {
        if (@as(ast.NodeType, node.*) == blacklisted_type)
            return false;
    }

    return switch (node.*) {
        .definition => false,
        .block => |n| blk: {
            if (r.have_seen_block) {
                break :blk true;
            } else {
                break :blk for (n.children) |child| {
                    if (willRenderAnything(child, options, r)) {
                        break true;
                    }
                } else false;
            }
        },
        .root => |n| for (n.children) |child| {
            if (willRenderAnything(child, options, r)) {
                break true;
            }
        } else false,
        else => true,
    };
}

fn containerKindName(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "figure")) {
        return "Figure";
    } else if (std.mem.eql(u8, kind, "table")) {
        return "Table";
    }

    @panic("unknown container kind");
}

fn printEscapedComment(
    out: *Io.Writer,
    s: []const u8,
) Io.Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        if (i + 4 <= s.len and std.mem.eql(u8, s[i .. i + 4], "--!>")) {
            _ = try out.writeAll("--!&gt;");
            i += 4;
        } else if (i + 3 <= s.len and std.mem.eql(u8, s[i .. i + 3], "<!-")) {
            _ = try out.writeAll("&lt;!-");
            i += 3;
        } else if (i + 2 <= s.len and std.mem.eql(u8, s[i .. i + 2], "->")) {
            _ = try out.writeAll("-&gt;");
            i += 2;
        } else {
            _ = try out.writeByte(s[i]);
            i += 1;
        }
    }
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

fn printIndent(out: *Io.Writer, options: InternalOptions, depth: u8) !void {
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
        .block = .{
            .children = &.{},
            .meta = "",
        },
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

test "render comment escaping" {
    var comment_node: ast.Node = .{
        .comment = .{
            .value = "<!- -> <script> --> --!>",
        },
    };
    var root_node: ast.Node = blk: {
        var children = [_]*ast.Node{&comment_node};
        break :blk .{
            .root = .{ .children = &children },
        };
    };

    const expected =
        \\<!--&lt;!- -&gt; <script> --&gt; --!&gt;-->
        \\
    ;

    try renderAndCompare(&root_node, .{}, expected);
}

// Typically block breaks would not be in an AST sent to the HTML renderer
// (because they are stripped out in the POST transform stage). But if for some
// reason they are in the AST, we render them as empty divs.
test "render block break" {
    var block_break_node: ast.Node = .{
        .block_break = .{
            .meta = "foobar",
        },
    };
    var root_node: ast.Node = blk: {
        var children = [_]*ast.Node{&block_break_node};
        break :blk .{
            .root = .{ .children = &children },
        };
    };

    const expected =
        \\<div></div>
        \\
    ;

    try renderAndCompare(&root_node, .{}, expected);
}
