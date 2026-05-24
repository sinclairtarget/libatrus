const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

pub const RenderError = error{
    NotImplemented,
} || Io.Writer.Error;

pub fn render(node: *ast.Node, out: *Io.Writer) RenderError!void {
    _ = try renderNode(node, out);
    try out.flush();
}

fn renderNode(node: *ast.Node, out: *Io.Writer) RenderError!void {
    switch (node.allowedChildren()) {
        .yes => |branch_node| {
            switch (branch_node) {
                .root,  => |n| {
                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                },
                .block => |n| {
                    for (n.children, 0..) |child, i| {
                        _ = try renderNode(child, out);
                        if (i < n.children.len - 1) {
                            _ = try out.writeAll("\n");
                        }
                    }
                },
                .heading => |n| {
                    for (0..n.depth) |_| {
                        _ = try out.writeAll("=");
                    }
                    _ = try out.writeAll(" ");

                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                },
                .paragraph => |n| {
                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                    _ = try out.writeAll("\n");
                },
                .emphasis => |n| {
                    _ = try out.writeAll("_");
                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                    _ = try out.writeAll("_");
                },
                .strong => |n| {
                    _ = try out.writeAll("*");
                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                    _ = try out.writeAll("*");
                },
                .link => |n| {
                    try out.print("#link(\"{s}\")[", .{n.url});
                    for (n.children) |child| {
                        _ = try renderNode(child, out);
                    }
                    _ = try out.writeAll("]");
                },
                .blockquote => |n| {
                    _ = try out.writeAll("#quote(block: true)[");
                    for (n.children, 0..) |child, i| {
                        _ = try renderNode(child, out);
                        if (i < n.children.len - 1) {
                            _ = try out.writeAll("\n");
                        }
                    }
                    _ = try out.writeAll("]\n");
                },
                else => return error.NotImplemented,
            }
        },
        .no => |leaf_node| {
            switch (leaf_node) {
                .text => |n| {
                    _ = try out.writeAll(n.value);
                },
                .inline_code => |n| {
                    try out.print("`{s}`", .{n.value});
                },
                .thematic_break => {
                    _ = try out.writeAll(
                        "#line(length: 100%, stroke: gray)\n",
                    );
                },
                .@"break" => {
                    _ = try out.writeAll("\\\n");
                },
                .definition => {},
                else => return error.NotImplemented,
            }
        },
    }
}
