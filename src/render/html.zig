const std = @import("std");
const Io = std.Io;

const ast = @import("../parse/ast.zig");

pub fn render(
    root: *ast.Node,
    out: *Io.Writer,
) Io.Writer.Error!void {
    try renderNode(out, root);
    try out.flush();
}

fn renderNode(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!void {
    switch (node.*) {
        .root => |n| {
            for (n.children) |child| {
                try renderNode(out, child);
            }
        },
        .block => |n| {
            for (n.children) |child| {
                try renderNode(out, child);
                try out.print("\n", .{});
            }
        },
        .paragraph => |n| {
            try out.print("<p>", .{});
            for (n.children) |child| {
                try renderNode(out, child);
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            try out.print("<h{d}>", .{n.depth});
            for (n.children) |child| {
                try renderNode(out, child);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => |n| {
            try printEscaped(out, n.value);
        },
        .emphasis => |n| {
            try out.print("<em>", .{});
            for (n.children) |child| {
                try renderNode(out, child);
            }
            try out.print("</em>", .{});
        },
        .strong => |n| {
            try out.print("<strong>", .{});
            for (n.children) |child| {
                try renderNode(out, child);
            }
            try out.print("</strong>", .{});
        },
        .code => |n| {
            // TODO: Lang?
            try out.print("<pre><code>", .{});
            try printEscaped(out, n.value);
            try out.print("\n", .{});
            try out.print("</code></pre>", .{});
        },
        .thematic_break => {
            try out.print("<hr />", .{});
        },
        .inline_code => |n| {
            try out.print("<code>", .{});
            try printEscaped(out, n.value);
            try out.print("</code>", .{});
        },
    }
}

fn printEscaped(out: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '&' => try out.print("&amp;", .{}),
            '<' => try out.print("&lt;", .{}),
            '>' => try out.print("&gt;", .{}),
            '"' => try out.print("&quot;", .{}),
            '\'' => try out.print("&#39;", .{}),
            else => try out.writeByte(c),
        }
    }
}
