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
    if (@as(ast.NodeType, node.*) == .definition) {
        return;
    }

    try stringify.beginObject();
    try stringify.objectField("type");

    switch (node.*) {
        .thematic_break => try stringify.write("thematicBreak"),
        .inline_code => try stringify.write("inlineCode"),
        .myst_role => try stringify.write("mystRole"),
        .myst_role_error => try stringify.write("mystRoleError"),
        .myst_directive => try stringify.write("mystDirective"),
        .myst_directive_error => try stringify.write("mystDirectiveError"),
        .admonition_title => try stringify.write("admonitionTitle"),
        else => try stringify.write(@tagName(node.*)),
    }

    switch (node.*) {
        inline .root, .paragraph, .block, .emphasis, .strong, .blockquote,
        .subscript, .superscript, .admonition_title, .caption => |n| {
            try render_children(stringify, n);
        },
        .heading => |n| {
            try stringify.objectField("depth");
            try stringify.write(n.depth);
            try render_children(stringify, n);
        },
        inline .text, .inline_code, .html => |n| {
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

            const title = n.title;
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }

            try render_children(stringify, n);
        },
        .image => |n| {
            try stringify.objectField("url");
            try stringify.write(n.url);

            const alt = n.alt;
            if (alt.len > 0) {
                try stringify.objectField("alt");
                try stringify.write(alt);
            }

            const title = n.title;
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }
        },
        .@"break", .thematic_break => {},
        .definition => unreachable,
        .container => |n| {
            try stringify.objectField("kind");
            try stringify.write(n.kind);

            if (n.children.len > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_role => |n| {
            try stringify.objectField("name");
            try stringify.write(n.name);

            try stringify.objectField("value");
            try stringify.write(n.value);

            if (n.children.len > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_role_error => |n| {
            try stringify.objectField("value");
            try stringify.write(n.value);
        },
        .abbreviation => |n| {
            const title = n.title;
            if (title.len > 0) {
                try stringify.objectField("title");
                try stringify.write(title);
            }

            if (n.children.len > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_directive => |n| {
            try stringify.objectField("name");
            try stringify.write(n.name);

            const args = n.args;
            if (args.len > 0) {
                try stringify.objectField("args");
                try stringify.write(args);
            }

            const value = n.value;
            if (value.len > 0) {
                try stringify.objectField("value");
                try stringify.write(value);
            }

            if (n.children.len > 0) {
                try render_children(stringify, n);
            }
        },
        .myst_directive_error => |n| {
            try stringify.objectField("message");
            try stringify.write(n.message);
        },
        .admonition => |n| {
            const kind = n.kind;
            if (kind.len > 0) {
                try stringify.objectField("kind");
                try stringify.write(kind);
            }

            if (n.children.len > 0) {
                try render_children(stringify, n);
            }
        },
    }

    try stringify.endObject();
}

fn render_children(
    stringify: *Stringify,
    node_payload: anytype,
) Io.Writer.Error!void {
    try stringify.objectField("children");
    try stringify.beginArray();

    for (node_payload.children) |child| {
        try render_node(stringify, child);
    }

    try stringify.endArray();
}
