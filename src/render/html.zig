const std = @import("std");
const Io = std.Io;

const ast = @import("../parse/ast.zig");

pub fn render(
    root: *ast.Node,
    out: *Io.Writer,
) Io.Writer.Error!void {
    try render_node(out, root);
    try out.flush();
}

fn render_node(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!void {
    switch (node.*) {
        .root => |n| {
            for (n.children) |child| {
                try render_node(out, child);
            }
        },
        .block => |n| {
            for (n.children) |child| {
                try render_node(out, child);
                try out.print("\n", .{});
            }
        },
        .paragraph => |n| {
            try out.print("<p>", .{});
            for (n.children) |child| {
                try render_node(out, child);
            }
            try out.print("</p>", .{});
        },
        .heading => |n| {
            try out.print("<h{d}>", .{n.depth});
            for (n.children) |child| {
                try render_node(out, child);
            }
            try out.print("</h{d}>", .{n.depth});
        },
        .text => |n| {
            try out.print("{s}", .{n.value});
        },
    }
}
