//! Renders MyST AST as JSON.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const ast = @import("../parse/ast.zig");

pub const Options = struct {
    whitespace: enum {
        minified,
        indent_2,
        indent_4,
    } = .minified,
};

pub fn render(
    root: *ast.Node,
    out: *Io.Writer,
    options: Options,
) Io.Writer.Error!void {
    const stringify_options: Stringify.Options = .{
        .whitespace = switch (options.whitespace) {
            .minified => .minified,
            .indent_2 => .indent_2,
            .indent_4 => .indent_4,
        },
    };
    var stringify = Stringify{
        .writer = out,
        .options = stringify_options,
    };
    try render_node(&stringify, root);
}

fn render_node(stringify: *Stringify, node: *ast.Node) Io.Writer.Error!void {
    try stringify.beginObject();
    try stringify.objectField("type");

    switch (node.*) {
        .thematic_break => try stringify.write("thematicBreak"),
        else => try stringify.write(@tagName(node.*)),
    }

    switch (node.*) {
        .root => |n| {
            try render_children(stringify, n);
        },
        .paragraph, .block => |n| {
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
        .code => |n| {
            try stringify.objectField("lang");
            try stringify.write(n.lang);
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .thematic_break => {},
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
