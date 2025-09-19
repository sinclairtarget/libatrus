//! Renders MyST AST as JSON.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const ast = @import("../parse/ast.zig");

pub fn render(
    root: ast.Node,
    out: *Io.Writer,
    options: struct { json_options: Stringify.Options = .{} },
) Io.Writer.Error!void {
    var stringify = Stringify{
        .writer = out,
        .options = options.json_options,
    };
    try render_node(&stringify, root);
}

fn render_node(stringify: *Stringify, node: ast.Node) Io.Writer.Error!void {
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
