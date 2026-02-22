//! A mini-renderer that renders nodes as plain text.
//!
//! This is only used during parsing to turn link text into an alt text string
//! for images.

const std = @import("std");
const Io = std.Io;

const ast = @import("ast.zig");

/// Write node as alt text to writer.
pub fn write(out: *Io.Writer, node: *ast.Node) Io.Writer.Error!void {
    switch (node.*) {
        inline .root, .block, .blockquote, .paragraph, .emphasis, .strong,
        .heading, .link => |n| {
            for (n.children) |child| {
                try write(out, child);
            }
        },
        inline .text, .inline_code, .code => |n| {
            _ = try out.write(n.value);
        },
        .image => |n| {
            _ = try out.write(n.alt);
        },
        .@"break", .thematic_break, .definition => {},
    }
}
