//! A mini-renderer that renders nodes as plain text.
//!
//! This is only used during parsing to turn link text into an alt text string
//! for images.

const std = @import("std");
const Io = std.Io;

const ast = @import("../ast.zig");

/// Write node as alt text to writer.
pub fn write(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!void {
    switch (node.hasChildren()) {
        .yes => |branch_node| switch (branch_node) {
            inline else => |n| {
                for (n.children) |child| {
                    try write(out, child);
                }
            },
        },
        .no => |leaf_node| switch (leaf_node) {
            inline .text, .code, .inline_code, .html,
            .myst_role_error => |n| {
                _ = try out.write(n.value);
            },
            .image => |n| {
                _ = try out.write(n.alt);
            },
            .@"break", .thematic_break, .definition => {},
        },
    }
}
