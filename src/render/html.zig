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
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
        },
        .block => |n| {
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
        },
        .blockquote => |n| {
            try out.print("<blockquote>\n", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                if (try renderNode(child, out)) {
                    try out.print("\n", .{});
                }
            }
            try out.print("</blockquote>", .{});
        },
        .paragraph => |n| {
            try out.print("<p>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            try out.print("<h{d}>", .{n.depth});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => |n| {
            try printHTMLEscapedContent(out, std.mem.span(n.value));
        },
        .emphasis => |n| {
            try out.print("<em>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</em>", .{});
        },
        .strong => |n| {
            try out.print("<strong>", .{});
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                _ = try renderNode(child, out);
            }
            try out.print("</strong>", .{});
        },
        .code => |n| {
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
        .inline_code => |n| {
            try out.print("<code>", .{});
            try printHTMLEscapedContent(out, std.mem.span(n.value));
            try out.print("</code>", .{});
        },
        .link => |n| {
            try out.print("<a href=\"", .{});
            try printHTMLEscapedAttrValue(out, n.url);
            try out.print("\"", .{});

            if (n.title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, n.title);
                try out.print("\"", .{});
            }

            try out.print(">", .{});

            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
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

            if (n.title.len > 0) {
                try out.print("title=\"", .{});
                try printHTMLEscapedAttrValue(out, n.title);
                try out.print("\" ", .{});
            }

            try out.print("/>", .{});
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
