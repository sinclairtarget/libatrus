const std = @import("std");
const Io = std.Io;

const ast = @import("../parse/ast.zig");

pub fn render(
    root: *ast.Node,
    out: *Io.Writer,
) Io.Writer.Error!void {
    _ = try renderNode(out, root);
    try out.flush();
}

/// Renders output, returning true if anything was written.
fn renderNode(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!bool {
    switch (node.*) {
        .root => |n| {
            for (n.children) |child| {
                _ = try renderNode(out, child);
            }
        },
        .block => |n| {
            for (n.children) |child| {
                if (try renderNode(out, child)) {
                    try out.print("\n", .{});
                }
            }
        },
        .paragraph => |n| {
            try out.print("<p>", .{});
            for (n.children) |child| {
                _ = try renderNode(out, child);
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            try out.print("<h{d}>", .{n.depth});
            for (n.children) |child| {
                _ = try renderNode(out, child);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => |n| {
            try printHTMLEscapedContent(out, n.value);
        },
        .emphasis => |n| {
            try out.print("<em>", .{});
            for (n.children) |child| {
                _ = try renderNode(out, child);
            }
            try out.print("</em>", .{});
        },
        .strong => |n| {
            try out.print("<strong>", .{});
            for (n.children) |child| {
                _ = try renderNode(out, child);
            }
            try out.print("</strong>", .{});
        },
        .code => |n| {
            // TODO: Lang?
            try out.print("<pre><code>", .{});
            try printHTMLEscapedContent(out, n.value);
            try out.print("\n", .{});
            try out.print("</code></pre>", .{});
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

            if (n.title.len > 0) {
                try out.print(" title=\"", .{});
                try printHTMLEscapedAttrValue(out, n.title);
                try out.print("\"", .{});
            }

            try out.print(">", .{});

            for (n.children) |child| {
                _ = try renderNode(out, child);
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
