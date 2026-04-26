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
    switch (node.tag) {
        .root => {
            const n = node.payload.root;
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
        },
        .block => {
            const n = node.payload.block;
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
        },
        .blockquote => {
            const n = node.payload.blockquote;
            try out.print("<blockquote>\n", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
            try out.print("</blockquote>", .{});
        },
        .paragraph => {
            const n = node.payload.paragraph;
            try out.print("<p>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</p>", .{});
        },
        .heading => {
            const n = node.payload.heading;
            try out.print("<h{d}>", .{n.depth});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => {
            const n = node.payload.text;
            try printHTMLEscapedContent(out, std.mem.span(n.value));
        },
        .emphasis => {
            const n = node.payload.emphasis;
            try out.print("<em>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</em>", .{});
        },
        .strong => {
            const n = node.payload.strong;
            try out.print("<strong>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</strong>", .{});
        },
        .code => {
            const n = node.payload.code;
            const lang = std.mem.span(n.lang);
            if (lang.len > 0) {
                try out.print("<pre><code class=\"language-{s}\">", .{lang});
            } else {
                try out.print("<pre><code>", .{});
            }

            const value = std.mem.span(n.value);
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
        .inline_code => {
            const n = node.payload.inline_code;
            try out.print("<code>", .{});
            try printHTMLEscapedContent(out, std.mem.span(n.value));
            try out.print("</code>", .{});
        },
        .link => {
            const n = node.payload.link;
            try out.print("<a href=\"", .{});
            try printHTMLEscapedAttrValue(out, std.mem.span(n.url));
            try out.print("\"", .{});

            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\"", .{});
            }

            try out.print(">", .{});

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }

            try out.print("</a>", .{});
        },
        .image => {
            const n = node.payload.image;
            try out.print("<img src=\"", .{});
            try printHTMLEscapedAttrValue(out, std.mem.span(n.url));
            try out.print("\" ", .{});

            try out.print("alt=\"", .{});
            try printHTMLEscapedAttrValue(out, std.mem.span(n.alt));
            try out.print("\" ", .{});

            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try out.print("title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\" ", .{});
            }

            try out.print("/>", .{});
        },
        .html => {
            // Rendered verbatim, unescaped!
            const n = node.payload.html;
            try out.print("{s}", .{n.value});
        },
        // Doesn't get rendered
        .definition => return false,
        .container => {
            const n = node.payload.container;
            const kind = std.mem.span(n.kind);
            if (std.mem.eql(u8, kind, "figure")) {
                try renderFigure(out, node);
            } else {
                @panic("no HTML rendering implementation for  container kind");
            }
        },
        .myst_role => {
            const n = node.payload.myst_role;
            if (n.n_children == 0) {
                // unknown role
                try out.print("<span class=\"role unhandled\">", .{});

                _ = try out.write("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, std.mem.span(n.name));
                _ = try out.write("}</code>");

                try out.print("<code>", .{});
                try printHTMLEscapedContent(out, std.mem.span(n.value));
                try out.print("</code>", .{});

                try out.print("</span>", .{});
            } else {
                // implemented role
                const sliced = n.children[0..n.n_children];
                for (sliced) |child| {
                    _ = try renderNode(child, out);
                }
            }
        },
        .myst_role_error => {
            const n = node.payload.myst_role_error;
            try printHTMLEscapedContent(out, std.mem.span(n.value));
        },
        .subscript => {
            const n = node.payload.subscript;
            _ = try out.write("<sub>");

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</sub>");
        },
        .superscript => {
            const n = node.payload.superscript;
            _ = try out.write("<sup>");

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</sup>");
        },
        .abbreviation => {
            const n = node.payload.abbreviation;

            _ = try out.write("<abbr");
            const title = std.mem.span(n.title);
            if (title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, title);
                try out.print("\"", .{});
            }
            _ = try out.write(">");

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }

            _ = try out.write("</abbr>");
        },
        .myst_directive => {
            const n = node.payload.myst_directive;
            if (n.n_children == 0) {
                // unknown directive
                _ = try out.write("<div class=\"directive unhandled\">\n");

                _ = try out.write("  <p>");
                _ = try out.write("<code class=\"kind\">{");
                try printHTMLEscapedContent(out, std.mem.span(n.name));
                _ = try out.write("}</code>");

                const args = std.mem.span(n.args);
                if (args.len > 0) {
                    _ = try out.write("<code class=\"args\">");
                    try printHTMLEscapedContent(out, args);
                    _ = try out.write("</code>");
                }

                _ = try out.write("</p>\n");

                _ = try out.write("  <pre><code>");
                try printHTMLEscapedContent(out, std.mem.span(n.value));
                _ = try out.write("</code></pre>\n");

                _ = try out.write("</div>");
            } else {
                // implemented directive; this is just a wrapper
                const sliced = n.children[0..n.n_children];
                for (sliced) |child| {
                    _ = try renderNode(child, out);
                }
            }
        },
        .myst_directive_error => {
            const n = node.payload.myst_directive_error;

            _ = try out.write("<div>");
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            _ = try out.write("</div>");
        },
        .admonition => {
            const n = node.payload.admonition;

            _ = try out.write("<aside class=\"admonition");

            const kind = std.mem.span(n.kind);
            if (kind.len > 0) {
                try out.print(" {s}", .{kind});
            }
            _ = try out.write("\">\n");

            // If we don't have a child title, we must render one ourselves.
            // But only if we aren't a simple admonition.
            if (
                (n.n_children == 0 or n.children[0].tag != .admonition_title)
                and !std.mem.eql(u8, kind, "admonition")
            ) {
                _ = try out.write("  ");
                try renderAdmonitionTitle(out, kind);
                _ = try out.write("\n");
            }

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try out.write("  ");
                _ = try renderNode(child, out);
                _ = try out.write("\n");
            }
            _ = try out.write("</aside>");
        },
        .admonition_title => {
            const n = node.payload.admonition_title;

            _ = try out.write("<p class=\"admonition-title\">");
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
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
    std.debug.assert(node.tag == .container);

    const n = node.payload.container;
    _ = try out.write("<figure class=\"numbered\">");

    const sliced = n.children[0..n.n_children];
    for (sliced) |child| {
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
