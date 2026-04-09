//! A mini-renderer that renders nodes as plain text.
//!
//! This is only used during parsing to turn link text into an alt text string
//! for images.

const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

/// Write node as alt text to writer.
pub fn write(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!void {
    switch (node.tag) {
        inline .root, .block, .blockquote, .paragraph, .emphasis, .strong,
        .heading, .link, .subscript => |node_type| {
            const n = @field(node.payload, @tagName(node_type));
            const sliced = n.children[0..n.n_children];
            for (sliced) |child| {
                try write(out, child);
            }
        },
        inline .text, .code, .inline_code, .html, .myst_role,
        .myst_role_error => |node_type| {
            const n = @field(node.payload, @tagName(node_type));
            _ = try out.write(std.mem.span(n.value));
        },
        .image => {
            const n = node.payload.image;
            _ = try out.write(std.mem.span(n.alt));
        },
        .@"break", .thematic_break, .definition => {},
    }
}
