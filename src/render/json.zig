//! Renders MyST AST as JSON.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const AstNode = @import("../parse/ast.zig").AstNode;

pub fn render(ast: AstNode, out: *Io.Writer) Io.Writer.Error!void {
    var stringify = Stringify{ .writer = out };
    try render_node(&stringify, ast);
}

fn render_node(stringify: *Stringify, node: AstNode) Io.Writer.Error!void {
    try stringify.beginObject();
    try stringify.objectField("type");
    try stringify.write(@tagName(node));

    switch (node) {
        .root, .paragraph => |n| {
            try render_children(stringify, n);
        },
        .heading => |n| {
            try stringify.objectField("depth");
            try stringify.write(n.depth);
            try render_children(stringify, n);
        },
        .text => |n| {
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
    }

    try stringify.endObject();
}

fn render_children(stringify: *Stringify, node: anytype) Io.Writer.Error!void {
    try stringify.objectField("children");
    try stringify.beginArray();
    for (node.children) |child| {
        try render_node(stringify, child);
    }
    try stringify.endArray();
}
