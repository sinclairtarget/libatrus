//! Renders MyST AST as JSON.

const std = @import("std");
const Io = std.Io;
const Stringify = std.json.Stringify;

const ast = @import("../ast.zig");

pub const Options = extern struct {
    whitespace: enum(c_uint) {
        minified = 0,
        indent_2 = 1,
        indent_4 = 2,
    } = .minified,
};

/// Renders the given AST as JSON.
///
/// The given AST node might be the root, but it might not. We support
/// rendering arbitrary subtrees of a complete MyST AST.
pub fn render(
    node: *ast.Node,
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
    try render_node(&stringify, node);
}

fn render_node(stringify: *Stringify, node: *ast.Node) Io.Writer.Error!void {
    // These nodes don't get rendered
    switch (node.*) {
        .definition => return,
        else => {},
    }

    try stringify.beginObject();
    try stringify.objectField("type");

    switch (node.*) {
        .thematic_break => try stringify.write("thematicBreak"),
        .inline_code => try stringify.write("inlineCode"),
        else => try stringify.write(@tagName(node.*)),
    }

    switch (node.*) {
        .root => |n| {
            try render_children(stringify, n);
        },
        .paragraph, .block, .emphasis, .strong, .blockquote => |n| {
            try render_children(stringify, n);
        },
        .heading => |n| {
            try stringify.objectField("depth");
            try stringify.write(n.depth);
            try render_children(stringify, n);
        },
        .text, .inline_code => |n| {
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .code => |n| {
            try stringify.objectField("lang");
            try stringify.write(n.lang);
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .link => |n| {
            try stringify.objectField("url");
            try stringify.write(n.url);

            if (n.title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(n.title);
            }

            try render_children(stringify, n);
        },
        .image => |n| {
            try stringify.objectField("url");
            try stringify.write(n.url);

            if (n.alt.len > 0) {
                try stringify.objectField("alt");
                try stringify.write(n.alt);
            }

            if (n.title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(n.title);
            }
        },
        .@"break", .thematic_break => {},
        .definition => unreachable,
    }

    try stringify.endObject();
}

fn render_children(
    stringify: *Stringify,
    node_data: anytype,
) Io.Writer.Error!void {
    try stringify.objectField("children");
    try stringify.beginArray();

    const sliced = node_data.children[0..node_data.n_children];
    for (sliced) |child| {
        try render_node(stringify, child);
    }

    try stringify.endArray();
}
