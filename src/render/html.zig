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
        // Doesn't get rendered
        .definition => return false,
    }

    return true;
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
